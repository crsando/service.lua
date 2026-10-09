-- Root service: spawns the demo children, exercises send/call/sleep and
-- shuts everything down in order.
--
-- The runtime binds service.self/pool/config before this file runs, so no
-- service.input(...) call is needed. Returning a handler table is equivalent
-- to returning service.dispatch(S).
local service = require "service"

local S = {}

function S.pong(from)
    print("root: pong from service " .. tostring(from))
end

function S.boot()
    print("root: booting, greeting = " .. tostring(service.config.greeting))

    service.spawn { name = "echo", source = "@service/echo.lua" }
    service.spawn { name = "user", source = "@service/user.lua", config = { delay_ms = 100 } }

    -- call returns every value the handler returns, including nil in the middle.
    print("root: echo ->", service.call("echo", "echo", "hi mountain", nil, 42))

    -- Unknown commands and handler errors come back as nil, error_msg.
    print("root: echo bad ->", service.call("echo", "nope"))

    -- send is one-way: true only means the target mailbox accepted it.
    assert(service.send("user", "check", "fire-and-forget"))

    -- user sleeps and then calls back into root while root is still waiting
    -- here; the root loop keeps serving S.pong meanwhile (re-entrant actor).
    print("root: user ping ->", service.call("user", "ping", service.get_id()))

    -- Shut down children first and wait for their acknowledgement, then stop
    -- root. The host thread is joining root, so this ends the program.
    assert(service.call("user", "quit"))
    assert(service.call("echo", "quit"))
    print("root: done")
    service.quit()
end

return S
