local service = require "lservice3_c"
local inspect = require "inspect"

-- 除了入口之外，这里理论上已经注册过"luv"
-- 理论上，一个service 启动的时候，会自动加载一份 luv，故这里轮上会直接获取 package.loaded["luv"] 的结果
local uv = require "luv"

--[[
    common conventions:

    addr: lightuserdata of service_t (actually, pointer)
    from, to : service_id (integer)
]]

-- constants

local ROOT_ID = 0
local UINT32_MAX = 4294967295
local DISPATCH_BATCH_SIZE = 256

local MESSAGE_SYSTEM = 0
local MESSAGE_REQUEST = 1
local MESSAGE_RESPONSE = 2
local MESSAGE_ERROR = 3
local MESSAGE_SIGNAL = 4

local MESSAGE_RECEIPT_NONE = 0
local MESSAGE_RECEIPT_DONE = 1
local MESSAGE_RECEIPT_ERROR = 2
local MESSAGE_RECEIPT_BLOCK = 3
local MESSAGE_RECEIPT_RESPONCE = 4

local CALL_SEND_ERROR = {
    SERVICE_NOT_FOUND = "service not found",
    SERVICE_STOPPING = "service stopping",
    SERVICE_STOPPED = "service stopped",
    MAILBOX_FULL = "mailbox full",
}


-- preserved internal parameters
service.self = nil -- the current running service
service.uv = uv -- 这个变量会在service启动的一开始就启动
service.pool = nil
service.config = nil

service.yield_session = coroutine.yield

local yield_session = coroutine.yield

-- basic apis

function service.new(t)
    if t.mailbox_size ~= nil then
        assert(type(t.mailbox_size) == "number" and t.mailbox_size % 1 == 0,
            "mailbox_size must be an integer")
        assert(t.mailbox_size >= 16 and t.mailbox_size <= 65536,
            "mailbox_size must be between 16 and 65536")
    end

    if not service.pool then
        if t.pool then
            service.pool = t.pool
        else
            -- print("create new pool")
            service.pool = service._pool_new()
        end
    end

    assert(t.source, "source not provided")
    --[[
    local code = nil
    if string.sub(t.source, 1, 1) == "@" then
        code = assert(io.open(string.sub(t.source, 2, -1)):read("*all"), "service code path not found")
    else
        code = t.source
    end
    ]]

    local config = nil
    if t.config and (type(t.config) == "table") then
        config = service.pack(t.config)
    else
        config = t.config
    end

    local addr = service._new(t.pool or service.pool, t.name, t.source, config, t)
    -- setmetatable(s, { __index = service })
    return addr
end

function service.start(addr)
    -- if id is given, it is automatically converted into addr
    local err
    addr, err = service.get_addr(addr)
    assert(addr, err)
    return service._start(addr)
end

function service.join(addr)
    -- if id is given, it is automatically converted into addr
    local err
    addr, err = service.get_addr(addr)
    assert(addr, err)
    return service._join(addr)
end

function service.spawn(t)
    local addr = service.new(t)
    service.start(addr)
    return service.get_id(addr)
end


function service.get_uv_loop(addr)
    addr = addr or service.self
    if not addr then return nil end
    return service._get_uv_loop(addr)
end

-- get current service_id or get_id by addr
local CURRENT_SERVICE_ID = nil
function service.get_id(addr)
    if service.self == nil then return 0 end
    if not addr then
        CURRENT_SERVICE_ID = CURRENT_SERVICE_ID or service._get_id(service.self)
        return CURRENT_SERVICE_ID
    else
        return service._get_id(addr)
    end
end

function service.lookup(name)
    if not name then return 0 end
    return service._lookup(service.get_pool(), name)
end

function service.get_async(addr)
    if service.self == nil then return nil end
    addr = addr or service.self
    return service._get_async(addr)
end


function service.get_pool(addr)
    if service.self == nil and addr == nil then return service.pool end
    addr = addr or service.self
    return service._get_pool(addr)
end

function service.get_addr(id)
    if not id then return service.self end -- if input is lightuserdata
    if type(id) ~= "number" then return id end
    if not service.self then return nil, "SERVICE_NOT_FOUND" end
    return service._get_addr(service.self, id)
end


function service.input(s, config_ptr)
    -- print("service.input", s, config, uv)
    if s then
        service.self = s
        service.pool = service.get_pool(s)
        -- The native start path owns and frees config_ptr after source init.
        service.config = config_ptr and service.unpack(config_ptr) or {}
    else
        -- print("No input, running in standalone mode")
        service.self = nil
        service.pool = nil
        service.config = {}
    end

    return service
end

function service.send_message(to, session, type, msg, sz)
    local from = service.get_id()
    return service._send_message(service.pool, from, to, session, type, msg, sz)
end

function service.recv_message(blocking)
    assert(service.self, "no self state provided")
    if blocking == nil then
        blocking = true
    end
    return service._recv_message(service.self, blocking)
end

--
-- session (mostly copyed and modified from ltask)
--
local running_thread

local session_coroutine_suspend_lookup = {}
local session_coroutine_where = {}
local session_coroutine_suspend = {}
local session_coroutine_response = {}
local session_coroutine_address = {}
local next_session_id = 1
local managed_coroutines = setmetatable({}, { __mode = "k" })

local session_waiting = {}
local wakeup_queue = {}

local function allocate_session()
    local first = next_session_id

    repeat
        local session = next_session_id
        next_session_id = session == UINT32_MAX and 1 or session + 1
        if session_coroutine_suspend_lookup[session] == nil then
            return session
        end
    until next_session_id == first

    error("RPC_SESSION_EXHAUSTED", 2)
end

local function error_message(errobj)
    if type(errobj) == "string" then
        return errobj
    end

    local ok, message = pcall(tostring, errobj)
    if ok and type(message) == "string" then
        return message
    end
    return "handler error"
end

local function send_error_response(to, session, message)
    service._send_message(
        service.pool,
        service.get_id(),
        to,
        session,
        MESSAGE_ERROR,
        service.pack(message)
    )
end

local function resume_session(co, ...)
	running_thread = co
	local ok, errobj = coroutine.resume(co, ...)
	running_thread = nil
	if ok then
		return errobj
	end
    local from = session_coroutine_address[co]
    local session = session_coroutine_response[co]

    session_coroutine_address[co] = nil
    session_coroutine_response[co] = nil
    if from ~= nil and type(session) == "number" and session > 0 then
        send_error_response(from, session, error_message(errobj))
    end
end

service.resume_session = resume_session

local coroutine_pool = setmetatable({}, { __mode = "kv" })

-- Mingda Qiu
-- 原始的new_thread没看懂, 尝试换一个写法试试
local function new_thread(f)
    local co = coroutine.create(function (...)
            -- print(">>> coroutine begin", f, inspect{...})
            local ok, err = pcall(f, ...)
            if not ok then print("ERROR", err) end
            if not ok then error(err, 0) end
            -- print(">>> coroutine end")
        end)

    managed_coroutines[co] = true
    table.insert(coroutine_pool, co)

	return co
end

local function new_session(f, from, session)
    -- print("new_session", f, from, session)
	local co = new_thread(f)
	session_coroutine_address[co] = from
	session_coroutine_response[co] = session
	return co
end

local function send_response(...)
	local session = session_coroutine_response[running_thread]
    -- print("send_response", session, inspect{...})

	if session > 0 then
		local from = session_coroutine_address[running_thread]
		service._send_message(service.pool, service.get_id(), from, session, MESSAGE_RESPONSE, service.pack(...))
	end

	-- End session
	session_coroutine_address[running_thread] = nil
	session_coroutine_response[running_thread] = nil
end

-- api

-- local function dispatch_wakeup()
--     print("dispatch_wakeup", inspect(wakeup_queue))
-- 	while #wakeup_queue > 0 do
-- 		local s = table.remove(wakeup_queue, 1)
-- 		resume_session(unpack(s))
-- 	end
-- end

-- function service.fork(func, ...)
-- 	local co = new_thread(func)
-- 	wakeup_queue[#wakeup_queue+1] = {co, ...}
-- end


function service.send(id, ...)
    if type(id) == "string" then
        id = service.lookup(id)
    end
    if type(id) ~= "number" then
        return nil, "SERVICE_NOT_FOUND"
    end
    return service._send_message(
        service.pool,
        service.get_id(), -- from
        id,  -- to
        0,  --session_id = 0
        MESSAGE_REQUEST,
        service.pack(...)
    )
end

function service.loopback(...)
    return service.send(service.get_id(), ...)
end

function service.call(id, ...)
    local caller = running_thread
    if caller == nil or not managed_coroutines[caller] then
        error("service.call must be called from a managed service coroutine", 2)
    end

    if type(id) == "string" then
        id = service.lookup(id)
    end

    if type(id) ~= "number" or id < 0 or id > UINT32_MAX or id % 1 ~= 0 then
        return nil, "service not found"
    end

    local session_id = allocate_session()

    -- print("begin service.call:", id, session_id)
    local ok, err = service._send_message(
        service.pool,
        service.get_id(), -- from
        id,  -- to
        session_id,
        MESSAGE_REQUEST,
        service.pack(...)
    )
    if not ok then
        return nil, CALL_SEND_ERROR[err] or err
    end

    session_coroutine_suspend_lookup[session_id] = caller

    -- print("begin service.call yield_session:", id)
	local type, session, msg, sz = yield_session()
    -- print("service.call get response from")
	if type == MESSAGE_RESPONSE then
		return service.unpack_remove(msg, sz)
	elseif type == MESSAGE_ERROR then
        local message = service.unpack_remove(msg, sz)
        return nil, message
	else
        service.remove(msg, sz)
        return nil, "invalid response type"
	end
end

function service.get_session()
    return running_thread
end

local quit = false
function service.quit()
    if quit then return end
    quit = true
    service._stop(service.self)
end

--
-- internal procedures
--

service._on_msg = nil
service._on_idle = nil

function service.dispatch(request_handler)
    local request; do
        if type(request_handler) == "function" then
            request = function (command, ...)
                send_response(request_handler(command, ...))
            end
        elseif type(request_handler) == "table" then
            request = function (command, ...)
                local s = request_handler[command]
                if not s then
                    error("command not found", 0)
                end
                send_response(s(...))
            end
        end
    end

    service._on_msg = function (msg)
        -- if in standalone mode
        if not service.self then return false end

        local processed = 0

        -- main loop
        while msg and not quit and processed < DISPATCH_BATCH_SIZE do
            local from, to, session, type, msg, sz = service.recv_message(false)
            -- print("recv_message", from, to, session, type, msg, sz)
            if from == nil then
                break
            end
            processed = processed + 1
            -- if a request is received
            if type == MESSAGE_REQUEST then
                local co = new_session(function (type, msg, sz)
                        request(service.unpack_remove(msg, sz))
                    end, from, session)
                resume_session(co, type, msg, sz)
            -- on response, resume the previous session
            elseif (type == MESSAGE_RESPONSE or type == MESSAGE_ERROR) and session > 0 then
                local co = session_coroutine_suspend_lookup[session]
                if co == nil then
                    service.remove(msg, sz)
                else
                    session_coroutine_suspend_lookup[session] = nil
                    resume_session(co, type, session, msg, sz)
                end
            else
                service.remove(msg, sz)
            end
        end

        -- Synchronous end-of-round hook; the mailbox may still have messages.
        if (not quit) and service.on_idle then
            service.on_idle()
        end

        return (not quit) and processed == DISPATCH_BATCH_SIZE
    end -- end function (handler)

    return service._on_msg
end -- end service.dispatch

function service.bootstrap(entry)
    assert(entry and type(entry) == "table")
    assert(entry.source and type(entry.source == "string"))

    local entry_point = entry.start or "boot"

    local addr = service.new { source = entry.source, config = entry.config, name = "root" }
    service.start(addr)
    service.send(service.get_id(addr), entry_point)
    service.join(addr)
end

--
-- utility functions
--

function service.sleep(ms)
    local co = service.get_session()
    service.set_timeout(ms, function ()
            resume_session(co)
        end)
    yield_session()
end

function service.set_timeout(ms, cb)
    local timer = service.uv.new_timer()
    timer:start(ms, 0, function()
        timer:stop()
        timer:close()
        cb()
    end)
    return timer
end

return service
