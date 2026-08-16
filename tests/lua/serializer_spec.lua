local service = require "lservice3"

local function assert_equal(actual, expected, label)
    if actual ~= expected then
        error(string.format(
            "%s: expected %s, got %s",
            label,
            tostring(expected),
            tostring(actual)
        ))
    end
end

local binary = "hello\0world"
local input = {
    enabled = true,
    nested = { answer = 42 },
}

local ptr, size = service.pack("ok", -12.5, binary, input)
local text, number, decoded_binary, output = service.unpack_remove(ptr, size)

assert_equal(text, "ok", "string round trip")
assert_equal(number, -12.5, "number round trip")
assert_equal(decoded_binary, binary, "binary string round trip")
assert_equal(output.enabled, true, "boolean round trip")
assert_equal(output.nested.answer, 42, "nested table round trip")

local numeric_keys = {
    [1] = "array",
    [1.25] = "fractional",
}

ptr, size = service.pack(numeric_keys)
local decoded_numeric_keys = service.unpack_remove(ptr, size)
assert_equal(decoded_numeric_keys[1], "array", "integer array key")
assert_equal(decoded_numeric_keys[1.25], "fractional", "fractional hash key")

local projected = setmetatable({}, {
    __pairs = function()
        return next, { visible = "metapairs" }, nil
    end,
})

ptr, size = service.pack(projected)
local decoded_projected = service.unpack_remove(ptr, size)
assert_equal(decoded_projected.visible, "metapairs", "__pairs serialization")

local cycle = { name = "cycle" }
cycle.self = cycle

ptr, size = service.pack(cycle)
local decoded_cycle = service.unpack_remove(ptr, size)
assert_equal(decoded_cycle.self, decoded_cycle, "cycle identity")

print("serializer_spec: ok")
