local service = require "service"
local root = require "service.root"

function root.boot()
    service.quit()
end
