# 使用指南

本文从使用者角度介绍如何编写、启动和关闭 service，以及实际项目中常用的几种模式。完整的函数签名见 [API 参考](api.md)。

## 1. 心智模型

- **service = 线程 + VM + loop + 邮箱。** service 内的所有 Lua 代码都只在它自己的线程上运行，不需要加锁。
- **消息是值拷贝。** `send` 和 `call` 的参数会被序列化后放进目标邮箱，目标拿到的是副本。table 内容可以传递，但 Lua 函数、coroutine 和 full userdata 不能传递。
- **每条请求一个 coroutine。** 收到请求后，运行时为它创建一个 coroutine 并执行 handler。handler 调用 `service.call` 或 `service.sleep` 时会挂起，这期间 service 继续处理其他消息。
- **可重入，而不是 run-to-completion。** handler 在 `call` 或 `sleep` 之后恢复时，service 的局部状态可能已被其他请求修改。需要原子性的逻辑不要跨越 `call` 或 `sleep`。
- **宿主线程不是 service。** 执行入口脚本的线程处于 standalone 上下文，只用来创建、启动 root 并等待它退出。

## 2. 编写一个 service

service source 是一段 Lua 代码，可以是 `@path/to/file.lua`（相对于进程当前目录），也可以是源码字符串。

运行时在执行 source 之前已经完成以下准备，source 中直接 `require "service"` 即可使用：

- 绑定 `service.self`、`service.pool`；
- 把 `config` 解包到 `service.config`（没有 config 时为 `{}`）；
- `require "luv"` 返回绑定到本 service loop 的 luv。

source 必须返回以下两种之一：

**handler table**：第一个参数是命令名，在 table 中查找对应函数。

```lua
local service = require "service"

local S = {}

function S.add(a, b)
    return a + b
end

function S.quit()
    service.quit()
    return true
end

return S        -- 等价于 return service.dispatch(S)
```

**dispatcher 函数**：用 `service.dispatch(function(command, ...) ... end)` 生成。

```lua
local service = require "service"

return service.dispatch(function(command, ...)
    if command == "echo" then
        return ...
    end
    error("unknown command: " .. tostring(command))
end)
```

handler 的全部返回值（包括中间和末尾的 nil）都会原样回到 `call` 的调用方。handler 抛出的错误会成为调用方的 `nil, err`。table 中不存在的命令会返回 `nil, "command not found"`。

旧代码中的 `require "service".input(...)` 写法仍然有效：对同一个 service 重复绑定是幂等的。新代码不需要写。

## 3. 启动程序

### 3.1 直接运行 root 文件（推荐）

root 文件的前两行固定为 `require "service"` 和 `require "service.root"`，入口写成 `root.boot`，文件结尾 `return root`：

```lua
-- services/root.lua
local service = require "service"
local root = require "service.root"

function root.boot(env)                 -- 命令行参数依次传入
    service.spawn { name = "db", source = "@services/db.lua" }
    ...
end

function root.quit()                    -- 其他命令和普通 service 一样定义
    service.quit()
end

return root
```

```sh
luajit services/root.lua prod
```

`require "service.root"` 的行为取决于它在哪里执行：

- **宿主线程**（`luajit services/root.lua` 时）：以当前文件为 source 调用 `bootstrap`，命令行参数 `arg[1..n]` 传给 `root.boot`。root 退出后，进程以 0 退出；失败时把原因写到 stderr，然后以 1 退出。这个 `require` **不会返回**，所以它之后的代码不会在宿主中执行。
- **service 中**（root VM 再次执行这个文件时）：返回一张空的 handler 表。之后定义的函数都是命令，`return root` 交给运行时。

注意事项：

- 同一个文件会执行两次：宿主一次，root 一次。宿主只会执行到第 2 行，所以这两行之前不要放有副作用的代码。
- 必须由被运行的脚本在**顶层**直接 require。在函数里 require、被其他模块 require、通过 `luajit -e` 运行，都会报错并以 1 退出。例外是在模块中写 `return require "service.root"`：这是尾调用，无法识别出来，但最终也会因为启动失败而以 1 退出。
- 忘了写 `return root` 或者没有定义 `root.boot`，进程都会以 1 退出，stderr 中会给出原因。
- `root.boot` 返回后 root **不会**自动退出，需要显式调用 `service.quit()`。`root.boot` 抛错时，root 带着这个错误退出。
- 子 service 的文件也可以使用 `service.root`：在 service 中它只是一张普通的表，同时这个文件还可以直接运行，单独作为 root 调试。

### 3.2 使用 `bootstrap`

如果需要传 config、指定入口命令名，或者 source 不是一个文件，可以写一个单独的启动脚本：

```lua
-- main.lua
local service = require "service"

local ok, err = service.bootstrap {
    source = "@service/root.lua",
    config = { greeting = "hello" },
    start = "boot",            -- 缺省为 "boot"
    args = { "prod" },         -- 传给入口命令的参数
}
if not ok then
    io.stderr:write("root failed: ", err, "\n")
    os.exit(1)
end
```

`bootstrap` 的执行过程：

1. 新建一个 pool，以名字 `root` 创建并启动 ID 为 0 的 service；
2. 让 root 执行 `start` 命令；
3. 等待 root 退出；
4. 停止、join 并释放 pool 中剩余的所有 service。

返回值：

- root 正常调用 `service.quit()` 时，返回 `true`；
- 启动失败、入口命令抛错或不存在、root 调用了 `service.quit(err)`、root 的分发循环出错（例如 `on_idle` 抛错）时，返回 `nil, err`。

入口命令执行成功后，root 会继续运行，直到它调用 `service.quit()` 为止。

### 3.3 手动启动

也可以手动控制启动过程：

```lua
local root = service.new { source = "@service/root.lua", config = {} }
service.start(root)
service.send(service.get_id(root), "boot")
service.join(root)
```

注意，手动方式中入口命令只是普通的 `send`：入口抛错时只记录日志，root 不会退出。另外 `join` 只等待，不会回收子 service。如果没有特殊需要，优先使用前两种方式。

## 4. 组织子 service

root 通常负责启动其他 service，并按依赖顺序完成初始化：

```lua
function S.boot()
    service.spawn { name = "db",  source = "@service/db.lua",  config = { path = "/tmp/x" } }
    assert(service.call("db", "open"))          -- 等 db 就绪后再继续

    service.spawn { name = "api", source = "@service/api.lua", mailbox_size = 4096 }
end
```

- `spawn` 返回新 service 的 ID，失败时直接抛错。
- `name` 在当前存活的 service 中必须唯一，长度最多 31 字节。service 停止后，它的名字可以被重新使用。
- 一个 pool 在整个生命周期内最多创建 32 个 service（ID 0..31），ID 不会复用。
- `config` 会被序列化后交给子 service，子 service 从 `service.config` 读取。

## 5. send 与 call

```lua
-- 单向：true 只表示目标邮箱已接收，不代表 handler 已执行
local ok, err = service.send("logger", "write", "hello")

-- RPC：只能在 service 的请求 coroutine 中调用
local v1, v2 = service.call("db", "get", key)
local ok, err = service.call("db", "put", key, value)
if ok == nil then
    -- err 可能是 "service not found" / "service stopping" / "service stopped"
    -- / "command not found" / handler 抛出的错误字符串
end
```

- 目标可以是 ID（数字）或名字（字符串）。名字只能解析到仍在运行的 service；已停止 service 的名字会得到 `service not found`。
- `call` 失败时第一个返回值一定是 `nil`，因此可以写成 `assert(service.call(...))`。
- `call` **没有超时**。目标在回复前停止时，调用方会收到 `nil, "service stopped"`；但如果目标收下请求后既不返回、也不停止（例如 handler 挂起后再也没有被恢复），调用方会一直等待。
- 邮箱没有容量上限，发送不会因为对方处理慢而失败。下游处理不过来时消息会在内存中堆积，stderr 中会出现 `mailbox may overload` 的 WARN，这时应在业务层降速或合并消息。

## 6. 等待与定时

```lua
service.sleep(500)                          -- 挂起当前请求 coroutine 500ms

service.set_timeout(1000, function()        -- 一次性 timer，回调不在 coroutine 中
    service.send(service.get_id(), "tick")  -- 需要 call 时，先把事件转成消息
end)

local uv = require "luv"                    -- 或 service.uv
uv.new_timer():start(0, 5000, function()
    service.send(service.get_id(), "heartbeat")
end)
```

需要按绝对时间或每日定时执行的任务，见[调度器](scheduler.md)。

## 7. 关闭

推荐的顺序是：root 先关闭子 service 并等待确认，最后关闭自己。

```lua
-- 子 service
function S.quit()
    cleanup()
    service.quit()
    return true          -- quit 之后仍可返回结果，调用方能收到
end

-- root
function S.shutdown()
    assert(service.call("worker", "quit"))
    assert(service.call("db", "quit"))
    service.quit()       -- 宿主线程的 join/bootstrap 随之返回
end
```

`service.quit(err?)` 的语义：

- 幂等，并且只是**请求**停止。当前 coroutine 会继续运行，直到它返回或挂起。
- 调用后，service 不再处理邮箱中的新消息。按 ID 发来的新 `send` 和 `call` 会收到 stopping 或 stopped 错误，按名字发来的会收到 not found。
- 邮箱里尚未处理的消息会被丢弃，其中的 `call` 请求会得到 `nil, "service stopped"`。
- 挂起中的 coroutine（正在 `call` 或 `sleep` 的）不会再被恢复；如果它们是在处理别人的 `call`，调用方同样会得到 `nil, "service stopped"`。
- 所有 luv handle（timer、socket 等）都由运行时关闭，不需要手动清理。
- 传入 `err` 表示异常退出。root 以 `quit(err)` 退出时，`bootstrap` 返回 `nil, err`。

root 退出后，`bootstrap` 会停止并 join 剩下的所有 service，所以即使子 service 没有主动 quit，程序也能正常结束。不过，由运行时强制停止的 service 不会执行自己的 quit 命令。需要做清理（例如断开连接、写盘）的子 service，应由 root 用 `call` 发送 quit 命令，并等它确认。

## 8. 常用模式

### 回调转消息

luv 回调、`set_timeout` 回调和 `on_idle` 都不在请求 coroutine 中，不能调用 `call` 或 `sleep`。正确做法是先把事件发给自己：

```lua
server:on_message(function(conn, msg)
    service.send(service.get_id(), "on_request", conn.id, msg)
end)

function S.on_request(conn_id, msg)
    local result = service.call("backend", "handle", msg)   -- 这里可以 call
    reply(conn_id, result)
end
```

### 把异步回调包装成同步调用

在 handler 内部记住当前 coroutine，然后挂起，由回调负责恢复：

```lua
local function read_all(pipe)
    local co = service.get_session()
    local chunks = {}
    pipe:read_start(function(err, chunk)
        if chunk then
            chunks[#chunks + 1] = chunk
        else
            pipe:close()
            service.resume_session(co, err, table.concat(chunks))
        end
    end)
    return service.yield_session()      -- 返回 resume_session 传入的值
end
```

约束：

- 只能在请求 coroutine 中调用 `service.get_session()`。
- 每次挂起只能 `resume_session` 一次。
- 不要在另一个正在运行的 handler 内部直接 resume 其他 coroutine。应从 luv 回调、`on_idle` 或 timer 回调中恢复。

这组函数目前是兼容保留的底层接口，未来计划提供更安全的 suspend/wakeup 封装（见[已知限制](known-issues.md)）。

### 外部线程接入

C/C++ 库（例如交易柜台 SDK）往往在自己的线程上回调。推荐的接入方式是：

1. C 层把数据放进自己的线程安全队列；
2. C 层对 `service.get_async()` 返回的 `uv_async_t*` 调用 `uv_async_send` 唤醒 service；
3. service 在 idle hook（`service.add_idle_hook`）中以非阻塞方式取完队列。

```lua
local sdk = native.new_client(service.config.server)
sdk:set_async(service.get_async())

local remove_hook = service.add_idle_hook(function()
    while true do
        local event = sdk:poll()        -- 非阻塞
        if event == nil then return end
        handle_event(event)
    end
end)
```

idle hook 在每轮消息分发结束时调用一次（service 启动后会先调用一次），顺序是先 `service.on_idle`、再按注册顺序调用各个 hook。被外部唤醒但邮箱为空的轮次也会调用，所以外部唤醒一定能让 hook 运行。

注意事项：

- idle hook 和 `on_idle` 都是同步回调，不能调用 `call` 或 `sleep`。需要的话，用 `send` 转给自己处理，或者用 `resume_session` 恢复等待中的请求。
- idle hook 或 `on_idle` 中抛出的错误会**停止整个 service**，需要时请自行 `pcall`。
- hook 运行期间不要注册或注销 hook。
- `service.on_idle` 只有一个槽位，仅为兼容旧代码保留。多个模块请各自用 `add_idle_hook` 注册。
- C 层只能对 service 处于运行状态时取得的 async 指针调用 `uv_async_send`，并且必须在 service 停止前停止回调。

### 日志

```lua
service.log.info("order accepted", order_id)
service.log.warn("retrying", attempt)
```

运维时不需要改代码：

```sh
SERVICE_LOG_LEVEL=off luajit main.lua          # 关闭所有日志
SERVICE_LOG_LEVEL=debug luajit main.lua        # 打开 debug
luajit main.lua 2>>app.log                     # 重定向到文件
```

在 systemd 下运行时，stderr 默认进入 journal，运行时会自动切换为 journal 格式，之后可以用 `journalctl -u <unit> -p warning` 按级别查看。级别可以写在 unit 的 `Environment=SERVICE_LOG_LEVEL=warn` 中。

如果配置来自应用自己的配置文件，在启动时调用一次 `service.log_config { level = cfg.log_level }`，它的优先级高于环境变量。

## 9. 常见陷阱

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 入口一直不退出 | 入口命令执行成功后，root 没有调用 `service.quit()`；或者某个 service 的 handler 陷入死循环、永不 yield | 保证 root 最终会 quit。入口命令抛错时，`bootstrap` 会让 root 退出 |
| `service.call must be called from a managed service coroutine` | 在 luv 回调、idle hook、`set_timeout` 或宿主线程中调用了 call | 先 `send` 给自己，在 handler 中再 call |
| 调用方永久挂起 | 目标的 handler 挂起后再也没有被恢复（目标停止时调用方会收到 `service stopped`，不会挂起） | 保证每次挂起都会被恢复。call 目前没有超时 |
| `mailbox may overload, length = N` | 下游处理速度跟不上，消息在邮箱中堆积 | 业务层降速、批量或合并消息（例如行情只保留最新值） |
| `Unsupport type function to serialize` | 参数或返回值中含有 Lua 函数、coroutine 或 userdata | 只传数据。lightuserdata 和无 upvalue 的 C 函数可以传 |
| 状态在 call 之后变了 | 可重入：等待期间其他请求修改了状态 | 在 call 之后重新检查状态，或者用队列串行化 |
| `cannot open file 'service/x.lua'` | `@` 路径相对于进程的当前目录 | 在正确目录启动，或者使用绝对路径 |
| 第 33 个 service 创建失败 | 每个 pool 最多 32 个，ID 不复用 | 复用长期存活的 service |
| 子 service 的清理代码没有执行 | root 先退出，子 service 被 `bootstrap` 强制停止 | 用 `call` 等子 service 确认 quit |
| `service.root: must be required ...` | `service.root` 没有在被运行脚本的顶层 require | 放到 root 文件的第 2 行；工具脚本只 require `service` |
| `service.root: SERVICE_START_FAILED` | root 文件没有 `return root`，或者 `@` 路径和当前目录不匹配 | 补上 `return root`；查看 stderr 中更早的 ERROR 日志 |
