local service = require "lservice3"

local source = [[
local service = require "lservice3" .input(...)

local S = {}

function S.echo(...)
    return ...
end

function S.boot()
    local text, number = service.call(service.get_id(), "echo", "pong", 42)
    assert(text == "pong")
    assert(number == 42)
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
