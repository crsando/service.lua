-- User service: shows service.config, service.sleep and a nested call back
-- into the caller.
local service = require "service"

local delay_ms = service.config.delay_ms or 0

local S = {}

function S.check(tag)
    print("user: check " .. tostring(tag))
end

function S.ping(caller)
    service.sleep(delay_ms)
    if caller then
        service.call(caller, "pong", service.get_id())
    end
    return "PONG"
end

function S.quit()
    print("user: quitting")
    service.quit()
    return true
end

return S
