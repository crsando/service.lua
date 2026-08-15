local service = require "lservice3"

local shared = { value = "shared" }
local ptr, size = service.pack({ shared, shared })
local output = service.unpack_remove(ptr, size)

assert(output[1] == output[2], "shared table identity was not preserved")
assert(output[1].value == "shared", "shared table value was not preserved")

local many = {}
for i = 1, 40 do
    local item = { index = i }
    many[#many + 1] = item
    many[#many + 1] = item
end

ptr, size = service.pack(many)
output = service.unpack_remove(ptr, size)

for i = 1, 40 do
    local left = output[(i - 1) * 2 + 1]
    local right = output[(i - 1) * 2 + 2]
    assert(left == right, "shared reference identity lost at index " .. i)
    assert(left.index == i, "shared reference value lost at index " .. i)
end

print("serializer_shared_ref_spec: ok")
