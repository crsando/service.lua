# API 参考

```lua
local service = require "service"
```

`service.lua` 在 `service_c` 原生模块的表上补充 Lua 层函数，然后返回这张表。因此 `service` 与 `require "service_c"` 是同一个表。每个 VM（宿主线程以及每个 service）各有一份。

除非特别说明返回 `nil, err`，参数错误和非法调用上下文都会抛出 Lua error。

## 1. 上下文

| 上下文 | 说明 |
| --- | --- |
| service | service 线程中的 Lua 代码。`service.self` 不为 nil |
| 请求 coroutine | 运行时为每条请求创建的 coroutine。只有这里能调用 `call`、`sleep`、`get_session` |
| 回调 | luv 回调、`set_timeout` 回调、`on_idle`、scheduler 任务。属于 service 上下文，但不是请求 coroutine |
| standalone | 宿主线程（入口脚本）。`service.self == nil`，只应调用 `bootstrap/new/start/send/join` |

## 2. 模块字段

| 字段 | 说明 |
| --- | --- |
| `service.self` | 当前 service 的 addr（lightuserdata）。standalone 中为 nil |
| `service.pool` | 当前 pool。standalone 中首次 `new` 时创建 |
| `service.config` | 当前 service 的配置 table，没有配置时为 `{}`。standalone 中为 nil |
| `service.uv` | 本 VM 的 luv 模块。service 中已绑定到本 service 的 loop |
| `service.on_idle` | 可选。每轮消息分发结束时调用的同步钩子，见 [§7](#7-分发) |
| `service.scheduler` | 约定的挂载点，需要手动赋值：`service.scheduler = require "service.scheduler"` |
| `service.yield_session` | `coroutine.yield` 的别名 |

业务代码不得修改 `self`、`pool`。addr 和 pool 都是不透明指针，不得伪造。

## 3. 创建与控制

### `service.new(options) -> addr`

| 字段 | 必需 | 说明 |
| --- | --- | --- |
| `source` | 是 | `"@path.lua"`（相对于进程当前目录）或 Lua 源码字符串 |
| `name` | 否 | 在存活 service 中唯一，最多 31 字节 |
| `config` | 否 | table（自动 `pack`）或来自 `service.pack` 的指针。所有权移交给运行时 |
| `mailbox_size` | 否 | 整数，范围 16..65536，默认 1024 |
| `pool` | 否 | 指定 pool。缺省使用 `service.pool`，没有则新建 |

只登记 service，不启动线程。以下情况抛出 `could not create service`：名字重复或过长、pool 已创建满 32 个、内存不足。

### `service.start(addr_or_id) -> 0`

创建线程并等待初始化完成。初始化包括：建立 loop、加载 luv、绑定 `service`、执行 source、规范化 handler。失败时抛出 `SERVICE_START_FAILED: <errno>`，并已回收该 service 的线程。具体原因（如 source 语法错误）会写入 stderr 日志。

service 启动后，运行时会立即触发一轮分发，因此 `on_idle` 会在启动后马上被调用一次。

### `service.spawn(options) -> id`

`new` + `start` + `get_id`。

### `service.quit(err?)`

请求停止**当前** service，幂等。传入 `err` 表示异常退出：它会被转成字符串，记为该 service 的退出原因，`bootstrap` 会把这个原因作为错误返回。只有第一次记录的原因有效。详细语义见[使用指南 §7](guide.md#7-关闭)。

### `service.join(addr_or_id) -> 0`

阻塞等待目标线程退出，然后释放它的 VM、loop 和邮箱。`join` 不会请求目标停止。

- 只应在宿主线程中使用。在 service 中 join 会阻塞自己的 loop。
- join 自己会抛错（`EDEADLK`）；重复 join 返回第一次的结果。
- 在 standalone 中只能传 addr，因为 ID 到 addr 的转换需要 service 上下文。

### `service.bootstrap { source, config?, start? } -> true | nil, err`

只能在宿主线程中调用。执行过程如下：

1. 新建一个专用 pool，在其中以 `name = "root"` 创建并启动 root；
2. 用一条内部 `MESSAGE_SYSTEM` 消息让 root 执行 `start` 命令（缺省为 `"boot"`）；
3. join root；
4. 调用 `_pool_delete`，停止、join 并释放这个 pool 中的所有 service；
5. 如果 `service.pool` 指向这个已删除的 pool，就把它重置为 nil。

返回值：

| 情况 | 返回 |
| --- | --- |
| root 调用 `service.quit()` | `true` |
| root 调用 `service.quit(err)` | `nil, err` |
| 入口命令抛错 | `nil, <错误字符串>`。运行时会先记录日志，再让 root 以该错误退出 |
| 入口命令不存在（table handler） | `nil, "command not found"` |
| root 的分发循环出错（例如 `on_idle` 抛错） | `nil, <错误字符串>` |
| root 启动失败 | `nil, "SERVICE_START_FAILED: <errno>"` |

参数不合法（缺少 `source`、`start` 不是字符串）或者在 service 中调用时会抛错。

限制：停止是协作式的。如果某个 service 的 handler 永不 yield，`bootstrap` 会一直阻塞。

## 4. 查询

| 函数 | 返回 | 说明 |
| --- | --- | --- |
| `service.get_id(addr?)` | integer | 不传参数时返回当前 ID。standalone 中恒为 0 |
| `service.get_addr(id_or_addr?)` | addr \| `nil, "SERVICE_NOT_FOUND"` | 不传参数时返回 `self`；传入非数字参数时原样返回。数字参数需要 service 上下文，已停止的 service 仍可查到（用于 join 或诊断） |
| `service.lookup(name)` | id \| nil | 只匹配存活的 service。参数不是字符串时返回 nil |
| `service.get_pool(addr?)` | pool | |
| `service.get_async(addr?)` | lightuserdata \| nil | 目标的 inbox `uv_async_t*`，用于[外部线程接入](guide.md#外部线程接入) |
| `service.get_uv_loop(addr?)` | lightuserdata \| nil | 目标的 `uv_loop_t*`，仅用于诊断 |

## 5. 消息

### `service.send(target, ...) -> true | nil, code`

`target` 可以是 ID 或名字。参数被序列化为一条 `MESSAGE_REQUEST`，session 为 0。

| code | 含义 |
| --- | --- |
| `SERVICE_NOT_FOUND` | ID 越界、ID 未分配或名字不存在 |
| `SERVICE_STOPPING` | 目标已请求停止，线程尚未退出 |
| `SERVICE_STOPPED` | 目标已停止 |
| `MAILBOX_FULL` | 目标邮箱已满 |

返回 `true` 只表示目标邮箱已经接收这条消息。返回失败时，这条消息一定不会被处理。

### `service.loopback(...)`

等价于 `service.send(service.get_id(), ...)`。

### `service.call(target, ...) -> ... | nil, err`

只能在请求 coroutine 中调用，否则抛错。成功时返回目标 handler 的全部返回值。

| err | 来源 |
| --- | --- |
| `service not found` / `service stopping` / `service stopped` / `mailbox full` | 请求未被接收。不会挂起，立即返回 |
| `command not found` | table handler 中没有该命令 |
| handler 抛出的错误字符串 | 例如 `service/echo.lua:11: unknown command: nope` |
| `handler error` | handler 抛出的错误对象无法转为字符串 |

没有超时和取消机制。请求被接收之后，调用方会一直等到响应到达为止。

### 底层接口

| 函数 | 说明 |
| --- | --- |
| `service.send_message(to, session, type, ptr, size)` | 发送任意类型的消息，`from` 取当前 service。`ptr` 交给运行时后，无论成功还是失败，调用方都不得再使用 |
| `service.recv_message(blocking)` | 非阻塞地弹出一条消息，返回 `from, to, session, type, ptr, size` 或无返回值。`blocking` 参数被忽略。拿到的 `ptr` 必须正好释放一次 |

正常业务不需要使用这两个函数。

## 6. Coroutine 与定时

| 函数 | 说明 |
| --- | --- |
| `service.sleep(ms)` | 挂起当前请求 coroutine。只能在请求 coroutine 中调用 |
| `service.set_timeout(ms, cb) -> timer` | 一次性 luv timer。触发后自动关闭，回调不在 coroutine 中执行 |
| `service.get_session()` | 当前由运行时恢复的 coroutine。在回调中为 nil |
| `service.yield_session(...)` | 挂起当前 coroutine |
| `service.resume_session(co, ...)` | 恢复一个由运行时管理的 coroutine。只能从回调中调用，不要在正在运行的 handler 内调用 |

## 7. 分发

### `service.dispatch(handler) -> dispatcher`

把 handler 包装成运行时使用的 dispatcher。source 返回 table 时，运行时会自动调用这个函数。

- **function**：调用 `handler(command, ...)`。
- **table**：调用 `handler[command](...)`。命令不存在时返回错误 `command not found`。

每次被唤醒执行一轮分发时：

1. 循环弹出消息，最多 256 条，直到邮箱为空或 service 已 quit；
2. `REQUEST` 消息：新建 coroutine 执行 handler。session > 0 时把返回值或错误回给调用方；
3. `RESPONSE`/`ERROR` 消息（session > 0）：恢复对应 session 中挂起的 `call`。找不到对应 session 的响应直接丢弃；
4. 其他类型：直接丢弃；
5. 如果 service 尚未 quit 且设置了 `service.on_idle`，调用一次 `on_idle`；
6. 如果本轮处理满了 256 条，再唤醒自己一次，以便 timer 和 socket 有机会执行。

handler 中的错误只影响当前请求。`on_idle` 中的错误，或者分发循环本身的错误，会停止整个 service。

## 8. 序列化

| 函数 | 说明 |
| --- | --- |
| `service.pack(...) -> ptr, size` | 序列化。不支持的类型会抛错 |
| `service.unpack(ptr, size?)` | 只读解码，不释放 |
| `service.unpack_remove(ptr, size?)` | 解码后释放 |
| `service.remove(ptr, size)` | 只释放 |

支持的类型：nil、boolean、number、string（二进制安全）、table（包括循环引用和共享引用）、lightuserdata、无 upvalue 的 C 函数。

不支持的类型：Lua 函数、coroutine、full userdata、带 upvalue 的 C 闭包。

其他说明：metatable 不会被保留，但打包时会使用 `__pairs` 遍历。数字一律按 double 编码。编码结果只在同一进程内有效，不能用于持久化或跨进程传输。

## 9. `service_c` 原生接口

这些函数仅供 `lua/service.lua` 和诊断代码使用，签名保持稳定。

| 函数 | 参数 | 返回 |
| --- | --- | --- |
| `_pool_new` | `()` | pool |
| `_pool_delete` | `(pool)` | 无返回值。停止、join 并释放 pool 中的所有 service，然后释放 pool 本身。之后该 pool 中的所有 addr 都失效 |
| `_new` | `(pool, name?, source, config_ptr?, options?)` | addr，失败时抛错 |
| `_start` / `_join` | `(addr)` | 0，失败时抛错 |
| `_stop` | `(addr, exit_error?)` | 0。传入 `exit_error` 时记录退出原因（只有第一次有效） |
| `_get_exit_error` | `(addr)` | 退出原因字符串，或 nil。join 之后仍可读取，直到 pool 被删除 |
| `_get_id` | `(addr)` | id |
| `_get_pool` / `_get_async` / `_get_uv_loop` | `(addr)` | 指针或 nil |
| `_get_addr` | `(addr, id)` | addr 或 `nil, "SERVICE_NOT_FOUND"` |
| `_lookup` | `(pool, name)` | id 或 nil |
| `_send_message` | `(pool, from, to, session, type, ptr?, size?)` | `true` 或 `nil, code` |
| `_recv_message` | `(addr, blocking)` | 6 个字段或无返回值 |
| `_log_error` | `(addr, message)` | 无返回值 |
| `pack` / `unpack` / `unpack_remove` / `remove` | 见 §8 | |

## 10. 消息类型

`service_id` 和 `session` 都是 `uint32_t`。

| 值 | 类型 | 用途 |
| --- | --- | --- |
| 0 | `MESSAGE_SYSTEM` | 运行时内部使用。目前只处理 payload 为 `("bootstrap", entry)` 的消息，其他直接丢弃 |
| 1 | `MESSAGE_REQUEST` | session 为 0 表示 `send`；session > 0 表示 `call` |
| 2 | `MESSAGE_RESPONSE` | `call` 成功时的响应 |
| 3 | `MESSAGE_ERROR` | `call` 失败时的响应，payload 是一个错误字符串 |
| 4 | `MESSAGE_SIGNAL` | 保留，目前直接丢弃 |

session 由调用方按 service 独立分配，在 uint32 范围内回绕时会跳过 0 和仍在等待中的 session。
