local service = require "lservice3" .input(...)
local inspect = require "inspect"


-- local timer = service.uv.new_timer()
-- timer:start(0, 0, function()
--   print("hello")
--   timer:stop()
--   timer:close()
-- end)

local S = {}

function S.check(id)
    print("user check", id)
end

function S.ping(id)
    print("ping get id", id)
    -- service.uv.sleep(5000)

    service.sleep(5000)

    if id then
        service.call(id, "pong")
    end

    return "PONG"
end

function S.quit()
    print("user is quitting")
    service.quit()
end

return service.dispatch(S)