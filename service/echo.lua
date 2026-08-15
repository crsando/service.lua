local service = require "lservice3".input(...)

return service.dispatch(function (...)
    return ...
end)