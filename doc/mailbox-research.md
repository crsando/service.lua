# 邮箱满（mailbox full）调研

本文记录邮箱容量问题的现状、skynet 和 ltask 的做法对比，以及最终选定的方案。调研时间：2026-10。

## 1. 问题

改造前，每个 service 的邮箱是固定容量的环形队列（`mailbox_size`，16 到 65536，默认 1024）。REQUEST、RESPONSE、ERROR、SYSTEM 四类消息共用这份容量。

- `mailbox_try_push` 发现队列已满时返回 `MAILBOX_FULL`。`lservice_send_message` 随后释放 payload，返回 `nil, "MAILBOX_FULL"`。
- 请求方向：`send` 返回 `nil, "MAILBOX_FULL"`，`call` 返回 `nil, "mailbox full"`。两者都立即返回，属于显式失败。
- **响应方向**：`send_response` 和 `send_error_response` 不检查 `_send_message` 的返回值。调用方邮箱满时，响应被静默丢弃，调用方永远挂起。

### 1.1 复现

- A 发出 `call("b", "ping")`，b 在 100 ms 后回复。
- 这期间，A 的另一个 coroutine 忙算 500 ms，不分发消息；filler 向 A 连发 2000 条消息，其中 1024 条成功入队，976 条被拒绝。
- b 回复时 A 的邮箱已满，响应被丢弃，A 的 `call` 2 秒后仍未返回。

这在行情场景里很现实：行情 service 的邮箱被 tick 塞满时，它对风控或交易 service 的 `call` 可能永远不返回。请求已被处理（可能已经下单），结果却丢失了。

### 1.2 问题清单

1. 响应被丢弃，调用方永远挂起（真 bug）。
2. 请求和响应共用容量，请求洪峰会挤掉响应。
3. 生产者只能失败即丢，运行时不提供背压手段。
4. 邮箱满时 `loopback` 给自己发消息也会失败，形成自锁。
5. 没有可观测性：看不到深度、高水位和拒绝次数。
6. 相关的 RT-2：service 停止时，邮箱里残留的请求和挂起中的请求都不会得到回复，调用方挂起。

## 2. skynet：无界队列

源码：`skynet-src/skynet_mq.c`、`skynet-src/skynet_server.c`、`lualib/skynet.lua`。

- 每个服务的消息队列初始容量为 64。push 时如果已满，就调用 `expand_queue` 把容量翻倍，没有上限，也不会缩小。
- 过载告警：pop 时，如果队列长度超过阈值（初始 1024），记下长度，并把阈值翻倍直到超过当前长度；队列清空时阈值恢复为 1024。dispatch 时检查到这个记录，就输出 `May overload, message queue length = N`。
- `skynet.send` 和 `skynet.call` 只在目标不存在时失败，响应一定能送达。
- `skynet.exit()` 退出时：
  - 对所有调用过本服务、尚未回复的 session，回复 `PTYPE_ERROR`；
  - 通知本服务调用过、尚未返回的那些服务；
  - 把回调换成"任何请求都回复 `PTYPE_ERROR`"，然后再退出。
- `skynet.call` 本身没有超时，需要业务用 `skynet.timeout` 或 `request:select(timeout)` 自己组合。

| 优点 | 缺点 |
| --- | --- |
| 不丢消息，也不丢响应，语义简单 | 没有背压：下游变慢时消息在内存中无限堆积，可能 OOM，延迟也可能失去意义 |
| 退出时回复所有挂起中的请求，调用方不会挂起 | 唯一的信号是告警日志 |
| | 队列只扩不缩 |

## 3. ltask：有界队列，请求快速失败，响应重试

源码：`src/ltask.c`（`dispatch_out_message`）、`src/service.c`（`service_push_message`）、`lualib/service.lua`（`post_request_message`、`post_response_message`）、`service/root.lua`（`send_retry`）。

- 每个服务的队列有上限：`DEFAULT_QUEUE 4096`，可以配置。
- 发送不直接写入对方队列，而是交给调度器。调度器 push 之后给发送方写回执：`DONE`、`BLOCK`（队列满）或 `ERROR`（目标已死）。
- 请求方向：收到 `BLOCK` 就 `error("{service:N} is busy")`，代码里留有 `-- todo: send again`。
- 响应方向：收到 `BLOCK` 时不丢弃，而是 fork 一个 coroutine 把响应交给 root（`send_retry`）。root 为每个目标维护一个 `retry_queue`，每个 tick（约 10 ms）按顺序重试，直到送达，或者目标已死时释放。如果交给 root 本身也被 BLOCK，就 `sleep(1)` 后再交。

| 优点 | 缺点 |
| --- | --- |
| 有背压：请求满了快速失败 | 响应可能延迟，按 10 ms 轮询 |
| 明确保证响应不丢 | 重试队列在 root 上，没有上限，等于把"无界"挪到了 root |
| | 所有重试都经过 root，形成集中点 |
| | 重试的响应与后续消息之间的顺序不保证 |

## 4. 对比

| | skynet | ltask | 本项目（改造前） |
| --- | --- | --- | --- |
| 队列 | 无界，自动翻倍 | 有界（4096） | 有界（默认 1024） |
| 请求满了 | 不会发生 | 报错 `is busy` | `nil, "mailbox full"` |
| 响应满了 | 不会发生 | 经 root 重试直到送达 | **静默丢弃，调用方挂起** |
| 停止时回复挂起中的请求 | `PTYPE_ERROR` | 目标已死时回执 `ERROR` | 无（RT-2） |
| call 超时 | 业务自行组合 | 未见内置 | 无（RT-1） |
| 过载信号 | 告警日志 | 无 | 无 |

## 5. 可选方案

1. **无界队列**（skynet）：满了就扩容，只有内存分配失败时才报错。
2. **响应走溢出链表**：响应不受容量限制，只在环形队列满时进入链表。响应总数天然受调用方未完成的 `call` 数量约束。
3. **call 时预留位置**：发起 `call` 时在自己邮箱中预留一格，响应消耗这个预留。普通消息的可用容量为 `capacity - reserved`；预留不到时 `call` 失败。没有 malloc，没有重试，没有任何无界结构。
4. **响应重试**（ltask）：在本项目中可以由响应方用自己的 uv timer 在本地重试，不需要经过 root。

## 6. 决策

先采用方案 1（skynet 思路），同时参考 skynet 解决 RT-2：

- 邮箱改为无界：`mailbox_size` 变为初始容量，满了就翻倍，不缩容。新缓冲区在锁外分配，避免生产者在自旋锁内等待 malloc。只有内存分配失败时，才返回 `MAILBOX_FULL`。
- 过载告警：沿用 skynet 的阈值翻倍算法，初始阈值等于邮箱的初始容量。超过阈值时，以 WARN 级别输出 `mailbox may overload, length = N`。
- RT-2：service 停止时：
  - 邮箱中残留的 REQUEST（session > 0），由 C 侧在清空邮箱时回复一条不带 payload 的 ERROR；
  - 已经开始处理、尚未回复的请求（例如挂起在 `call` 或 `sleep` 中），由 Lua 侧在线程退出前统一回复 ERROR；
  - 调用方收到不带 payload 的 ERROR 时，`call` 返回 `nil, "service stopped"`。
- 不实现 skynet 中"通知本服务调用过的那些服务"这一步。被调用方的处理不依赖调用方是否存活，迟到的响应会被当作"找不到 session"丢弃。

后续可选：

- 方案 3（预留位置）可以作为"有界模式"的基础：需要背压时，可以给 service 设置可选的容量上限。
- 增加 `mailbox_stat`，提供深度、高水位、扩容次数等观测数据。
- RT-1 的 call 超时仍然需要：目标卡死而没有停止时，调用方依然会挂起。

## 7. 落地结果（2026-10）

- `src/mailbox.c`：满时在锁外分配两倍容量的缓冲区，在锁内搬移（保持 FIFO），旧缓冲区在解锁后释放；如果容量在分配期间已被别的生产者改变，就丢弃新缓冲区重新判断。`MAILBOX_FULL` 只在内存分配失败时返回。新增 `mailbox_overload`、`mailbox_capacity`。
- `src/service.c`：
  - 每轮分发后检查过载，以 WARN 级别输出 `[svc N] mailbox may overload, length = N`；
  - `service_drain_mailbox` 对 session > 0 的 REQUEST 回复不带 payload 的 ERROR；
  - `service_finish_thread` 在销毁 VM 之前，以 `"stop"` 为参数调用一次 dispatcher（`service_notify_lua_stop`）。
- `lua/service.lua`：dispatcher 收到 `"stop"` 时，为所有已接收、尚未回复的请求回复 ERROR；`call` 收到不带 payload 的 ERROR 时返回 `nil, "service stopped"`。
- 顺带修复：`_recv_message` 对空 payload 推 `nil`，不再推 NULL lightuserdata；`unpack_remove` 对 NULL 指针直接返回。原先 NULL lightuserdata 不等于 `nil`，会让 `unpack_remove` 解引用空指针。
- 测试：
  - `tests/c/mailbox_test.c`：扩容时保持顺序，包括环形队列已回绕的情况；过载阈值；16 个生产者并发扩容容量为 1 的邮箱（同时在 TSAN 下运行）。
  - `tests/lua/mailbox_spec.lua`：扩容；第 1.1 节的响应丢失场景作为回归测试。
  - `tests/lua/stop_reply_spec.lua`：请求在邮箱中未处理、handler 挂起在 sleep 中、dispatcher 出错导致停止，这三种情况下调用方都得到 `service stopped`。
