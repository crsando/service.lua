local seri = require "seri"

local shared = { value = "module" }
local ptr, size = seri.pack({ shared, shared })
local output = seri.unpack_remove(ptr, size)

assert(output[1] == output[2], "standalone serializer lost shared identity")
assert(output[1].value == "module", "standalone serializer lost table value")

print("serializer_module_spec: ok")
