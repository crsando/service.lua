local service = require "lservice3"
service.input()

local uv = service.uv
local original_gettimeofday = uv.gettimeofday
local original_new_timer = uv.new_timer

local today = os.date("*t")
local base_seconds = os.time {
    year = today.year,
    month = today.month,
    day = today.day,
    hour = 13,
    min = 4,
    sec = 59,
}
assert(base_seconds, "could not construct local test time")

local fake_now_ms = base_seconds * 1000
local fake_timer

uv.gettimeofday = function()
    local seconds = math.floor(fake_now_ms / 1000)
    return seconds, (fake_now_ms - seconds * 1000) * 1000
end

uv.new_timer = function()
    fake_timer = {
        callback = nil,
        delay = nil,
    }

    function fake_timer:is_closing()
        return false
    end

    function fake_timer:start(delay, _, callback)
        self.delay = delay
        self.callback = callback
        return 0
    end

    function fake_timer:stop()
        return 0
    end

    return fake_timer
end

local scheduler = require "lservice3.scheduler"
service.scheduler = scheduler

local fired = 0
scheduler:daily("13:05:00", function()
    fired = fired + 1
end)

assert(fake_timer.delay == 1000, "daily should arm for the next local 13:05:00")
assert(type(fake_timer.callback) == "function", "daily timer was not armed")

fake_now_ms = fake_now_ms + 1000
fake_timer.callback()
assert(fired == 1, "daily callback should fire at 13:05:00")

uv.gettimeofday = original_gettimeofday
uv.new_timer = original_new_timer
package.loaded["lservice3.scheduler"] = nil

print("scheduler_daily_spec: ok")
