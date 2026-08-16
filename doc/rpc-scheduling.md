# RPC、Coroutine 与调度

> 当前状态：REQUEST 可以由 RESPONSE 或 ERROR 完成。timeout、取消、completion
> 来源校验、投递重试和停止恢复不属于当前实现目标。

## 当前信任模型

当前 RPC 建立在以下约束上：

1. 请求被 mailbox 接受后，目标 handler 正常返回 RESPONSE，command/handler error 返回 ERROR。
2. response/error completion 一定能成功进入调用方 mailbox；当前发送端不处理 completion send 失败。
3. `service.call` 没有 timeout，调用方允许无限期等待。
4. 业务代码不在 handler 内手动调用 `service.resume_session` 恢复另一个 coroutine。
5. 低层消息发送方可信，只发送符合约定的 REQUEST/RESPONSE/ERROR，不伪造、重复或错配 session。
6. response/error 只按 session 匹配，不验证 from/to 或 pending target。
7. RPC 目标在发送 completion 前不会停止，调用方也不会提前销毁等待 coroutine。

这些约束是当前公开行为的一部分，不是 runtime 已经检测或补偿的条件。违反约束时，
`service.call` 可以永久等待或丢弃 completion。

## 调度模型

每个 service 只有一个 pthread 和 Lua VM。inbox、timer、socket callback 都在该线程的
libuv loop 上串行进入 Lua。每个 REQUEST 创建独立 coroutine：

```text
inbox callback
    -> decode request
    -> create managed coroutine
    -> resume handler
         |-- return: send response
         `-- call/sleep yield: dispatcher continues
```

目标线程可以在调用方仍执行 `service.call` 时把 response 入队，但调用方的 Lua VM
不会并发运行第二个 inbox callback。调用方只有 yield 回 dispatcher 后才会处理
response，因此当前的“send 成功后登记 session、随后 yield”顺序没有响应抢跑竞态。

## Coroutine 元数据

当前 Lua 层只依赖两组核心映射：

```text
coroutine -> inbound { from, session }
session   -> waiting coroutine
```

`running_thread` 必须是 runtime 创建并登记的 managed coroutine。普通 luv callback、
standalone 代码和业务自行创建的 coroutine 不能调用 `service.call`。runtime 可以在一个
handler 因 call/sleep yield 后调度其他 request coroutine；“不支持嵌套 coroutine”特指
业务代码不得在一个正在运行的 handler 内手动 `resume_session` 另一个 coroutine。

## Session 分配

- 每个 service 独立维护精确的非零 uint32 session。
- session 从 1 递增到 `UINT32_MAX`，下一次回绕到 1，永远不发送 0。
- 候选 session 已存在于 pending table 时继续扫描，不能覆盖仍在等待的 call。
- 所有非零 session 都被占用时抛出 `RPC_SESSION_EXHAUSTED`。
- Lua number 可以精确表示完整 uint32 范围，native binding 在发送边界再次检查范围。

## `service.call`

当前调用流程：

1. 验证 `running_thread` 是 runtime 管理的 coroutine；失败时在 pack/send 前抛错。
2. 解析 name/ID，目标格式无效时返回 `nil, "service not found"`。
3. 分配一个未被 pending table 占用的非零 uint32 session。
4. pack 请求并调用 native send。
5. send 失败时立即返回 `nil, error_msg`，不登记 pending。
6. send 成功后登记 `session -> coroutine`，随后 yield。
7. dispatcher 收到相同 session 的 RESPONSE/ERROR，删除 pending 并恢复 coroutine。
8. RESPONSE 解包并返回 handler 的全部值；ERROR 解包后返回 `nil, error_msg`。

当前不创建 RPC timer，也不主动取消已经发送的 request。第一个错误返回值必须是 nil，
因此 `assert(service.call(...))` 可以把下游错误继续作为当前 handler error 向上传递。

## Request 和 Response

REQUEST payload 的第一个值是 command：

- function handler 调用 `handler(command, ...)`。
- table handler 调用 `handler_table[command](...)`。
- session 0 来自 `service.send`，handler 返回后不发送 response。
- session 大于 0 来自 `service.call`，handler 的全部返回值自动 pack 为 response。

table handler 找不到 command 时抛出固定的 `command not found`。request coroutine 的错误
由 `resume_session` 在仍持有 from/session 映射时处理：session 大于 0 时发送只包含一个字符串的
MESSAGE_ERROR，session 0 没有等待者，不发送 completion。handler 主动抛出的字符串原样传播；
错误对象转成字符串失败时使用 `handler error`。

dispatcher 使用正向分派：REQUEST 始终进入新请求路径；只有 RESPONSE/ERROR 且 session 大于 0
才进入 completion 路径。其他 type/session 组合释放 payload。合法 completion 再按 session 查找
等待 coroutine，不验证来源；找不到 session 时同样释放 payload。设计依据见
[ltask 调度与消息模型研究](ltask-analysis.md)。

response/error 发送调用 native `_send_message` 后不检查结果。当前模型把调用方 mailbox 有空间、
仍处于 RUNNING 且 completion 入队成功作为前置条件。

## Stop 和无限等待

`service.call` 允许无限期等待。当前停止流程不会恢复挂起的 outbound call，也不会为
尚未处理或 suspended 的 inbound RPC 构造 `SERVICE_STOPPED`。因此：

- RPC 目标必须在停止前完成已经接受的 call。
- 调用方必须保持运行直到收到 RESPONSE 或 ERROR。
- 无 completion、丢失 completion 或提前停止属于违反信任契约，runtime 不做恢复。

## 未来可选增强

只有信任边界扩大或实际业务需要时，再评估：

- 默认 timeout、取消以及 late/duplicate response 状态。
- response 的 from/to/target 校验。
- 跨 service traceback 和结构化错误对象。
- service stop 时取消 outbound call，并为 inbound/queued RPC 回复 `SERVICE_STOPPED`。
- 业务手动嵌套 `resume_session` 时的 `running_thread` 栈式恢复。

这些能力不得在没有新需求时扩大当前 RPC 改造范围。

## 当前必测场景

- 非 managed coroutine 调用 `service.call` 时在发送前失败。
- session 在 `UINT32_MAX` 后回绕到 1，并跳过 pending ID。
- self-call、跨 service call。
- response 多返回值以及中间、末尾 nil。
- handler error、yield 后 error、unknown command 和 `assert(call)` 传播。
- type/session 分派矩阵以及 unknown pending session。
- request send 的 target missing/full/stopping/stopped 错误。
- callback 前后 Lua stack top 不变。
