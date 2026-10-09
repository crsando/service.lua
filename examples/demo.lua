-- Run from the repository root:
--   LUA_PATH='./lua/?.lua;;' LUA_CPATH='./build/?.so;;' luajit examples/demo.lua
local service = require "service"

-- Run root's "boot" command and wait until root calls service.quit(). Any
-- service still running is then stopped. Returns nil, err if root failed.
assert(service.bootstrap {
    source = "@service/root.lua",
    config = { greeting = "hello" },
    start = "boot",
})
