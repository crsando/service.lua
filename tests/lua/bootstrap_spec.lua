local service = require "service"

-- A child that never quits on its own; bootstrap must stop and join it.
local CHILD = [[
local service = require "service"
local uv = require "luv"
uv.new_timer():start(0, 10, function() end)
return { ping = function() return "pong" end }
]]

local function root(body)
    return string.format([[
local service = require "service"
local CHILD = %q
local S = {}
function S.boot()
%s
end
return S
]], CHILD, body)
end

-- Success: returns true, stops children that never quit, resets the host pool.
local ok, err = service.bootstrap { source = root [[
    service.spawn { name = "child", source = CHILD }
    assert(service.call("child", "ping") == "pong")
    service.quit()
]] }
assert(ok == true and err == nil, tostring(err))
assert(service.pool == nil, "bootstrap must not leave a deleted pool behind")

-- The start command is configurable.
ok, err = service.bootstrap { start = "go", source = [[
local service = require "service"
return { go = function() service.quit() end }
]] }
assert(ok == true, tostring(err))

-- args are passed to the entry command, nil holes included.
ok, err = service.bootstrap { args = { "a", nil, "c", n = 3 }, source = [[
local service = require "service"
return { boot = function(...)
    local n = select("#", ...)
    local a, b, c = ...
    if n == 3 and a == "a" and b == nil and c == "c" then
        service.quit()
    else
        service.quit("bad args: " .. n)
    end
end }
]] }
assert(ok == true, tostring(err))
assert(not pcall(service.bootstrap, { source = "return {}", args = "x" }))

-- Entry handler error: root stops with that error, children are reclaimed.
ok, err = service.bootstrap { source = root [[
    service.spawn { name = "child", source = CHILD }
    service.sleep(1)
    error("entry exploded", 0)
]] }
assert(ok == nil and err == "entry exploded", tostring(err))

-- Unknown entry command.
ok, err = service.bootstrap { start = "missing", source = root "service.quit()" }
assert(ok == nil and err == "command not found", tostring(err))

-- Root reports its own failure through quit(err).
ok, err = service.bootstrap { source = root [[
    service.quit("config invalid")
]] }
assert(ok == nil and err == "config invalid", tostring(err))

-- Dispatcher-level failure (on_idle error) stops root with that error.
ok, err = service.bootstrap { source = [[
local service = require "service"
local S = {}
function S.boot()
    service.on_idle = function() error("idle exploded", 0) end
end
return S
]] }
assert(ok == nil and tostring(err):find("idle exploded", 1, true), tostring(err))

-- Start failure is returned rather than thrown.
ok, err = service.bootstrap { source = "this is not lua" }
assert(ok == nil and tostring(err):find("SERVICE_START_FAILED", 1, true), tostring(err))

-- bootstrap is host-only and validates its entry.
assert(not pcall(service.bootstrap, {}))
assert(not pcall(service.bootstrap, { source = "return {}", start = 1 }))

print("bootstrap_spec: ok")
