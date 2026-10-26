local service = require "service"

-- mailbox_size is only the initial capacity: a full mailbox grows.
local source = [[
local service = require "service" .input(...)
local received = 0

return service.dispatch(function(command)
    assert(command == "item")
    received = received + 1
    if received == 100 then
        service.quit()
    end
end)
]]

service.input()
local addr = service.new {
    source = source,
    config = {},
    mailbox_size = 16,
}

for _ = 1, 100 do
    assert(service.send(0, "item") == true)
end

service.start(addr)
service.join(addr)

-- Regression: a response must not be dropped while the caller's mailbox is
-- flooded and the caller is too busy to drain it.
local ok, err = service.bootstrap { source = [[
local service = require "service"
local S = {}
function S.noop() end
function S.boot()
    service.spawn { name = "b", source = [=[
        local service = require "service"
        return { ping = function() service.sleep(50) return "pong" end }
    ]=] }
    service.spawn { name = "filler", source = [=[
        local service = require "service"
        return { flood = function(to, n)
            for _ = 1, n do assert(service.send(to, "noop")) end
        end }
    ]=] }
    service.loopback("busy")
    local r = service.call("b", "ping")
    if r ~= "pong" then
        service.quit("expected pong, got " .. tostring(r))
    end
    service.quit()
end
function S.busy()
    service.send("filler", "flood", service.get_id(), 4000)
    local t = service.uv.hrtime()
    while service.uv.hrtime() - t < 200e6 do end
end
return S
]] }
assert(ok, err)

print("mailbox_spec: ok")
