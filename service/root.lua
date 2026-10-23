-- Root service of the demo. Run it directly from the repository root:
--
--   LUA_PATH='./lua/?.lua;;' LUA_CPATH='./build/?.so;;' luajit service/root.lua [greeting]
--
-- require "service.root" starts this file as the root service and exits the
-- process when root quits; everything below it only runs inside root.
local service = require "service"
local root = require "service.root"

function root.pong(from)
    print("root: pong from service " .. tostring(from))
end

-- Entry point; receives the command line arguments.
function root.boot(greeting)
    print("root: booting, greeting = " .. tostring(greeting or "hello"))

    service.spawn { name = "echo", source = "@service/echo.lua" }
    service.spawn { name = "user", source = "@service/user.lua", config = { delay_ms = 100 } }

    -- call returns every value the handler returns, including nil in the middle.
    print("root: echo ->", service.call("echo", "echo", "hi mountain", nil, 42))

    -- Unknown commands and handler errors come back as nil, error_msg.
    print("root: echo bad ->", service.call("echo", "nope"))

    -- send is one-way: true only means the target mailbox accepted it.
    assert(service.send("user", "check", "fire-and-forget"))

    -- user sleeps and then calls back into root while root is still waiting
    -- here; the root loop keeps serving root.pong meanwhile (re-entrant actor).
    print("root: user ping ->", service.call("user", "ping", service.get_id()))

    -- Shut down children first and wait for their acknowledgement, then stop
    -- root, which ends the program.
    assert(service.call("user", "quit"))
    assert(service.call("echo", "quit"))
    print("root: done")
    service.quit()
end

return root
