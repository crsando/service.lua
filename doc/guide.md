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

程序入口运行在宿主线程，通常只做一件事：启动 root 并等待它退出。

```lua
-- main.lua
local service = require "service"

service.bootstrap {
    source = "@service/root.lua",
    config = { greeting = "hello" },
    start = "boot",            -- 缺省为 "boot"
}
```

`bootstrap` 依次执行以下步骤：以名字 `root` 创建 ID 为 0 的 service；启动它；向它 `send` 一条 `start` 命令；然后 `join` 它。等价的手写形式是：

```lua
local root = service.new { source = "@service/root.lua", config = {} }
service.start(root)
service.send(service.get_id(root), "boot")
service.join(root)
```

`join` 只等待，不会让 root 停止。root 必须自己调用 `service.quit()`，否则入口会一直阻塞。

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
    -- err 可能是 "service not found" / "service stopping" / "mailbox full"
    -- / "command not found" / handler 抛出的错误字符串
end
```

- 目标可以是 ID（数字）或名字（字符串）。名字只能解析到仍在运行的 service；已停止 service 的名字会得到 `service not found`。
- `call` 失败时第一个返回值一定是 `nil`，因此可以写成 `assert(service.call(...))`。
- `call` **没有超时**。如果目标收下请求后既不返回也不报错（例如在回复前就 quit），调用方会永久挂起。

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

`service.quit()` 的语义：

- 幂等，并且只是**请求**停止。当前 coroutine 会继续运行，直到它返回或挂起。
- 调用后，service 不再处理邮箱中的新消息。按 ID 发来的新 `send` 和 `call` 会收到 stopping 或 stopped 错误，按名字发来的会收到 not found。
- 邮箱里尚未处理的消息会被丢弃。挂起中的 coroutine（正在 `call` 或 `sleep` 的）不会再被恢复。
- 所有 luv handle（timer、socket 等）都由运行时关闭，不需要手动清理。

如果只用 `send` 发出 quit，root 可能先于子 service 退出。当前 `bootstrap` 只 join root，没有退出的子 service 会在进程结束时随进程一起终止。如果子 service 需要完成清理，就用 `call` 等待它确认。

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
3. service 在 `service.on_idle` 中以非阻塞方式取完队列。

```lua
local sdk = native.new_client(service.config.server)
sdk:set_async(service.get_async())

function service.on_idle()
    while true do
        local event = sdk:poll()        -- 非阻塞
        if event == nil then return end
        handle_event(event)
    end
end
```

`on_idle` 在每轮消息分发结束时调用一次（service 启动后会先调用一次）。被外部唤醒但邮箱为空的轮次也会调用，所以外部唤醒一定能让 `on_idle` 运行。

注意事项：

- `on_idle` 是同步回调，不能调用 `call` 或 `sleep`。需要的话，用 `send` 转给自己处理，或者用 `resume_session` 恢复等待中的请求。
- `on_idle` 中抛出的错误会**停止整个 service**，需要时请自行 `pcall`。
- `service.on_idle` 只有一个槽位。同一个 service 里的多个模块要共用它，需要自己做组合。
- C 层只能对 service 处于运行状态时取得的 async 指针调用 `uv_async_send`，并且必须在 service 停止前停止回调。

## 9. 常见陷阱

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 入口一直不退出 | root 没有调用 `service.quit()`，或 boot 中途抛错 | 保证所有路径都会 quit。boot 抛错时运行时只记录日志 |
| `service.call must be called from a managed service coroutine` | 在 luv 回调、`on_idle`、`set_timeout` 或宿主线程中调用了 call | 先 `send` 给自己，在 handler 中再 call |
| 调用方永久挂起 | 目标在回复前 quit，或者 handler 自己挂起后再也没有被恢复 | 先返回结果再结束。call 目前没有超时 |
| `Unsupport type function to serialize` | 参数或返回值中含有 Lua 函数、coroutine 或 userdata | 只传数据。lightuserdata 和无 upvalue 的 C 函数可以传 |
| 状态在 call 之后变了 | 可重入：等待期间其他请求修改了状态 | 在 call 之后重新检查状态，或者用队列串行化 |
| `cannot open file 'service/x.lua'` | `@` 路径相对于进程的当前目录 | 在正确目录启动，或者使用绝对路径 |
| 第 33 个 service 创建失败 | 每个 pool 最多 32 个，ID 不复用 | 复用长期存活的 service |
| 子 service 的清理代码没有执行 | root 先退出，进程随即结束 | 用 `call` 等子 service 确认 quit |
