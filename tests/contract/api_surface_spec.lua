local service = require "lservice3"
local native = require "lservice3_c"

local function assert_functions(module, names, label)
    for _, name in ipairs(names) do
        assert(
            type(module[name]) == "function",
            string.format("%s.%s must be a function", label, name)
        )
    end
end

assert_functions(service, {
    "new",
    "start",
    "join",
    "spawn",
    "get_uv_loop",
    "get_id",
    "lookup",
    "get_async",
    "get_pool",
    "get_addr",
    "input",
    "send_message",
    "recv_message",
    "resume_session",
    "send",
    "loopback",
    "call",
    "get_session",
    "quit",
    "dispatch",
    "bootstrap",
    "sleep",
    "set_timeout",
    "pack",
    "unpack",
    "unpack_remove",
    "remove",
}, "lservice3")

assert_functions(native, {
    "_pool_new",
    "_lookup",
    "_get_pool",
    "_get_async",
    "_get_addr",
    "_get_uv_loop",
    "_new",
    "_start",
    "_stop",
    "_join",
    "_get_id",
    "_send_message",
    "_recv_message",
    "_log_error",
    "pack",
    "unpack",
    "unpack_remove",
    "remove",
}, "lservice3_c")

assert(type(service.uv) == "table", "service.uv must be the luv module")
assert(service.yield_session == coroutine.yield, "yield_session compatibility alias changed")

local ptr, size = service.pack("contract", 3)
assert(type(ptr) == "userdata", "pack must return a lightuserdata pointer")
assert(type(size) == "number" and size > 0, "pack must return a positive size")

local text, number = service.unpack_remove(ptr, size)
assert(text == "contract" and number == 3, "serializer ABI smoke test failed")

assert(service.input() == service, "input must return the same module table")
assert(service.self == nil, "standalone input must clear service.self")
assert(type(service.config) == "table", "standalone config must be an empty table")

local fake_self, fake_self_size = service.pack("recv-message-contract")
local native_recv_message = service._recv_message
local observed_blocking

service.self = fake_self
service._recv_message = function(actual_self, blocking)
    assert(actual_self == fake_self, "recv_message must forward service.self")
    observed_blocking = blocking
end

service.recv_message(false)
assert(observed_blocking == false, "recv_message(false) must preserve false")
service.recv_message()
assert(observed_blocking == true, "recv_message() must preserve the compatibility default")

service._recv_message = native_recv_message
service.self = nil
service.remove(fake_self, fake_self_size)

print("api_surface_spec: ok")
