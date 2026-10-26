-- Makes the requiring script runnable as the root service:
--
--   local service = require "service"
--   local root = require "service.root"
--   function root.boot(...) ... end
--   return root
--
-- Inside a service VM this module is just an empty handler table. On the
-- host thread it bootstraps the requiring file as root, passes the command
-- line arguments to root.boot and exits the process with 0 or 1.
local service = require "service"

if service.self ~= nil then
    return {}
end

local function fail(message)
    error("service.root: " .. message, 0)
end

-- The first Lua frame above require is the file that required us. Level 1
-- is this function and level 2 is this module's chunk.
local function requiring_frame()
    local level = 3
    while true do
        local info = debug.getinfo(level, "S")
        if info == nil then
            return nil
        end
        if info.what ~= "C" then
            return info
        end
        level = level + 1
    end
end

local caller = requiring_frame()
if caller == nil or caller.what ~= "main" or caller.source:sub(1, 1) ~= "@" then
    fail("must be required at the top level of the script being run")
end
if arg and arg[0] and caller.source ~= "@" .. arg[0] then
    fail("must be required by the script being run (" .. tostring(arg[0]) ..
        "), not by " .. caller.source:sub(2))
end

local args = { n = 0 }
if arg then
    args.n = #arg
    for i = 1, args.n do
        args[i] = arg[i]
    end
end

local ok, err = service.bootstrap { source = caller.source, args = args }
if not ok then
    service._log(nil, "error", "service.root: " .. tostring(err))
end
os.exit(ok and 0 or 1)
