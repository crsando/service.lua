local service = require "lservice3"

local source = [[
local service = require "lservice3" .input(...)
local received = 0

return service.dispatch(function(command)
    assert(command == "item")
    received = received + 1
    if received == 16 then
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

for _ = 1, 16 do
    assert(service.send(0, "item") == true)
end

local ok, err = service.send(0, "item")
assert(ok == nil and err == "MAILBOX_FULL")

service.start(addr)
service.join(addr)
print("mailbox_spec: ok")
