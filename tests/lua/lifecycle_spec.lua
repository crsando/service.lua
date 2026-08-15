local service = require "lservice3"

local source = [[
local service = require "lservice3" .input(...)

return service.dispatch(function(command)
    assert(command == "boot")
    service.quit()
    return "done"
end)
]]

service.input()
local addr = service.new {
    source = source,
    config = {},
}
local id = service.get_id(addr)

assert(service.start(addr) == 0)
assert(service.send(id, "boot") == true)
assert(service.join(addr) == 0)
assert(service.join(addr) == 0)

local ok, err = service.send(id, "late")
assert(ok == nil and err == "SERVICE_STOPPED")
ok, err = service.send(99, "invalid")
assert(ok == nil and err == "SERVICE_NOT_FOUND")
assert(service.lookup("root") == nil)

local bad = service.new {
    source = "error('expected init failure')",
    config = {},
}
ok, err = pcall(service.start, bad)
assert(ok == false and tostring(err):find("SERVICE_START_FAILED", 1, true))

print("lifecycle_spec: ok")
