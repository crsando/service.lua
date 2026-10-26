# 已知限制与路线

本文记录当前实现与理想语义之间的差距，以及建议的改进方向。条目均已对照 2026-10 的代码确认。

优先级：**P0** 安全或外部风险；**P1** 可能导致挂起、崩溃或资源错误；**P2** 功能或易用性缺陷；**P3** 工程和文档问题。

## 1. 外部风险

### SEC-1（P0）历史仓库中的明文交易凭据

本项目的前身 `lservice3` 的 Git 历史中包含明文账号、密码、AppID 和认证码。这些文件没有被复制到本仓库，`.gitignore` 也已经忽略常见的本地秘密文件。但历史中的凭据必须按已泄漏处理并完成轮换，同时检查远端仓库、镜像和 CI 日志。今后凭据只能通过环境变量或仓库外的配置文件注入。

## 2. 运行时语义

### RT-1（P1）`call` 没有超时和取消

请求被接收后，调用方会一直等待，直到收到响应或者目标停止。如果目标的某个 handler 挂起后再也没有被恢复，而目标又没有停止，调用方就永远挂起。实际项目（例如 CTP trader）已经不得不自己实现超时。

**方向**：提供 `service.call_timeout(ms, target, ...)` 或类似的选项。超时只在调用方一侧生效：超时后从等待表中移除这个 session，迟到的响应按“找不到 session”直接释放。这样不需要放宽 completion 必达的信任模型。

### RT-2（P1）停止时挂起中的 coroutine 被直接丢弃 —— 已解决

service 停止时，邮箱中未处理的请求由 C 侧回复 ERROR，已接收、尚未回复的请求由 Lua 侧回复 ERROR，调用方得到 `nil, "service stopped"`。本 service 自己挂起中的 `call` 和 `sleep` 仍然不会被恢复，它们随 VM 一起销毁。详见 [mailbox-research.md](mailbox-research.md)。

### RT-11（P2）邮箱没有容量上限

为了保证响应不丢，邮箱改为满时翻倍（同 skynet）。代价是没有背压：下游变慢时消息在内存中堆积，可能 OOM，延迟也可能失去意义。目前唯一的信号是 `mailbox may overload` 的 WARN 日志。邮箱只扩不缩。

**方向**：

- 提供 `service.mailbox_stat(target?, { reset? }) -> stat`，设计草案见 [mailbox-research.md §8](mailbox-research.md#8-未来工作mailbox_stat)；
- 需要背压的 service 可以设置可选的容量上限，此时用"call 时在自己邮箱中预留位置"的方式保证响应不丢（见 mailbox-research.md 方案 3）。

### RT-12（P3）root 无法指定 `mailbox_size`

`service.bootstrap` 创建 root 时没有转发 `mailbox_size`，`require "service.root"` 也没有配置入口，所以 root 只能使用默认的初始容量 1024。

**方向**：bootstrap 的 entry 增加 `mailbox_size` 字段并转发给 `service.new`；`service.root` 从 root 模块读取，例如 `root.mailbox_size`。

### RT-3（P1）外部线程持有的 async 指针可能比 service 活得更久

外部接入依赖 `service.get_async()` 返回的 `uv_async_t*`。service 停止后这个 handle 会被关闭，loop 也会被销毁。外部线程如果在这之后继续调用 `uv_async_send`，属于未定义行为。目前只能依靠业务代码在 quit 之前先停止外部回调。

**方向**：提供正式的 notifier 对象（例如 `service.notifier()`），用引用计数加关闭标志包装 async handle，并在 C 层提供 `notifier_signal()` 和 `notifier_release()`。service 停止后，`signal` 变为空操作。

### RT-4（P2）idle 回调出错会停止 service

多个 idle 回调的问题已解决：`service.add_idle_hook(fn) -> remove` 可注册多个 hook，`service.on_idle` 保留以兼容旧代码。

仍未解决：`on_idle` 或任何 hook 中未捕获的错误都会让 dispatcher 的 `pcall` 失败，进而停止整个 service。hook 运行期间也不能增删 hook。

**方向**：如有需要，再对每个 hook 单独做 `xpcall` 和记录日志。

### RT-5（P2）挂起和唤醒的底层接口缺少保护

`get_session`、`yield_session`、`resume_session` 已被业务代码广泛使用（用于把异步回调包装成同步调用），但它们缺少以下保护：重复 resume 不会报错；在 handler 内部嵌套 resume 会破坏 `running_thread`；在非请求 coroutine 中调用 `service.sleep` 时，报错信息难以理解。

**方向**：提供 `local token = service.suspend()` 和 `service.wakeup(token, ...)`。token 只能使用一次，并且只允许在非 handler 上下文中唤醒。`sleep` 和 `call` 都应检查上下文并给出明确的错误信息。

### RT-8（P2）每个 pool 最多 32 个 service，ID 不复用

对长期运行、需要动态创建 worker 的程序不够用。

**方向**：把 `MAX_SERVICES` 改为可配置，或者引入 generation 机制，使 ID 可以复用的同时，旧 addr 仍然能被识别为已失效。

### RT-9（P3）错误信息只写在日志里

`SERVICE_START_FAILED` 只带一个 errno，source 语法错误等真正的原因只写到日志。

**方向**：在 start 的错误中带上 Lua 错误信息。

日志级别控制已完成：见 [API §11](api.md#11-日志)，调研与取舍见 [logging-research.md](logging-research.md)。

### RT-10（P3）宿主线程发送的消息 `from` 为 0

standalone 中 `get_id()` 返回 0，与 root 的 ID 相同。由于宿主线程不能 `call`，目前不会造成问题，但诊断时容易混淆。

## 3. 序列化

### SER-1（P2）解码信任任意指针和长度

`unpack`、`remove` 接受任意 lightuserdata，不校验来源。在当前“可信 Lua 代码”的边界内这是可以接受的。如果将来要加载不可信脚本，需要引入受管 buffer（带 magic、长度和所有权标记）。

## 4. 网络

旧实现中的 `remote` 和 `gateway` 已经移除。如果要恢复网络入口，至少需要做到：默认只监听 localhost；限制帧长度；使用路由白名单，不能让客户端指定任意 service 和方法；提供鉴权钩子和速率限制。

## 5. 工程

| ID | 级别 | 问题 | 方向 |
| --- | --- | --- | --- |
| ENG-1 | P3 | 缺少顶层 LICENSE/NOTICE。`src/lua-seri.c`（cloudwu，MIT）需要保留署名 | 补充 LICENSE 和 NOTICE |
| ENG-2 | P3 | 没有 `test-asan`、`lint` 和 CI | 补充这些 target，并把 `make test`、`make test-tsan` 纳入 CI |
| ENG-3 | P3 | 缺少长时间运行的压力测试（例如百万条消息下内存和 Lua 栈不增长），也缺少 bootstrap 结束后的资源计数校验 | 增加 stress 测试和资源计数 |
| ENG-4 | P3 | `message.h` 中有未使用的 receipt、schedule 常量和兼容 typedef；`tests/legacy/test.lua` 引用了已不存在的模块 | 清理，或者明确标注为保留 |

## 6. 建议的推进顺序

1. SEC-1 的凭据轮换（外部动作，不依赖代码）。
2. RT-1：调用方超时。
4. RT-3、RT-4、RT-5：把外部线程接入、idle hook 的错误隔离、挂起和唤醒做成正式 API。CTP 这类集成目前依赖的正是这些底层接口。
5. RT-9 及工程类条目。

已完成：RT-2（停止时回复挂起中的请求）、RT-6（bootstrap 返回结果并回收整个 pool）、RT-7（`lookup` 不再把非字符串名字解析为 root）。
