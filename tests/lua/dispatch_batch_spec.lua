local service = require "lservice3"

local exact_batch_source = [[
local service = require "lservice3" .input(...)

local processed = 0
local idle_calls = 0

service.on_idle = function()
    idle_calls = idle_calls + 1
end

local S = {}

function S.tick()
    processed = processed + 1
end

function S.boot(count)
    local idle_before_batch = idle_calls

    for _ = 1, count do
        assert(service.loopback("tick"))
    end

    service.sleep(0)
    if processed ~= count or idle_calls ~= idle_before_batch + 1 then
        return
    end
    service.quit()
end

return service.dispatch(S)
]]

local fairness_source = [[
local service = require "lservice3" .input(...)

local processed = 0
local total = 0
local idle_calls = 0
local idle_before_batch = 0
local fairness_checked = false

service.on_idle = function()
    idle_calls = idle_calls + 1
    if fairness_checked and processed == total and
        idle_calls == idle_before_batch + 4 then
        service.quit()
    end
end

local S = {}

function S.tick()
    processed = processed + 1
end

function S.boot(count)
    total = count
    idle_before_batch = idle_calls
    for _ = 1, total do
        assert(service.loopback("tick"))
    end

    service.sleep(0)
    if processed >= total or idle_calls == idle_before_batch then
        return
    end
    fairness_checked = true
end

return service.dispatch(S)
]]

service.input()

local exact_batch = service.new {
    name = "exact-batch",
    source = exact_batch_source,
    config = {},
}
assert(service.start(exact_batch) == 0)
assert(service.send("exact-batch", "boot", 255))
assert(service.join(exact_batch) == 0)

local fairness = service.new {
    name = "batch-fairness",
    source = fairness_source,
    config = {},
}
assert(service.start(fairness) == 0)
assert(service.send("batch-fairness", "boot", 768))
assert(service.join(fairness) == 0)

print("dispatch_batch_spec: ok")
