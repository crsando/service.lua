-- Runs each case in a child process so that the logger's environment-driven
-- defaults are read fresh, and checks what reaches stderr.
local script_path = os.tmpname()
local out_path = os.tmpname()

-- os.execute returns 0 in Lua 5.1 and true with 5.2 compatibility.
local function succeeded(result)
    return result == 0 or result == true
end

local function run(env, source)
    local f = assert(io.open(script_path, "w"))
    f:write(source)
    f:close()
    local cmd = string.format(
        "env -u SERVICE_LOG_LEVEL -u SERVICE_LOG_FORMAT -u JOURNAL_STREAM %s luajit %s 2>%s",
        env, script_path, out_path)
    assert(succeeded(os.execute(cmd)), "child failed: " .. cmd)
    f = assert(io.open(out_path))
    local out = f:read("*a")
    f:close()
    return out
end

local function expect(out, pattern, label)
    assert(out:find(pattern), label .. ": missing " .. pattern .. " in:\n" .. out)
end

local function reject(out, pattern, label)
    assert(not out:find(pattern), label .. ": unexpected " .. pattern .. " in:\n" .. out)
end

-- A service that logs at every level, then answers one failing call.
local SOURCE = [[
local service = require "service"
%s
local ok = service.bootstrap { source = %q }
assert(ok)
]]
local ROOT = [[
local service = require "service"
local S = {}
function S.fail() error("business failure", 0) end
function S.boot()
    service.log.debug("debug-line")
    service.log.info("info-line\t%d\t%s", 42, nil)
    service.log.info("literal 100%% %s")
    service.log.info("fmt %.2f|%5s|%x|%s", 3.14159, "ab", 255, {})
    service.log.info("bad %d", "x")
    service.log.warn("warn-line")
    service.log.error("error-line")
    assert(service.call(service.get_id(), "fail") == nil)
    service.quit()
end
return S
]]

local function case(env, config)
    return run(env, SOURCE:format(config or "", ROOT))
end

-- Default: info and above, text format, real Lua location, service tag.
local out = case("")
reject(out, "debug%-line", "default")
-- printf-style formatting; a lone argument is logged verbatim.
expect(out, "%] literal 100%%%% %%s\n", "default")
expect(out, "%] fmt 3%.14|   ab|ff|table: 0x%x+\n", "default")
-- A bad format logs the raw arguments instead of raising.
expect(out, "%] bad %%d\tx %(log format error: [^\n]*%)\n", "default")
expect(out, '%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%.%d%d%d INFO  %[string "[^\n]-%.%.%."%]:6: %[svc 0%] info%-line\t42\tnil\n', "default")
expect(out, "ERROR [^\n]*%[svc 0%] error%-line", "default")
-- The callee's error goes back to the caller, so it is only a warning.
expect(out, "WARN  %[svc 0%] business failure\nstack traceback:", "default")

-- off silences everything, including runtime records.
out = case("SERVICE_LOG_LEVEL=off")
assert(out == "", "off: expected no output, got:\n" .. out)

-- journal format: priority prefix on every line, no timestamp.
out = case("SERVICE_LOG_LEVEL=debug SERVICE_LOG_FORMAT=journal")
expect(out, "^<7>[^\n]*%[svc 0%] debug%-line\n", "journal")
expect(out, "\n<6>[^\n]*info%-line", "journal")
expect(out, "\n<3>[^\n]*error%-line", "journal")
expect(out, "\n<4>%[svc 0%] business failure\n<4>stack traceback:", "journal")
reject(out, "%d%d:%d%d:%d%d", "journal")

-- journal is picked automatically when stderr is the JOURNAL_STREAM target.
if succeeded(os.execute("stat -c %d:%i / >/dev/null 2>&1")) then
    local f = assert(io.open(script_path, "w"))
    f:write('require "service"._log(nil, "info", "auto")\n')
    f:close()
    local cmd = string.format(
        "touch %s && env -u SERVICE_LOG_FORMAT JOURNAL_STREAM=$(stat -c %%d:%%i %s) luajit %s 2>>%s",
        out_path, out_path, script_path, out_path)
    os.remove(out_path)
    assert(succeeded(os.execute(cmd)), cmd)
    f = assert(io.open(out_path))
    out = f:read("*a")
    f:close()
    assert(out == "<6>[host] auto\n", "auto journal: got " .. out)
end

-- log_config overrides the environment and reports the effective settings.
out = case("SERVICE_LOG_LEVEL=off", [[
local level, format = service.log_config { level = "warn", format = "journal" }
assert(level == "warn" and format == "journal")
service.log.info("host-info")
service.log.warn("host-warn")
]])
reject(out, "info", "log_config")
expect(out, "^<4>[^\n]*%[host%] host%-warn\n", "log_config")
expect(out, "\n<3>[^\n]*error%-line", "log_config")

-- Invalid settings are rejected without applying either one.
out = run("", [[
local service = require "service"
assert(not pcall(service.log_config, { level = "verbose" }))
assert(not pcall(service.log_config, { level = "debug", format = "xml" }))
assert(service.log_config {} == "info")
]])
assert(out == "", "invalid config: " .. out)

-- Level and format names ignore case, in the environment and in log_config;
-- log_config reports them in lower case.
out = case("SERVICE_LOG_LEVEL=WARN SERVICE_LOG_FORMAT=Journal")
reject(out, "info%-line", "env case")
expect(out, "\n<3>[^\n]*error%-line", "env case")
out = run("", [[
local service = require "service"
local level, format = service.log_config { level = "Error", format = "TEXT" }
assert(level == "error" and format == "text", tostring(level) .. " " .. tostring(format))
assert(service._log_enabled("ERROR") and not service._log_enabled("Warn"))
]])
assert(out == "", "log_config case: " .. out)

-- An invalid environment value is reported and ignored.
out = run("SERVICE_LOG_LEVEL=loud", [[
require "service".log.info("still-info")
]])
expect(out, "WARN  ignoring invalid SERVICE_LOG_LEVEL: loud\n", "invalid env")
expect(out, "INFO  [^\n]*still%-info", "invalid env")

os.remove(script_path)
os.remove(out_path)
print("log_spec: ok")
