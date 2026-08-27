local service = require "lservice3"

-- The source runs in the root service's own Lua VM and libuv loop.
local source = [[
local service = require "lservice3".input(...)
local scheduler = require "lservice3.scheduler"
service.scheduler = scheduler

local now = os.time()

-- Numeric timestamps are Unix epoch seconds and do not depend on timezone.
scheduler:at(now + 1, function()
    print("at(number): fired")
end)

-- An explicit UTC suffix makes the timestamp portable across hosts.
local utc_deadline = os.date("!%Y-%m-%dT%H:%M:%SZ", now + 2)
scheduler:at(utc_deadline, function()
    print("at(UTC): fired at " .. utc_deadline)
    service.quit()
end)

-- daily uses the service process's local calendar timezone.
scheduler:daily({ hour = 12, minute = 59, second = 0 }, function()
    print("daily(local): fired")
end)

return service.dispatch(function(command)
    assert(command == "boot", "unexpected command: " .. tostring(command))
    print("scheduler example started")
end)
]]

service.bootstrap {
    source = source,
    config = {},
    start = "boot",
}
