# 内部实现

本文描述运行时的结构和关键不变量，面向维护者。对外接口以 [API 参考](api.md) 为准。

## 1. 组成

```text
宿主线程 (standalone)                    service 线程 × N
┌──────────────────────┐                 ┌───────────────────────────────┐
│ lua/service.lua      │  new/start/join │ LuaJIT VM                     │
│   └─ service_c.so ───┼────────────────▶│   lua/service.lua + source    │
└──────────────────────┘                 │ uv_loop                       │
                                         │   inbox_async   ← 消息唤醒    │
           service_pool_t                │   control_async ← 停止请求    │
  ┌─────────────────────────────┐        │   luv handles (timer/tcp/…)   │
  │ lock, services[32], next_id │◀──────▶│ mailbox (growable MPSC ring)  │
  └─────────────────────────────┘        └───────────────────────────────┘
```

| 文件 | 职责 |
| --- | --- |
| `src/service.c/.h` | pool、service 句柄、生命周期、线程主循环、发送与停止 |
| `src/mailbox.c/.h` | 可扩容的 MPSC 环形队列，用 spinlock 保护，满时翻倍 |
| `src/message.c/.h` | `message_t` 定义、消息类型、payload 释放 |
| `src/lservice.c` | `luaopen_service_c` 及其导出函数 |
| `src/loadluv.c/.h` | 进程内只 `dlopen` 一次 luv，并为每个 VM 绑定各自的 loop |
| `src/lua-seri.c/.h` | 序列化（源自 ltask 和 skynet 的 lua-seri） |
| `src/log.c/.h` | 进程级 logger：按级别过滤，每条记录一次 `write(2)` 写到 stderr，支持 text 和 journal 格式 |
| `lua/service.lua` | 公共 API、session 与 coroutine 管理、分发循环 |

## 2. Pool 与句柄

- `service_pool_t` 保存一个 `services[32]` 数组和单调递增的 `next_id`。ID 等于数组下标，**不复用**。
- `service_t` 本身就是对外暴露的 addr（lightuserdata）。join 之后，VM、loop、邮箱、source、config 都会释放，但 `service_t` 结构作为墓碑一直保留，直到 pool 被删除。因此旧 addr 和旧 ID 不会指向新的 service。
- 每个 service 有一个 `routable` 标志，受 pool lock 保护。名字查找和消息投递只看 routable 的 service，所以停止后名字可以立即复用。
- 运行时信任上游传入的 addr 和 pool 指针，不校验它们的来源。

## 3. 发送路径

`service_send(pool, msg)`：

1. **pin**：在 pool lock 内检查目标是否 routable，是的话 `send_pins++`。不 routable 时，根据状态返回 `STOPPING` 或 `STOPPED`；没有这个 ID 时返回 `NOT_FOUND`。
2. **push**：`mailbox_try_push`。可能的结果是 `OK`、`FULL` 或 `CLOSED`，其中 `FULL` 只表示扩容时内存分配失败。成功时邮箱接管 payload 的所有权。
3. **notify**：只有当邮箱从“未调度”变为“已调度”时，才调用 `uv_async_send(inbox_async)`，这样可以合并重复唤醒。
4. **unpin**：`send_pins--`。降到 0 时广播 `pins_changed`。

发送失败时，`lservice.c` 会释放 payload，然后返回 `nil, code`。

同一发送者发往同一目标的消息保持 FIFO 顺序。不同发送者之间的顺序取决于谁先拿到邮箱的 spinlock。

## 4. 邮箱与分发

邮箱内部状态包括 `items[capacity]`、`head`、`tail`、`count`、`closed`、`scheduled`，以及过载检测用的 `overload` 和 `overload_threshold`。

- **扩容**：push 时如果已满，先释放 spinlock，在锁外分配两倍容量的新缓冲区，然后重新加锁。如果容量在此期间没有被别的生产者改变、并且仍然是满的，就按 FIFO 顺序把旧内容搬进新缓冲区；否则丢弃新缓冲区，重新判断。旧缓冲区在解锁后释放。这样其他生产者和消费者不会在 spinlock 上等待 malloc。邮箱只扩不缩。
- **过载检测**（与 skynet 相同）：pop 后如果 `count` 超过阈值，就记下 `count`，并把阈值翻倍直到超过 `count`；pop 遇到空队列时，阈值恢复为初始容量。每轮分发结束后，C 侧取出这个记录（`mailbox_overload`），如果非 0 就输出 WARN。

- 生产者 push 成功，并且 `scheduled` 为 false 时，把它置为 true 并通知消费者。
- 消费者 pop 时遇到空队列，就把 `scheduled` 清为 false，以便下一次 push 能重新唤醒它。
- `inbox_async` 触发后，C 回调 `service_async_cb` 调用 Lua dispatcher（`service._on_msg`）。Lua 侧最多循环 pop 256 条消息。
  - 如果本轮因为遇到空队列而结束，`scheduled` 已在 pop 时被清除。
  - 如果本轮处理满 256 条，Lua 返回 true。C 侧调用 `mailbox_finish_batch`：仍有消息时保持 `scheduled` 并再次唤醒自己，否则清除 `scheduled`。这样 timer 和 socket 回调可以插在两轮分发之间执行。
- 每一轮结束时都会调用 `service._on_idle`，它先调用 `service.on_idle`（若有），再按注册顺序调用 `add_idle_hook` 注册的 hook。外部代码直接 `uv_async_send(inbox_async)` 也会触发一轮（这一轮里可能没有消息），这就是[外部线程接入](guide.md#外部线程接入)的基础。libuv 可能把多次 `uv_async_send` 合并成一次回调，因此 hook 必须把外部队列取空。
- 如果 dispatcher 本身出错（`lua_pcall` 失败，包括 `on_idle` 或 idle hook 抛出的错误），service 会被停止。

## 5. RPC

完全在 Lua 层实现（`lua/service.lua`）：

- 每个 service 维护一个 `next_session`，在 1..UINT32_MAX 范围内回绕，并跳过仍在等待中的 session。
- `call` 在发送前先检查当前 coroutine 是否由运行时管理，然后分配 session 并发送 REQUEST。发送失败时直接返回 `nil, err`，不挂起。发送成功后，把 `session → coroutine` 记入等待表，然后 yield。
- 接收方为每个 REQUEST 创建一个 coroutine，并记下 `from` 和 `session`。handler 正常返回后发送 RESPONSE。handler 抛错时（由 `resume_session` 捕获）用 `debug.traceback(co, msg)` 带上 traceback 记录日志：session > 0 时记为 WARN 并发送 ERROR，否则记为 ERROR。
- 收到 RESPONSE 或 ERROR 时，按 session 找到等待中的 coroutine 并恢复它。找不到时直接释放 payload。运行时不校验响应的 `from`。
- 信任模型：一旦请求被接收，就假定接收方一定会回复（completion 必达）。因此没有超时、取消、重试，也不处理迟到的响应。

## 6. 生命周期

```text
NEW ─start─▶ STARTING ─init ok─▶ RUNNING ─stop─▶ STOPPING ─thread exit─▶ STOPPED ─join─▶ JOINED ─▶ FREED
                 │                                   ▲
                 └──────────── init 失败 / stop ─────┘
```

**启动**（`service_start` 在调用方线程等待 `start_done`）：

1. 线程中依次执行 `uv_loop_init`、初始化 `inbox_async` 和 `control_async`；
2. `luaL_newstate`、`openlibs`，然后编译 source；
3. 加载 luv 并绑定到本 loop（写入 `package.loaded.luv`）；
4. `require "service"`，再调用 `service.input(self, config)` 完成绑定（自动绑定）；
5. 执行 source，参数为 `(addr, config_ptr)`。如果返回 table，用 `service.dispatch` 规范化。结果必须是函数，并被保存到 registry；
6. 释放 config buffer，状态切换到 RUNNING，唤醒 `start`。主动触发一次 `inbox_async`（这样启动前已入队的消息也会被处理），然后进入 `uv_run`。

任一步失败时，`start_error` 被设置，状态进入 STOPPING，然后走统一的收尾流程。Lua 侧的 `_start` 收到错误后会 join 这个 service，再抛出 `SERVICE_START_FAILED`。

**停止**（`service_stop`，可以从任意线程调用，幂等）：

1. retire：把 routable 置为 false。之后的新发送都会失败；
2. 状态切换到 STOPPING，关闭邮箱；
3. 第一次请求时调用 `uv_async_send(control_async)`。

**控制回调**（在 service 线程执行）：等待 `send_pins` 归零，然后取出并释放邮箱中剩余的消息，其中 session > 0 的 REQUEST 先回复一条不带 payload 的 ERROR；最后关闭两个 async handle。这两个 handle 关闭完成后，用 `uv.walk` 关闭所有 luv handle，此时 loop 自然退出。

**线程收尾**（`service_finish_thread`）：

- 再执行一遍 prepare_shutdown，覆盖启动失败的路径；
- 如果 Lua 已初始化完成，以 `"stop"` 调用一次 dispatcher，回复已接收、尚未回复的请求；
- 循环执行 close handles、`uv_run`、`uv_loop_close`，直到 loop 不再处于忙状态；
- `lua_close`，状态切换到 STOPPED。

**join**：`pthread_join` 之后状态切换到 JOINED。随后执行 `service_free`：等待 pin 归零，释放邮箱、source 和 config，状态切换到 FREED。并发调用 join 时，后来者等待第一个 join 完成，然后返回它的结果。

**退出原因**：`service_t.exit_error` 记录 service 为什么停止，只保留第一次写入的值。写入来源有两个：`service.quit(err)`（通过 `_stop` 的第二个参数），以及 `service_async_cb` 中 dispatcher 的 `lua_pcall` 失败。这个字段在 join 之后仍保留在墓碑中，pool 删除时才释放。

**bootstrap 入口**：入口命令以 `MESSAGE_SYSTEM` 发送，payload 为 `("bootstrap", entry, ...)`。dispatcher 为它创建一个由运行时管理的 coroutine（session 为 0），用 `xpcall` 执行 `request(entry, ...)`，出错时在栈展开前取得 traceback。LuaJIT 允许在 `xpcall` 内部 yield，所以入口中可以正常 `call` 和 `sleep`。如果出错，就以 ERROR 级别记录 traceback 并执行 `service.quit(message)`。

**`service.root` 的环境判断**：`lua/service/root.lua` 用 `service.self` 区分宿主和 service。这依赖 native 的启动顺序：执行 source 之前，已经调用过 `service.input(addr, config)`。调用者通过 `debug.getinfo` 查找：第 1 层是查找函数本身，第 2 层是模块主体，从第 3 层往上跳过 C 栈帧（即 `require`），第一个 Lua 栈帧就是调用者。LuaJIT 的尾调用不会保留栈帧，所以模块里写 `return require "service.root"` 时，调用者看起来是主脚本。这种情况最终会因为主脚本没有返回 handler 而启动失败。

**pool 删除**：`service_pool_delete` 先对所有 service 执行 stop，再逐个 join，然后释放所有 `service_t` 和 pool 本身。Lua 侧通过 `_pool_delete` 调用它，`bootstrap` 在 root 退出后使用。

**限制**：

- 停止是协作式的。运行时无法打断一个永不 yield 的 handler。
- 停止时不会恢复挂起中的 `call` 或 `sleep`，这些 coroutine 随 VM 一起销毁。但在销毁之前，`service_finish_thread` 会以 `"stop"` 为参数调用一次 dispatcher，由 Lua 为所有已接收、尚未回复的请求（session > 0）回复不带 payload 的 ERROR。调用方的 `call` 收到这种 ERROR 时返回 `nil, "service stopped"`。
- 不带 payload 的消息在 Lua 中表现为 `msg == nil`。

## 7. luv 加载

`luaopen_service_c` 首次被调用时，用 `pthread_once` 在 `package.cpath` 中找到 `luv.so`，以 `RTLD_NOW | RTLD_GLOBAL` 打开它，并解析出 `luaopen_luv` 和 `luv_set_loop` 两个符号。

此后每个 service VM 的处理是：先调用 `luv_set_loop(L, &service->loop)`，再调用 `luaopen_luv`，把得到的模块写入 `package.loaded.luv`。因此在 service 中执行 `require "luv"` 时，拿到的就是绑定到本 loop 的实例。宿主线程中的 `require "luv"` 是普通加载，使用默认 loop。

## 8. 序列化

使用 ltask 版本的 lua-seri，并针对 LuaJIT 修正了共享引用和小数键的问题。

- buffer 由 `malloc` 分配，用 `free` 释放。运行时信任 `ptr` 和 `size` 的来源。
- 发送路径上，所有权从发送方转移到邮箱，再转移到接收方，接收方通过 `unpack_remove` 或 `remove` 释放。失败的发送、停止时清空邮箱、找不到 session 的响应，都会由运行时负责释放。payload 可以为空（NULL），例如停止时回复的 ERROR。
- 编码格式不是对外 ABI，只保证 `pack`、`unpack`、`unpack_remove`、`remove` 这几个 Lua 接口的调用形式稳定。

## 9. 不变量清单

1. Lua 代码和非 async 的 libuv handle 只在所属 service 的线程上被访问。
2. 任何消息 payload 在任一时刻只有一个所有者，并且恰好被释放一次。
3. `send` 返回成功意味着目标邮箱已持有这条消息；返回失败意味着这条消息永远不会被处理。
4. 运行时生成的 addr 和 ID 在 pool 存续期间不会指向另一个 service。
5. `service_free` 必须在 `send_pins == 0` 之后才释放邮箱。
6. 未知名字或非字符串名字绝不能解析为 root（ID 0）。
