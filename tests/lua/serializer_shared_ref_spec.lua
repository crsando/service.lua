local service = require "lservice3"

local function round_trip(...)
    local ptr, size = service.pack(...)
    return service.unpack_remove(ptr, size)
end

local shared = { value = "shared" }
local output = round_trip({ shared, shared })

assert(output[1] == output[2], "shared table identity was not preserved")
assert(output[1].value == "shared", "shared table value was not preserved")

local top_left, top_right = round_trip(shared, shared)
assert(top_left == top_right, "top-level shared argument identity was not preserved")

for _, count in ipairs({ 1, 31, 32, 33, 1000 }) do
    local many = {}
    for i = 1, count do
        local item = { index = i }
        many[#many + 1] = item
        many[#many + 1] = item
    end

    output = round_trip(many)
    for i = 1, count do
        local left = output[(i - 1) * 2 + 1]
        local right = output[(i - 1) * 2 + 2]
        assert(left == right, "shared reference identity lost at index " .. i)
        assert(left.index == i, "shared reference value lost at index " .. i)
    end
end

local first = { name = "first" }
local second = { name = "second" }
first.peer = second
second.peer = first

output = round_trip({ first, first, second })
assert(output[1] == output[2], "mixed graph shared identity was not preserved")
assert(output[1].peer == output[3], "mixed graph forward edge was not preserved")
assert(output[3].peer == output[1], "mixed graph cycle was not preserved")

local key = { name = "key" }
output = round_trip({ [key] = key, value = key })
local decoded_key = next(output)
if decoded_key == "value" then
    decoded_key = next(output, decoded_key)
end
assert(type(decoded_key) == "table", "shared table key was not decoded")
assert(decoded_key == output.value, "shared key/value identity was not preserved")
assert(output[decoded_key] == decoded_key, "shared table key lookup was not preserved")

print("serializer_shared_ref_spec: ok")
