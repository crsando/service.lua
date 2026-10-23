-- Runs fixture scripts in a child luajit and checks output and exit code.
local FIXTURES = "tests/lua/fixtures/"

local function run(command)
    local pipe = assert(io.popen(
        "LUA_PATH='./" .. FIXTURES .. "?.lua;'\"$LUA_PATH\" " ..
        command .. " 2>&1; echo \"exit=$?\""))
    local output = pipe:read("*a")
    pipe:close()
    local body, code = output:match("^(.-)exit=(%d+)%s*$")
    return body, tonumber(code)
end

local function expect(command, code, pattern)
    local output, actual = run(command)
    assert(actual == code, string.format("%s: exit %s, want %d\n%s",
        command, tostring(actual), code, output))
    assert(output:find(pattern, 1, true), string.format(
        "%s: output missing %q\n%s", command, pattern, output))
end

-- Running the file bootstraps it as root and forwards the arguments.
expect("luajit " .. FIXTURES .. "root_ok.lua a b", 0, "args:\t2\ta\tb")
expect("luajit " .. FIXTURES .. "root_ok.lua", 0, "child:\thi")

-- Failures are reported on stderr with exit code 1.
expect("luajit " .. FIXTURES .. "root_fail.lua", 1, "service.root: boot exploded")
expect("luajit " .. FIXTURES .. "root_noboot.lua", 1, "service.root: command not found")
expect("luajit " .. FIXTURES .. "root_noreturn.lua", 1, "service.root: SERVICE_START_FAILED")

-- Only the top level of the script being run may require service.root.
expect("luajit " .. FIXTURES .. "root_indirect.lua", 1,
    "must be required by the script being run")
expect("luajit " .. FIXTURES .. "root_indirect_tail.lua", 1,
    "service.root: SERVICE_START_FAILED")
expect("luajit " .. FIXTURES .. "root_in_function.lua", 1,
    "must be required at the top level")
expect("luajit -e 'require \"service.root\"'", 1,
    "must be required at the top level")

-- Plain require "service" never bootstraps.
expect("luajit -e 'require \"service\" print(\"library\")'", 0, "library")

print("root_spec: ok")
