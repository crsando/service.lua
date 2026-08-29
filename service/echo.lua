local service = require "service".input(...)

return service.dispatch(function (...)
    return ...
end)