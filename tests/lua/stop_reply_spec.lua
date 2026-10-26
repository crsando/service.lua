local service = require "service"

-- When a service stops, every request it accepted but did not answer gets an
-- ERROR, so call returns nil, "service stopped" instead of hanging.
local TARGET = [[
local service = require "service"
local S = {}
function S.ping() return "pong" end
-- Keeps the thread busy, then quits with later requests still queued.
function S.busy_quit(ms)
    local t = service.uv.hrtime()
    while service.uv.hrtime() - t < ms * 1e6 do end
    service.quit()
end
function S.wait() service.sleep(60000) end
function S.quit() service.quit() end
function S.explode()
    service.add_idle_hook(function() error("idle exploded", 0) end)
end
return S
]]

local ok, err = service.bootstrap { source = string.format([[
local service = require "service"
local TARGET = %q
local S = {}
local results = {}

local function check(label, r, e)
    if r ~= nil or e ~= "service stopped" then
        service.quit(label .. ": expected nil, service stopped; got " ..
            tostring(r) .. ", " .. tostring(e))
        return false
    end
    return true
end

function S.call_into(slot, target, ...)
    results[slot] = { service.call(target, ...) }
end

local function wait_for(slot)
    for _ = 1, 500 do
        if results[slot] then return unpack(results[slot]) end
        service.sleep(10)
    end
    return "timeout"
end

function S.boot()
    -- Queued request: never handled, answered while draining the mailbox.
    local t1 = service.spawn { source = TARGET }
    assert(service.send(t1, "busy_quit", 100))
    if not check("queued", service.call(t1, "ping")) then return end

    -- In-flight request suspended in sleep when the target quits.
    local t2 = service.spawn { source = TARGET }
    service.loopback("call_into", "inflight", t2, "wait")
    service.sleep(20)
    assert(service.send(t2, "quit"))
    if not check("in-flight", wait_for("inflight")) then return end

    -- In-flight request when the target stops because its dispatcher fails.
    local t3 = service.spawn { source = TARGET }
    service.loopback("call_into", "failed", t3, "wait")
    service.sleep(20)
    assert(service.send(t3, "explode"))
    if not check("dispatcher failure", wait_for("failed")) then return end

    -- Calls after the stop fail immediately.
    local r, e = service.call(t2, "ping")
    if r ~= nil or (e ~= "service not found" and e ~= "service stopped" and
        e ~= "service stopping") then
        service.quit("after stop: got " .. tostring(r) .. ", " .. tostring(e))
        return
    end
    service.quit()
end
return S
]], TARGET) }
assert(ok == true, tostring(err))

print("stop_reply_spec: ok")
