# RPC、Coroutine 与调度

## 调度模型

每个 service 只有一个 pthread 和 Lua VM。inbox、timer、socket callback 都在该线程的 libuv loop 上串行进入 Lua。

每个 REQUEST 创建独立 coroutine：

```text
inbox callback
    -> decode request
    -> create request coroutine
    -> resume handler
         |-- return: send response
         `-- yield: register wait state, dispatcher continues
```

coroutine 只由所属 service thread 恢复。其他线程只能投递 message 或 async signal，不能调用 `lua_resume`。

## Coroutine 元数据

Lua 层至少维护：

```text
coroutine -> inbound { from, session }
coroutine -> wait kind { none, rpc, sleep }
session   -> outbound { coroutine, target, timer, state }
timer     -> coroutine
```

元数据变更只发生在 service thread，因此 Lua table 本身不需要跨线程锁。每个 terminal path 必须原子地从所有相关表删除记录，避免一个 coroutine 被 timeout 和 response 恢复两次。

建议 outbound state：

```text
REGISTERED -> SENT -> COMPLETED
                  `-> TIMED_OUT
                  `-> CANCELLED
```

迟到或重复 response 只在找不到 active session 时释放 payload并记录日志。

## Session 分配

- 每个 service 独立维护 `uint32_t next_session`。
- session 0 永不用于 RPC。
- 分配从当前值递增，回绕时跳过 0。
- 候选 ID 已在 pending table 中时继续扫描。
- pending 已占满全部非零空间时返回资源耗尽错误，不能覆盖旧 session。
- Lua table key 使用截断后的精确 uint32 数值，C message 与 Lua lookup 必须一致。

## `service.call`

调用流程：

1. 确认 `running_thread` 是 runtime 管理的 coroutine。
2. 解析 name/ID 并验证目标。
3. 分配非零 session。
4. 创建 timeout timer；默认 30000 ms，配置 0 时跳过。
5. 在 pending table 注册 coroutine/session。
6. pack 请求并调用 native send。
7. send 失败时删除 pending、关闭 timer、释放 payload并立即抛错。
8. 标记 wait kind 为 rpc，yield coroutine。
9. response/error/timeout/cancel 恢复后清理 wait state。

注册必须发生在消息可被接收端处理之前。即使当前 loop 的串行性可以减少竞态，也不依赖该偶然顺序。

## Request dispatch

REQUEST payload 的第一个值是 command：

- function handler：调用 `handler(command, ...)`。
- table handler：查找 `handler[command]` 并调用 `handler_method(...)`。
- command 不是允许的 key 或 table 中无方法：`UNKNOWN_COMMAND`。

session 0：

- 正常返回时不发送 response。
- handler error 只记录服务端日志。

session > 0：

- 正常返回的全部值 pack 为 RESPONSE。
- handler error/unknown command/response pack error 形成 ERROR。
- response send 失败时记录上游不可达；当前 coroutine 仍完成并释放自身元数据。

## Response dispatch

仅按 message type 分派，不能使用 Lua 中 `if session then` 判断，因为 0 也为真：

- `MESSAGE_RESPONSE`：session 必须非零，查找 active pending，关闭 timer并恢复 coroutine。
- `MESSAGE_ERROR`：同上，恢复后由 `service.call` 重抛。
- `MESSAGE_REQUEST`：创建新 request coroutine。
- `MESSAGE_SYSTEM`：只进入 runtime system handler。
- `MESSAGE_SIGNAL`：只进入显式 signal handler；未支持时记录并释放。
- 未知 type：协议错误，释放 payload。

from/to 必须与当前 service 和 pending target 一致。错误来源的 response 不能完成 session。

## 错误 payload

service 间 ERROR 使用单个 string：

```text
CODE: human-readable message
stack traceback:
    ...
```

稳定 code 包括 `UNKNOWN_COMMAND`、`HANDLER_ERROR`、`SERIALIZE_ERROR`、`SERVICE_STOPPED`、`RPC_TIMEOUT`。

- 内部 service 可以获得完整 traceback。
- 网络 gateway 对外响应必须去掉内部绝对路径和敏感参数。
- traceback 构造失败时仍要发送最小 `CODE: message`。

## Timeout

timer callback：

1. stop/close timer。
2. 检查 session 仍处于 SENT。
3. 删除 pending record。
4. 标记 TIMED_OUT。
5. 恢复 coroutine，并让 `service.call` 抛出 `RPC_TIMEOUT`。

response callback 与 timeout callback 在同一 service thread 串行执行，先完成者删除 record，后完成者只释放自己的资源。

timeout 不撤销已经在目标执行的业务操作，因此 call 提供的是 bounded wait，不是事务取消。需要幂等或取消语义的业务协议必须自行携带 request ID。

## Sleep 和 timer

`service.sleep(ms)`：

1. 验证 coroutine 上下文和非负有限 ms。
2. 创建一次性 luv timer并登记 wait kind。
3. yield。
4. timer callback 先 stop/close，再删除 wait record并恢复 coroutine。

`service.set_timeout(ms, callback)` 返回 timer handle，但 runtime 仍包装 callback：

- callback 前 timer 已停止。
- 无论 callback 成功/失败都关闭 handle。
- error 通过 runtime logger 记录，不穿过 libuv C callback。
- service STOPPING 时未触发 timer 统一关闭，不执行普通业务 callback。

## Stop 时的调度

- 停止请求不会抢占当前正在执行的 Lua 指令。
- 当前 handler 返回到 dispatcher 边界后停止继续取新 request。
- 当前 handler 若在 stop_requested 后 yield，取消它并按 inbound session 回复错误。
- suspended outbound call 关闭 timer、删除 session，并以 `SERVICE_STOPPED` 恢复或直接在 VM teardown 前清理。
- suspended inbound handler 向其调用方回复 `SERVICE_STOPPED`。
- 关闭期间的 late response 只释放 payload。

## 公平性

- 每次 inbox callback 最多处理 256 条，可配置但有上下限。
- batch 后 mailbox 非空则再次 async send，让 timer/socket callback 获得运行机会。
- 一个不 yield 的 handler 仍可无限阻塞 loop；batch 不能解决业务 CPU 饥饿。
- 指标记录 handler duration、batch size、timer scheduling delay 和 pending RPC count。

## 嵌套调用

`A -> B -> C -> A` 可以工作：A 的第一个 coroutine 等待 B 时，A 的 dispatcher 可以为 C 的请求创建另一个 coroutine。

这不保证业务无死锁。若 handler 在 Lua 层持有逻辑锁、等待不可重入状态或依赖严格执行顺序，仍可能形成循环等待。框架只保证线程不会因为同步 pthread wait 阻塞消息调度。

## 必测场景

- call 多返回值、包含 nil、self-call、跨 service call。
- handler error、unknown command、response serialize error。
- target missing/full/stopping/stopped。
- timeout 与 response 同一 tick 竞争。
- late、duplicate、unknown session、wrong sender response。
- session 接近 `UINT32_MAX` 的回绕。
- stop 取消 sleep、outbound call 和 inbound suspended handler。
- 嵌套 A/B/C/A 调用。
- inbox 压力下 timer 延迟有界。
- callback 前后 Lua stack top 不变。
