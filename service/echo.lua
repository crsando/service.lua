-- Echo service: the function form of service.dispatch receives (command, ...).
local service = require "service"

return service.dispatch(function(command, ...)
    if command == "echo" then
        return ...
    elseif command == "quit" then
        service.quit()
        return true
    end
    error("unknown command: " .. tostring(command))
end)
