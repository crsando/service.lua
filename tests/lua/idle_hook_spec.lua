local service = require "service"

-- Each round ends with service.on_idle, then the hooks in registration order.
-- Rounds are forced with loopback; sleep lets the round finish before checking.
local ok, err = service.bootstrap { source = [[
local service = require "service"
local log = {}

local function check(expected)
    local got = table.concat(log, ",")
    if got ~= expected then
        service.quit("expected " .. expected .. ", got " .. got)
    end
    log = {}
end

local function next_round()
    assert(service.loopback("noop"))
    service.sleep(10)
end

local S = {}
function S.noop() end
function S.boot()
    service.on_idle = function() log[#log + 1] = "legacy" end
    local remove_a = service.add_idle_hook(function() log[#log + 1] = "a" end)
    local remove_b = service.add_idle_hook(function() log[#log + 1] = "b" end)
    local c = function() log[#log + 1] = "c" end
    local remove_c1 = service.add_idle_hook(c)
    service.add_idle_hook(c)
    service.sleep(10)
    check("legacy,a,b,c,c")

    remove_b()
    remove_b()
    next_round()
    check("legacy,a,c,c")

    remove_c1()
    service.on_idle = nil
    next_round()
    check("a,c")

    remove_a()
    next_round()
    check("c")

    assert(not pcall(service.add_idle_hook, 42))
    service.quit()
end
return S
]] }
assert(ok == true, tostring(err))

-- An error in a hook stops the service, like an error in service.on_idle.
ok, err = service.bootstrap { source = [[
local service = require "service"
local S = {}
function S.boot()
    service.add_idle_hook(function() error("hook exploded", 0) end)
end
return S
]] }
assert(ok == nil and tostring(err):find("hook exploded", 1, true), tostring(err))

print("idle_hook_spec: ok")
