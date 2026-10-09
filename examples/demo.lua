-- Run from the repository root:
--   LUA_PATH='./lua/?.lua;;' LUA_CPATH='./build/?.so;;' luajit examples/demo.lua
local service = require "service"

-- Create root, send it "boot", and join it. root must call service.quit()
-- itself; bootstrap returns once the root pthread has exited.
service.bootstrap {
    source = "@service/root.lua",
    config = { greeting = "hello" },
    start = "boot",
}
