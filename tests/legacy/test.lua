local inspect = require "inspect"
local service = require "lservice2"
local uv = require "luv"


-- test pack and unpack
function test_pack()
    local config = { ping = "hello", pong = "world" }
    local ptr = service.pack(config)
    print(ptr, inspect(config))
    print(inspect(service.unpack_remove(ptr)))
end
-- test_pack()

-- test service.new
--[[
local addr1 = service.new {
    source = "@service/hello.lua",
    config = { say = "hello world" }
}

service.start(addr1)

local addr2 = service.new { source = "@service/hello.lua", config = { say = "hello world again" } }
local addr3 = service.new { source = "@service/user.lua", config = { say = "hello world again" } }

print("id", service.get_id(addr2))

service.start(addr2)
service.start(addr3)

local msg, sz = service.pack { say = "msg1" }

service._send_message(
        service.pool,
        service.get_id(addr1),
        service.get_id(addr2),
        0, -- session
        0, -- type
        msg,
        sz
    )

local MESSAGE_REQUEST = 1

local msg, sz = service.pack ( "ping", "arg1", 2 )
service._send_message(
    service.pool,
    service.get_id(addr1), -- from
    service.get_id(addr3), -- to
    0,
    MESSAGE_REQUEST,
    msg,
    sz
)
]]

local MESSAGE_REQUEST = 1
local boot_id = service.spawn { source = "@service/echo.lua", config = {} }
print("boot_id", boot_id)
local msg, sz = service.pack ( "boot" )
service._send_message(
    service.pool,
    0,
    boot_id,
    0,
    MESSAGE_REQUEST,
    msg,
    sz
)


uv.new_signal():start("sigint", function(signal)
        print("on sigint, exit")
        uv.walk(function (handle) if not handle:is_closing() then handle:close() end end)
        os.exit(1)
    end)

uv.run()