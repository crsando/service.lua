local service = require "lservice3"

local scheduler = {}

local MAX_TASKS_PER_TICK = 256
local MAX_RECHECK_MS = 60 * 1000

local heap = {}
local sequence = 0
local timer
local timer_armed = false
local draining = false
local bound_uv
local bound_self
local on_timer

local function fail(message, level)
    error("scheduler: " .. message, level or 3)
end

local function finite(value)
    return type(value) == "number" and value == value and
        value ~= math.huge and value ~= -math.huge
end

local function ensure_context()
    local current_uv = service.uv
    if type(current_uv) ~= "table" then
        fail("service.uv is not available")
    end
    if type(current_uv.gettimeofday) ~= "function" then
        fail("service.uv.gettimeofday is not available")
    end
    if type(current_uv.new_timer) ~= "function" then
        fail("service.uv.new_timer is not available")
    end

    if bound_uv == nil then
        bound_uv = current_uv
        bound_self = service.self
    elseif bound_uv ~= current_uv or bound_self ~= service.self then
        fail("cannot reuse scheduler across service or loop contexts")
    end
    return current_uv
end

local function wall_now_ms()
    local current_uv = ensure_context()
    local seconds, useconds = current_uv.gettimeofday()
    if not finite(seconds) or not finite(useconds) or
        useconds < 0 or useconds >= 1000000 then
        fail("uv.gettimeofday returned an invalid value")
    end
    return seconds * 1000 + math.floor(useconds / 1000)
end

local function is_leap_year(year)
    return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local function days_in_month(year, month)
    local days = {
        31, is_leap_year(year) and 29 or 28, 31, 30, 31, 30,
        31, 31, 30, 31, 30, 31,
    }
    return days[month]
end

-- Gregorian date to days since 1970-01-01 (Howard Hinnant's civil algorithm).
local function days_from_civil(year, month, day)
    year = year - (month <= 2 and 1 or 0)
    local era = math.floor(year / 400)
    local year_of_era = year - era * 400
    local month_prime = month + (month > 2 and -3 or 9)
    local day_of_year = math.floor((153 * month_prime + 2) / 5) + day - 1
    local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4) -
        math.floor(year_of_era / 100) + day_of_year
    return era * 146097 + day_of_era - 719468
end

local function parse_at_string(value)
    local main, tail = value:match(
        "^(%d%d%d%d%-%d%d%-%d%d[T ]%d%d:%d%d:%d%d)(.*)$")
    if not main then
        fail("invalid timestamp")
    end

    local year, month, day, hour, minute, second = main:match(
        "^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)$")
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
    if year < 1 or month < 1 or month > 12 or day < 1 or
        day > days_in_month(year, month) or hour > 23 or minute > 59 or
        second > 59 then
        fail("invalid timestamp")
    end

    local millis = 0
    if tail:sub(1, 1) == "." then
        local digits
        digits, tail = tail:match("^%.(%d+)(.*)$")
        if not digits or #digits > 3 then
            fail("timestamp fractional seconds must contain 1..3 digits")
        end
        millis = tonumber((digits .. "00"):sub(1, 3))
    end

    local offset_seconds = 0
    local has_explicit_zone = tail ~= ""
    if has_explicit_zone then
        if tail == "Z" or tail == "z" then
            offset_seconds = 0
        else
            local sign, offset_hour, offset_minute = tail:match(
                "^([+-])(%d%d):(%d%d)$")
            offset_hour, offset_minute = tonumber(offset_hour), tonumber(offset_minute)
            if not sign or offset_hour > 23 or offset_minute > 59 then
                fail("invalid timestamp timezone")
            end
            offset_seconds = offset_hour * 3600 + offset_minute * 60
            if sign == "-" then
                offset_seconds = -offset_seconds
            end
        end
    end

    local epoch_seconds
    if has_explicit_zone then
        epoch_seconds = days_from_civil(year, month, day) * 86400 +
            hour * 3600 + minute * 60 + second - offset_seconds
    else
        local local_epoch = os.time {
            year = year,
            month = month,
            day = day,
            hour = hour,
            min = minute,
            sec = second,
            -- Omit isdst so LuaJIT/libc can infer DST from local timezone.
            -- In Lua, numeric -1 is truthy and is treated as DST enabled.
        }
        if not local_epoch then
            fail("timestamp is outside the local time range")
        end
        local ok, roundtrip = pcall(os.date, "*t", local_epoch)
        if not ok or not roundtrip or roundtrip.year ~= year or
            roundtrip.month ~= month or roundtrip.day ~= day or
            roundtrip.hour ~= hour or roundtrip.min ~= minute or
            roundtrip.sec ~= second then
            fail("invalid or nonexistent local timestamp")
        end
        epoch_seconds = local_epoch
    end

    local deadline = epoch_seconds * 1000 + millis
    if not finite(deadline) then
        fail("timestamp is outside the supported range")
    end
    return deadline
end

local function parse_at_timestamp(value)
    if finite(value) then
        local deadline = value * 1000
        if not finite(deadline) then
            fail("timestamp is outside the supported range")
        end
        return deadline
    end
    if type(value) == "string" then
        return parse_at_string(value)
    end
    fail("timestamp must be an epoch number or date-time string")
end

local function check_integer(value, field)
    if not finite(value) or value ~= math.floor(value) then
        fail("daily " .. field .. " must be an integer")
    end
    return value
end

local function parse_daily_time(value)
    local hour, minute, second
    if type(value) == "string" then
        local hour_text, minute_text, second_text = value:match(
            "^(%d%d):(%d%d):(%d%d)$")
        if not hour_text then
            fail("daily time must use HH:MM:SS")
        end
        hour, minute, second = tonumber(hour_text), tonumber(minute_text),
            tonumber(second_text)
    elseif type(value) == "table" then
        hour = check_integer(value.hour, "hour")
        minute = value.minute == nil and 0 or check_integer(value.minute, "minute")
        second = value.second == nil and 0 or check_integer(value.second, "second")
    else
        fail("daily time must be a table or HH:MM:SS string")
    end

    if hour < 0 or hour > 23 or minute < 0 or minute > 59 or
        second < 0 or second > 59 then
        fail("daily time is outside the valid range")
    end
    return { hour = hour, minute = minute, second = second }
end

local function next_daily_deadline(spec, now_ms)
    local now_seconds = math.floor(now_ms / 1000)
    local date = os.date("*t", now_seconds)

    local function make_candidate()
        return os.time {
            year = date.year,
            month = date.month,
            day = date.day,
            hour = spec.hour,
            min = spec.minute,
            sec = spec.second,
            -- Omit isdst so the local timezone rules determine DST.
        }
    end

    local candidate = make_candidate()
    if not candidate then
        fail("daily time is outside the local time range")
    end
    if candidate * 1000 <= now_ms then
        date.day = date.day + 1
        candidate = make_candidate()
        if not candidate then
            fail("daily time is outside the local time range")
        end
    end
    return candidate * 1000
end

local function task_before(left, right)
    return left.deadline_ms < right.deadline_ms or
        (left.deadline_ms == right.deadline_ms and left.sequence < right.sequence)
end

local function swap_tasks(left, right)
    heap[left], heap[right] = heap[right], heap[left]
    heap[left].heap_index = left
    heap[right].heap_index = right
end

local function sift_up(index)
    while index > 1 do
        local parent = math.floor(index / 2)
        if not task_before(heap[index], heap[parent]) then
            break
        end
        swap_tasks(index, parent)
        index = parent
    end
end

local function sift_down(index)
    local size = #heap
    while true do
        local left = index * 2
        local right = left + 1
        local smallest = index
        if left <= size and task_before(heap[left], heap[smallest]) then
            smallest = left
        end
        if right <= size and task_before(heap[right], heap[smallest]) then
            smallest = right
        end
        if smallest == index then
            break
        end
        swap_tasks(index, smallest)
        index = smallest
    end
end

local function heap_push(task)
    local index = #heap + 1
    heap[index] = task
    task.heap_index = index
    sift_up(index)
end

local function heap_pop()
    local size = #heap
    if size == 0 then
        return nil
    end
    local root = heap[1]
    root.heap_index = nil
    if size == 1 then
        heap[1] = nil
        return root
    end
    heap[1] = heap[size]
    heap[size] = nil
    heap[1].heap_index = 1
    sift_down(1)
    return root
end

local function heap_remove(task)
    local index = task.heap_index
    local size = #heap
    if not index or index < 1 or index > size or heap[index] ~= task then
        return false
    end
    task.heap_index = nil
    if index == size then
        heap[size] = nil
        return true
    end
    heap[index] = heap[size]
    heap[size] = nil
    heap[index].heap_index = index
    if index > 1 and task_before(heap[index], heap[math.floor(index / 2)]) then
        sift_up(index)
    else
        sift_down(index)
    end
    return true
end

local function report_error(message)
    local ok, text = pcall(tostring, message)
    if not ok or type(text) ~= "string" then
        text = "unknown scheduler error"
    end
    if service.self ~= nil and type(service._log_error) == "function" then
        local ok = pcall(service._log_error, service.self, "scheduler: " .. text)
        if ok then
            return
        end
    end

    if io and io.stderr and type(io.stderr.write) == "function" then
        pcall(io.stderr.write, io.stderr, "scheduler: " .. text .. "\n")
    end
end

local function timer_result_ok(result, error_message)
    return error_message == nil and
        (result == nil or result == true or result == 0)
end

local function ensure_timer()
    local current_uv = ensure_context()
    if timer ~= nil then
        local is_closing = timer.is_closing
        if type(is_closing) == "function" then
            local ok, closing = pcall(is_closing, timer)
            if not ok then
                fail("could not inspect timer state")
            end
            if closing then
                fail("scheduler timer is already closed")
            end
        end
        return timer
    end

    local created, error_message = current_uv.new_timer()
    if not created then
        fail("could not create timer" ..
            (error_message and (": " .. tostring(error_message)) or ""))
    end
    timer = created
    return timer
end

local function stop_timer()
    if not timer or not timer_armed then
        timer_armed = false
        return
    end
    local ok, result, error_message = pcall(timer.stop, timer)
    if not ok or not timer_result_ok(result, error_message) then
        fail("could not stop timer")
    end
    timer_armed = false
end

local function arm_timer()
    if #heap == 0 then
        stop_timer()
        return
    end

    local current_timer = ensure_timer()
    local remaining = heap[1].deadline_ms - wall_now_ms()
    if remaining < 0 then
        remaining = 0
    end
    local delay = math.ceil(remaining)
    if delay > MAX_RECHECK_MS then
        delay = MAX_RECHECK_MS
    end

    if timer_armed then
        stop_timer()
    end
    local ok, result, error_message = pcall(
        current_timer.start, current_timer, delay, 0, on_timer)
    if not ok or not timer_result_ok(result, error_message) then
        fail("could not start timer")
    end
    timer_armed = true
end

local function invoke_action(task)
    local ok, error_message = xpcall(task.action, debug.traceback)
    if not ok then
        report_error(error_message)
    end
end

on_timer = function()
    if draining then
        return
    end

    timer_armed = false
    draining = true
    local ok, error_message = xpcall(function()
        local now = wall_now_ms()
        local processed = 0
        while heap[1] and heap[1].deadline_ms <= now and
            processed < MAX_TASKS_PER_TICK do
            local task = heap_pop()
            invoke_action(task)
            if task.kind == "daily" then
                task.deadline_ms = next_daily_deadline(task.daily_spec, wall_now_ms())
                sequence = sequence + 1
                task.sequence = sequence
                heap_push(task)
            end
            processed = processed + 1
            now = wall_now_ms()
        end
    end, debug.traceback)
    draining = false

    if not ok then
        report_error(error_message)
    end
    local arm_ok, arm_error = pcall(arm_timer)
    if not arm_ok then
        report_error(arm_error)
    end
end

local function enqueue(deadline_ms, kind, action, daily_spec)
    ensure_context()
    if type(action) ~= "function" then
        if type(action) == "table" then
            fail("action table is not supported yet")
        end
        fail("action must be a function")
    end

    sequence = sequence + 1
    local token = {}
    local task = {
        token = token,
        deadline_ms = deadline_ms,
        sequence = sequence,
        kind = kind,
        action = action,
        daily_spec = daily_spec,
    }

    ensure_timer()
    heap_push(task)
    if not draining then
        local ok, error_message = pcall(arm_timer)
        if not ok then
            heap_remove(task)
            if #heap == 0 then
                pcall(stop_timer)
            end
            error(error_message, 0)
        end
    end
    return token
end

function scheduler:at(timestamp, action)
    if self ~= scheduler then
        fail("at must use scheduler:at(...)", 2)
    end
    local deadline_ms = parse_at_timestamp(timestamp)
    return enqueue(deadline_ms, "at", action)
end

function scheduler:daily(time, action)
    if self ~= scheduler then
        fail("daily must use scheduler:daily(...)", 2)
    end
    local daily_spec = parse_daily_time(time)
    local deadline_ms = next_daily_deadline(daily_spec, wall_now_ms())
    return enqueue(deadline_ms, "daily", action, daily_spec)
end

return scheduler
