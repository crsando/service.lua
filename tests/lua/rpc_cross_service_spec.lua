local service = require "lservice3"

local target_source = [[
local service = require "lservice3" .input(...)

local S = {}

function S.values()
    return "pong", nil, 42, nil
end

function S.echo(...)
    return ...
end

function S.fail()
    error("cross-service handler failed", 0)
end

function S.fail_after_sleep()
    service.sleep(0)
    error("cross-service delayed failure", 0)
end

function S.nested(caller)
    local value = assert(service.call(caller, "callback", "from-target"))
    return "nested", value
end

function S.shutdown()
    service.quit()
    return "stopping"
end

return service.dispatch(S)
]]

local caller_source = [[
local service = require "lservice3" .input(...)

local S = {}
local completed = 0
local request_count

local function capture(...)
    return { n = select("#", ...), ... }
end

function S.callback(value)
    return "callback:" .. value
end

function S.probe(index)
    local label, echoed = service.call("target", "echo", "load", index)
    assert(label == "load")
    assert(echoed == index)

    completed = completed + 1
    if completed == request_count then
        assert(service.call("target", "shutdown") == "stopping")
        service.quit()
    end
end

function S.boot(count)
    local values = capture(service.call("target", "values"))
    assert(values.n == 4)
    assert(values[1] == "pong")
    assert(values[2] == nil)
    assert(values[3] == 42)
    assert(values[4] == nil)

    local failed, fail_err = service.call("target", "fail")
    assert(failed == nil)
    assert(fail_err == "cross-service handler failed")

    local delayed, delayed_err = service.call("target", "fail_after_sleep")
    assert(delayed == nil)
    assert(delayed_err == "cross-service delayed failure")

    local missing, missing_err = service.call("target", "missing")
    assert(missing == nil)
    assert(missing_err == "command not found")

    local nested, callback = service.call("target", "nested", service.get_id())
    assert(nested == "nested")
    assert(callback == "callback:from-target")

    request_count = count
    for index = 1, request_count do
        assert(service.loopback("probe", index))
    end
end

return service.dispatch(S)
]]

service.input()

local caller = service.new {
    name = "caller",
    source = caller_source,
    config = {},
}
local target = service.new {
    name = "target",
    source = target_source,
    config = {},
}

assert(service.start(target) == 0)
assert(service.start(caller) == 0)
assert(service.send("caller", "boot", 128))
assert(service.join(caller) == 0)
assert(service.join(target) == 0)

print("rpc_cross_service_spec: ok")
