local service = require "lservice3"
service.input()
assert(service.scheduler == nil, "scheduler must not be loaded by lservice3")

local uv = service.uv
local original_gettimeofday = uv.gettimeofday
local original_new_timer = uv.new_timer
local initial_seconds, initial_useconds = original_gettimeofday()
local fake_now_ms = initial_seconds * 1000 + math.floor(initial_useconds / 1000)
local fake_timer_count = 0
local fake_timer

local function fake_gettimeofday()
    local seconds = math.floor(fake_now_ms / 1000)
    return seconds, (fake_now_ms - seconds * 1000) * 1000
end

uv.gettimeofday = fake_gettimeofday
uv.new_timer = function()
    fake_timer_count = fake_timer_count + 1
    fake_timer = {
        callback = nil,
        closed = false,
    }
    function fake_timer:is_closing()
        return self.closed
    end
    function fake_timer:start(_, _, callback)
        self.callback = callback
        return 0
    end
    function fake_timer:stop()
        return 0
    end
    function fake_timer:close()
        self.closed = true
        return 0
    end
    return fake_timer
end

local scheduler = require "lservice3.scheduler"
service.scheduler = scheduler

local at_order = {}
scheduler:at("1970-01-01T00:00:00Z", function()
    at_order[#at_order + 1] = "z"
end)
scheduler:at("1970-01-01 08:00:00+08:00", function()
    at_order[#at_order + 1] = "offset"
end)

local daily_count = 0
scheduler:daily({ hour = 0 }, function()
    daily_count = daily_count + 1
end)
scheduler:daily("00:00:00", function()
    daily_count = daily_count + 1
end)

assert(fake_timer_count == 1, "scheduler must create one timer")
assert(type(fake_timer.callback) == "function", "scheduler timer was not armed")
fake_now_ms = fake_now_ms + 2 * 24 * 60 * 60 * 1000
fake_timer.callback()
assert(at_order[1] == "z" and at_order[2] == "offset",
    "equal deadlines must preserve registration order")
assert(daily_count == 2, "overdue daily tasks must be executed")
assert(fake_timer_count == 1, "daily rearm must reuse the timer")

local once_count = 0
local error_ok, error_message = pcall(function()
    scheduler:at(fake_now_ms / 1000 - 1, function()
        once_count = once_count + 1
        error("expected scheduler callback error")
    end)
end)
assert(error_ok, error_message)
scheduler:at(fake_now_ms / 1000 - 1, function()
    once_count = once_count + 1
end)
fake_timer.callback()
fake_timer.callback()
assert(once_count == 2, "at tasks must execute once even when overdue")
assert(fake_timer_count == 1, "rescheduling must not create another timer")

local invalid_ok = pcall(function()
    scheduler:at("2024-02-30T00:00:00Z", function() end)
end)
assert(not invalid_ok, "invalid calendar date must be rejected")
invalid_ok = pcall(function()
    scheduler:daily({ hour = 24 }, function() end)
end)
assert(not invalid_ok, "invalid daily hour must be rejected")
invalid_ok = pcall(function()
    scheduler:at(fake_now_ms / 1000, {})
end)
assert(not invalid_ok, "table actions must be rejected in phase one")

-- Reload the module after the fake-loop checks so the real luv timer is tested
-- with a fresh scheduler state in the same Lua VM.
uv.gettimeofday = original_gettimeofday
uv.new_timer = original_new_timer
package.loaded["lservice3.scheduler"] = nil
local real_scheduler = require "lservice3.scheduler"
service.scheduler = real_scheduler

local real_timer_count = 0
uv.new_timer = function()
    real_timer_count = real_timer_count + 1
    return original_new_timer()
end

local real_seconds, real_useconds = original_gettimeofday()
local target_ms = real_seconds * 1000 + math.floor(real_useconds / 1000) + 20
local real_once_count = 0
real_scheduler:at(target_ms / 1000, function()
    real_once_count = real_once_count + 1
end)

local wait_until_ms = target_ms + 100
repeat
    real_seconds, real_useconds = original_gettimeofday()
    fake_now_ms = real_seconds * 1000 + math.floor(real_useconds / 1000)
until fake_now_ms >= wait_until_ms

uv.run()
uv.run()
assert(real_once_count == 1,
    "an overdue at task must be compensated exactly once")
assert(real_timer_count == 1, "real scheduler must create one timer")

uv.walk(function(handle)
    if not handle:is_closing() then
        handle:close()
    end
end)
uv.run()
uv.new_timer = original_new_timer

print("scheduler_spec: ok")
