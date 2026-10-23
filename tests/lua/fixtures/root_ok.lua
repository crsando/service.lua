local service = require "service"
local root = require "service.root"

-- Only runs in the root VM: the host exits inside require "service.root".
local CHILD = [[
local service = require "service"
local child = require "service.root"
function child.echo(...) return ... end
return child
]]

function root.boot(...)
    service.spawn { name = "child", source = CHILD }
    print("args:", select("#", ...), ...)
    print("child:", service.call("child", "echo", "hi"))
    service.quit()
end

return root
