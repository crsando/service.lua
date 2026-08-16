local service = require "lservice3"

local function find_upvalue(fn, expected)
    for index = 1, 32 do
        local name, value = debug.getupvalue(fn, index)
        if name == expected then
            return value, index
        end
        if name == nil then
            break
        end
    end
end

local ok, err = pcall(service.call, 0, "echo")
assert(ok == false)
assert(tostring(err):find("managed service coroutine", 1, true))

local unmanaged_ok
local unmanaged_err
local unmanaged = coroutine.create(function()
    unmanaged_ok, unmanaged_err = pcall(service.call, 0, "echo")
end)
service.resume_session(unmanaged)
assert(unmanaged_ok == false)
assert(tostring(unmanaged_err):find("managed service coroutine", 1, true))

local allocate_session = assert(find_upvalue(service.call, "allocate_session"))
local pending = assert(find_upvalue(service.call, "session_coroutine_suspend_lookup"))
local call_send_error = assert(find_upvalue(service.call, "CALL_SEND_ERROR"))
local _, next_session_index = find_upvalue(allocate_session, "next_session_id")
assert(next_session_index)
assert(debug.setupvalue(allocate_session, next_session_index, 4294967295))

assert(call_send_error.SERVICE_NOT_FOUND == "service not found")
assert(call_send_error.SERVICE_STOPPING == "service stopping")
assert(call_send_error.SERVICE_STOPPED == "service stopped")
assert(call_send_error.MAILBOX_FULL == "mailbox full")
for _, message in pairs(call_send_error) do
    assert(message:find("[\128-\255]") == nil)
end

pending[1] = true
assert(allocate_session() == 4294967295)
assert(allocate_session() == 2)
pending[1] = nil
assert(debug.setupvalue(allocate_session, next_session_index, 4294967295))

local new_session = assert(find_upvalue(service.dispatch, "new_session"))
local new_thread = assert(find_upvalue(new_session, "new_thread"))
local original_send_message = service._send_message
for native_error, expected in pairs(call_send_error) do
    local result
    local call_err
    service._send_message = function(_, _, _, _, _, msg, sz)
        service.remove(msg, sz)
        return nil, native_error
    end

    local co = new_thread(function()
        result, call_err = service.call(0, "echo")
    end)
    service.resume_session(co)
    assert(coroutine.status(co) == "dead")
    assert(result == nil)
    assert(call_err == expected)
    assert(next(pending) == nil)
end
service._send_message = original_send_message

local source = [[
local service = require "lservice3" .input(...)

local allocate_session
for index = 1, 32 do
    local name, value = debug.getupvalue(service.call, index)
    if name == "allocate_session" then
        allocate_session = value
        break
    end
end
assert(allocate_session)

local session_was_set
for index = 1, 32 do
    local name = debug.getupvalue(allocate_session, index)
    if name == "next_session_id" then
        session_was_set = debug.setupvalue(allocate_session, index, 4294967295)
        break
    end
end
assert(session_was_set)

local S = {}

local MESSAGE_SYSTEM = 0
local MESSAGE_RESPONSE = 2
local MESSAGE_ERROR = 3
local MESSAGE_SIGNAL = 4

function S.echo(...)
    return ...
end

function S.fail()
    error("handler failed", 0)
end

function S.fail_after_sleep()
    service.sleep(0)
    error("delayed handler failure", 0)
end

function S.boot()
    local self = service.get_id()

    local function post_raw(session, message_type)
        local msg, sz = service.pack("ignored")
        assert(service.send_message(self, session, message_type, msg, sz))
    end

    post_raw(0, MESSAGE_RESPONSE)
    post_raw(0, MESSAGE_ERROR)
    post_raw(7, MESSAGE_SYSTEM)
    post_raw(8, MESSAGE_SIGNAL)
    post_raw(9, 99)

    local text, number = service.call(service.get_id(), "echo", "pong", 42)
    assert(text == "pong")
    assert(number == 42)

    local missing, missing_err = service.call("missing", "echo")
    assert(missing == nil)
    assert(missing_err == "service not found")

    local failed, failed_err = service.call(self, "fail")
    assert(failed == nil)
    assert(failed_err == "handler failed")

    local delayed, delayed_err = service.call(self, "fail_after_sleep")
    assert(delayed == nil)
    assert(delayed_err == "delayed handler failure")

    local unknown, unknown_err = service.call(self, "missing_command")
    assert(unknown == nil)
    assert(unknown_err == "command not found")

    local assert_ok, assert_err = pcall(function()
        assert(service.call(self, "fail"))
    end)
    assert(assert_ok == false)
    assert(tostring(assert_err):find("handler failed", 1, true))

    assert(service.send(self, "fail"))
    local after_error = service.call(self, "echo", "still running")
    assert(after_error == "still running")

    service.quit()
end

return service.dispatch(S)
]]

service.bootstrap {
    source = source,
    config = {},
    start = "boot",
}

print("rpc_spec: ok")
