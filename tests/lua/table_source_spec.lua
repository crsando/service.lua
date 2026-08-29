local service = require "service"

service.input()

local table_source = [[
local S = {}

function S.echo(msg)
    return msg
end

return S
]]

local caller_source = [[
local service = require "service"

return service.dispatch(function(command, ...)
    assert(command == "boot")
    local result = assert(service.call("table-target", "echo", "hello"))
    assert(result == "hello")
    service.quit()
end)
]]

local target = service.new {
    name = "table-target",
    source = table_source,
    config = {},
}
local caller = service.new {
    name = "table-caller",
    source = caller_source,
    config = {},
}

assert(service.start(target) == 0)
assert(service.start(caller) == 0)
assert(service.send("table-caller", "boot") == true)
assert(service.join(caller) == 0)

assert(service._stop(target) == 0)
assert(service.join(target) == 0)

print("table_source_spec: ok")
