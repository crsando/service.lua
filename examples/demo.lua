local service = require "lservice3"

--[[
local root_addr = service.new { source = "@service/root.lua", config = { accounts = accounts } }

service.start(root_addr)
service.send(service.get_id(root_id), "boot")
service.join(root_addr)
]]

service.bootstrap {
    source = "@service/root.lua",
    config = {},
    start = "boot"
}