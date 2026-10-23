local service = require "service"
local root = require "service.root"

function root.boot()
    error("boot exploded", 0)
end

return root
