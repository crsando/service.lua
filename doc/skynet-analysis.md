# cloudwu/skynet 消息系统研究报告

## 1. 结论先行

Skynet 对 mailbox、消息和 Lua 序列化的处理可以概括为四个相互配合的约定：

1. 每个 service context 拥有一个自旋锁保护的、可动态扩容的环形 mailbox。所有 producer 都在同一把锁下入队，因此它是 MPSC 安全的，但不是无锁队列，也没有满载失败或 backpressure。
2. `struct skynet_message` 只是按值存入环形数组的消息描述符。真正需要管理的是 `data` 指向的独立 payload。payload 在任意时刻只有一个 owner，并在 send、mailbox、callback、forward 之间显式转移。
3. service 地址生命周期由 handle registry 和 context 原子引用计数保护。退出时先从 registry 摘除 handle，再等待已经取得的引用释放；context 最终销毁时只标记 mailbox，mailbox 由调度线程延迟 drain 和释放。
4. `lua-seri` 只负责把 Lua value 编码到一块 `malloc` buffer。它没有 Buffer Registry，也不拥有传入 `unpack` 的 buffer。默认 Lua 消息处理期间 payload 是借用状态，callback 返回后由 C core 释放。

Skynet 真正解决生命周期竞争的关键，不是给 `message` 或 buffer 加引用计数，而是组合了以下三层边界：

```text
handle registry: 阻止退出后产生新的发送引用
context refcount: 等待已经开始的发送和 dispatch 完成
mailbox release: 等 context 不再可达后，由 scheduler drain 并回收残留消息
```

这套思路值得当前项目借鉴，但实现不能直接复制。Skynet 是多个 worker pthread 调度大量 service context；当前项目的初心是一个 service 固定拥有一个 pthread、一个 Lua VM 和一个 libuv loop。当前项目现已采用 bounded spinlock MPSC mailbox、按值 descriptor、`scheduled` 唤醒状态和显式 `MAILBOX_FULL`；仍不引入 Skynet 的 global ready queue、动态扩容或 Buffer Registry。下一步应集中解决 stable handle、send pin、停止顺序及 drain。

## 2. 研究基线与范围

- 上游仓库：[cloudwu/skynet](https://github.com/cloudwu/skynet)
- 研究提交：[`2251550a785480fb04c343da1eb8b42f9a8484fd`](https://github.com/cloudwu/skynet/commit/2251550a785480fb04c343da1eb8b42f9a8484fd)
- 提交时间：2026-08-05 09:25:52 +08:00
- 本报告重点：本地消息发送、mailbox 调度、service 退出、Lua binding 和 `lua-seri`
- Harbor 远程消息只分析所有权交接，不展开网络协议和 socket buffer 实现

Skynet 源码中没有名为 `message_t` 的类型。与当前项目 `message_t` 对应的是 [`struct skynet_message`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_mq.h#L7)。

主要依据：

- [`skynet_mq.c`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_mq.c)：mailbox 和 global queue
- [`skynet_server.c`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_server.c)：context、send、dispatch 和退出回收
- [`skynet_handle.c`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_handle.c)：handle 注册、grab 和 retire
- [`skynet_start.c`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_start.c)：worker 调度循环
- [`lua-skynet.c`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/lualib-src/lua-skynet.c)：Lua/C 所有权边界
- [`lua-seri.c`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/lualib-src/lua-seri.c)：序列化格式和 buffer 分配
- [`skynet.lua`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/lualib/skynet.lua)：Lua coroutine dispatch 和 RPC

## 3. 先区分两种运行模型

Skynet 的 service 不是一 service 一 pthread。多个 worker pthread 从 global queue 取得某个 service 的 mailbox，执行一批消息后再调度其他 mailbox，入口见 [`thread_worker`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_start.c#L156)。同一 service 的 callback 不会并行执行，但它前后两批消息可能由不同 worker 执行。

```text
Skynet

many producers
      |
      v
per-service mailbox -- global ready queue --> worker pool --> service callback

当前项目

many producers
      |
      v
per-service mailbox -- uv_async --> dedicated pthread/libuv loop --> Lua handler
```

因此，Skynet 的 global queue 解决的是“哪个 worker 接下来运行哪个 service”。当前项目已经由 service 专属 libuv loop 决定消费位置，只需要可靠唤醒目标 loop，不需要再建立一层全局 runnable mailbox 调度。

## 4. Mailbox 的数据结构

Skynet 的每 service mailbox 定义在 [`message_queue`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_mq.c#L21)：

| 字段 | 作用 |
| --- | --- |
| `lock` | 保护 queue、head/tail、release 和 in_global |
| `handle` | mailbox 所属 service 地址 |
| `cap/head/tail` | 环形数组容量和读写位置 |
| `release` | context 已最终销毁，mailbox 可以回收 |
| `in_global` | mailbox 已在 global queue 或正由 worker dispatch |
| `overload` | 最近一次越过阈值时观察到的队列长度 |
| `overload_threshold` | 从 1024 开始按 2 倍增长的告警阈值 |
| `queue` | 按值存放 `struct skynet_message` 的数组 |
| `next` | global queue 的 intrusive 链表指针 |

初始容量是 64。初始化时 `in_global` 被设为 1，但 queue 尚未真正放入 global queue。这会阻止 service 模块初始化期间收到的消息过早触发 dispatch；初始化成功后 context 显式把 queue 放入 global queue，见 [`skynet_mq_create`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_mq.c#L77) 和 [`skynet_context_new`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_server.c#L124)。

## 5. Push、pop 和竞争为什么成立

### 5.1 Push 不是一个孤立的原子指令

[`skynet_mq_push`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_mq.c#L189) 在 mailbox 自旋锁内完成：

1. 把整个 `struct skynet_message` 复制到 `queue[tail]`。
2. 推进 tail。
3. head 和 tail 相遇时扩容为 2 倍。
4. 如果 `in_global == 0`，将其设为 1 并挂入 global queue。

这条线性化路径保护的不是单个指针写入，而是 slot 内容、tail、满/空状态、扩容和 runnable 状态的组合不变量。即使某个 `queue_push_ptr` 能原子写一个指针，也不能单独保证这些状态一致。

Skynet 默认的 spinlock 使用 acquire `atomic_exchange` 和 release `atomic_store`，见 [`spinlock.h`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/spinlock.h#L48)。也可以编译为 pthread mutex。语义上它仍是锁保护队列，不是 lock-free queue。

### 5.2 不会丢失“空队列变为非空”的唤醒

[`skynet_mq_pop`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_mq.c#L137) 也持有同一把 mailbox lock。只有 pop 确认队列为空时，才把 `in_global` 清零。

producer 和 consumer 的竞争只有两种合法结果：

- producer 先取得锁：消息进入队列，consumer 随后能看到它，`in_global` 保持 1。
- consumer 先取得锁并确认为空：它把 `in_global` 清零；producer 随后看到 0，会重新把 mailbox 放进 global queue。

因此，没有“consumer 看见空以后准备睡眠，同时 producer 入队但没有重新调度”的状态窗口。

### 5.3 同一 mailbox 同时只有一个 consumer

`in_global == 1` 同时表示“已排队”或“正在 dispatch”。global pop 不清除它。worker 持有 mailbox 期间，producer 只入队，不会重复把同一个 mailbox 放进 global queue。

dispatch 一批后：

- 如果还有其他 ready mailbox，当前 mailbox 被放回 global queue，worker切换到下一个。
- 如果 global queue 为空，当前 worker直接保留当前 mailbox，下一轮继续处理。
- 如果当前 mailbox 为空，pop 已经把 `in_global` 清零，worker转去 global queue。

这部分逻辑在 [`skynet_context_message_dispatch`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_server.c#L292)。它既保证单 mailbox 串行消费，也提供 service 间的批量公平调度。

### 5.4 它不提供 backpressure

queue 满时 [`expand_queue`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_mq.c#L174) 分配 2 倍数组并复制旧元素，不返回 `FULL`。长度跨过 1024、2048、4096 等阈值时，consumer 记录一次 overload 告警；队列重新变空后阈值复位，见 [`skynet_mq_overload`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_mq.c#L127)。

这解决的是“尽量不丢消息”，代价是过载时内存可以持续增长。Skynet 默认 Linux/jemalloc 构建的分配失败策略是直接 abort 进程，见 [`malloc_hook.c`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/malloc_hook.c#L111)。

当前项目已经选择 bounded mailbox 和显式 `MAILBOX_FULL`，这更符合错误可见性和资源上限的初心，不应改回 Skynet 的无限扩容策略。

### 5.5 Global queue 与 worker 唤醒

Global queue 自己还有一把自旋锁，内部是 mailbox 的单链表，见 [`global_queue`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_mq.c#L35)。`skynet_globalmq_push` 只发布 runnable mailbox，本身不直接 signal worker condition。已有 worker 会在下一轮 dispatch 看到新任务；socket 线程在产生事件后唤醒 worker，timer 线程也以约 2.5 ms 周期唤醒，相关入口见 [`skynet_start.c`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_start.c#L55)。

这是 worker-pool 架构的一部分。当前项目不能据此省略 `uv_async_send`，因为每个目标 service 的专属 libuv loop 需要自己的跨线程唤醒。

## 6. `skynet_message` 与 payload 的关系

消息描述符只有四个字段：

```c
struct skynet_message {
    uint32_t source;
    int session;
    void *data;
    size_t sz;
};
```

它本身没有 refcount、destructor 或 ownership flag。消息 type 编码在 `sz` 的最高 8 bit，实际 payload size 位于其余 bit，定义见 [`skynet_mq.h`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_mq.h#L7)。mailbox 复制这个小结构，payload 不复制。

因此需要分别看两个生命周期：

```text
message descriptor: sender stack -> mailbox slot -> worker stack
payload allocation: sender/core -> mailbox -> callback borrow/own -> free or forward
```

Skynet 没有为每条本地消息单独 malloc descriptor。当前项目也已改为在 mailbox ring 和 consumer 栈之间按值复制 `message_t`，不再分配 envelope；payload 仍然独立转移和释放。

## 7. 本地发送的完整所有权状态机

[`skynet_send`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_server.c#L695) 支持两种输入契约。

### 7.1 默认 copy

未设置 `PTYPE_TAG_DONTCOPY` 时：

1. 调用方仍拥有原始内存。
2. core 分配 `sz + 1` 字节并复制 payload，额外写入 `\0`。
3. 从此 core 拥有这个副本。
4. 目标无效、地址为 0 或后续 push 失败时，core 释放副本。
5. 入队成功后，所有权转给 mailbox。

### 7.2 `PTYPE_TAG_DONTCOPY`

设置该 tag 时，调用 `skynet_send` 就表示把 payload 转交给 core。无论目标有效与否，调用方都不能再释放或使用它：

- 消息过大时 core 释放。
- 名称解析或目标 handle 失败时 core 释放。
- 本地 push 成功时 mailbox 接管。
- 远程消息时 harbor wrapper 接管。

copy/tag 处理位于 [`_filter_args`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_server.c#L674)，本地失败释放位于 [`skynet_send`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_server.c#L696)。

### 7.3 入队与 dispatch

```text
sender
  |
  | skynet_send(copy or take ownership)
  v
handle_grab(destination)
  |
  | mq_push copies descriptor
  v
mailbox owns payload
  |
  | mq_pop copies descriptor to worker stack
  v
callback temporarily receives data,size
  |
  +-- callback returns 0 --> core free(data)
  |
  `-- callback returns 1 --> callback/forward path owns data
```

默认回收发生在 [`dispatch_message`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_server.c#L255)。callback 返回值不是业务结果，而是“是否保留 payload”的内部所有权信号。

如果 context 尚未注册 callback，worker 也会直接释放 payload，见 [`skynet_context_message_dispatch`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_server.c#L327)。

### 7.4 远程分支的额外交接

目标是远程 handle 时，core 把原 payload 放入新分配的 `remote_message` wrapper，再把 wrapper 作为 `PTYPE_SYSTEM` 消息发送给被保留引用的 harbor context，见 [`skynet_harbor_send`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_harbor.c#L19)。harbor callback 返回后，普通 dispatch 规则释放 wrapper；wrapper 内的原 payload 则由 harbor 的发送队列接管，或在远程发送失败时显式释放，见 [`service_harbor.c`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/service-src/service_harbor.c#L703)。

也就是说，wrapper 和原 payload 是两层独立 allocation，harbor 必须分别完成它们的所有权闭环。

## 8. Handle、context 与 mailbox 的退出协议

### 8.1 为什么仅让 mailbox push 原子化仍然不够

send 的目标不是一个永生 queue，而是一个可能同时退出的 service。下面的序列会造成 UAF：

```text
sender: lookup service pointer
target: unregister, close, free service/mailbox
sender: push through stale pointer
```

Skynet 在 lookup 和 push 外增加了 context pin。`skynet_context_push` 先 `skynet_handle_grab(handle)`，成功后才访问 `ctx->queue`，push 完成后 release，见 [`skynet_context_push`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_server.c#L224)。

handle grab 在 registry 的读保护下确认 handle 与 context 匹配，并增加 context 原子 ref；retire 在写保护下先清空 slot，再释放 registry 持有的 ref，见 [`skynet_handle_grab`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_handle.c#L194) 和 [`skynet_handle_retire`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_handle.c#L131)。

结果是：

- retire 后开始的新 send 无法 grab，明确失败。
- retire 前已经 grab 的 send 可以安全完成 push。
- context 在最后一个 in-flight ref 释放前不能销毁。

### 8.2 创建时的两个初始引用

context 创建时 ref 初始化为 2：一个代表 handle registry，一个代表模块初始化过程，见 [`skynet_context_new`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_server.c#L124)。

- 初始化成功：queue 首次进入 global queue，释放初始化引用，registry 引用继续维持 context。
- 初始化失败：先释放初始化引用，再 retire handle；最后一个引用触发 context 删除和 queue release。

这样，初始化期间发到该 service 的消息可以先排队，但不会在模块准备完成前执行；初始化失败时仍会被统一 drain。

### 8.3 退出分成三步

```text
1. retire handle
   registry 不再产生新 ref
             |
             v
2. final context_release
   释放模块实例，mark mailbox release，释放 context
             |
             v
3. scheduler observes handle missing
   drain queued messages，释放 payload，释放 mailbox
```

`delete_context` 不直接 free mailbox，而是调用 [`skynet_mq_mark_release`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_mq.c#L219)。如果 mailbox 当前不在 global queue，它会被重新挂入，保证最终有 worker看到它。

worker 取得 mailbox 后若无法 grab 对应 handle，就调用 [`skynet_mq_release`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_mq.c#L239)：

- `release == 0`：说明仍有 in-flight context ref，mailbox 重新排队等待。
- `release == 1`：说明所有可能 push 的引用已经结束，安全 drain 和 free。

这正是 mailbox 可以晚于 context 存活的原因。

### 8.4 残留消息如何处理

每条未处理消息通过 [`drop_message`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/skynet-src/skynet_server.c#L110)：

1. 释放 payload。
2. 以已经退出的 handle 作为 source，向原消息 source 发送同 session 的 `PTYPE_ERROR`。

session 非 0 时，这会唤醒等待 RPC 的 coroutine。session 为 0 的 error 在 Lua 层还承担“该来源 service 已退出”的通知语义，会清理对该 service 的观察关系，见 [`_error_dispatch`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/lualib/skynet.lua#L345)。错误消息自身投递失败时没有无限补偿，payload 已经回收。

## 9. Lua binding 如何交接 payload

### 9.1 发送端

[`send_message`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/lualib-src/lua-skynet.c#L245) 根据 Lua 参数类型选择所有权策略：

| Lua 参数 | C 调用 | 结果 |
| --- | --- | --- |
| string | 普通 `skynet_send` | core 复制，Lua string 不受影响 |
| lightuserdata + size | 自动加 `DONTCOPY` | core 接管该 malloc buffer |

`skynet.pack(...)` 返回的正是 `lightuserdata, size`，所以惯用写法 `c.send(addr, type, session, p.pack(...))` 是一次零额外 copy 的所有权转移。`skynet.packstring(...)` 则把临时 malloc buffer 复制成 Lua string 后立即 free，见 [`lpackstring`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/lualib-src/lua-skynet.c#L388)。

### 9.2 接收端默认是借用

C callback 把 `msg` 作为 lightuserdata、把 `sz` 作为 integer 传入 Lua。普通 callback 无论 Lua 调用成功或失败都返回 0，见 [`_cb`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/lualib-src/lua-skynet.c#L53)。因此：

- Lua dispatch 执行期间可以读 payload。
- callback 返回 C core 后，payload 立即释放。
- Lua 不能把原始指针保存到 callback 之外继续使用。

正常 request 在启动业务 coroutine 前先执行 `p.unpack(msg, sz)`；正常 response 在恢复等待 coroutine 后也立即进入 protocol unpack，见 [`raw_dispatch_message`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/lualib/skynet.lua#L901)。解码后的 string/table 已经属于接收 Lua VM，不再依赖原 buffer。

`c.tostring(ptr, size)` 同样复制成 Lua string。`c.trash(ptr, size)` 对 lightuserdata 执行 free，对 Lua string 不操作，见 [`ltrash`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/lualib-src/lua-skynet.c#L398)。

### 9.3 Forward 模式是手工所有权模式

Lua callback 注册的第二个参数为 true 时，C 使用 [`forward_cb`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/lualib-src/lua-skynet.c#L90)，固定返回 1，core 不再 free payload。

此时 Lua 路径最终必须且只能完成一次所有权处置：

- 把指针通过另一个 `DONTCOPY` send 继续转移；或
- 调用 `c.trash` 释放。

[`skynet.forward_type`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/lualib/skynet/manager.lua#L67) 展示了这种用法。它性能直接，但异常路径依赖调用者严格遵守契约；没有 registry 帮助检测泄漏、double free 或保存过期指针。

## 10. `lua-seri` 实际解决了什么

### 10.1 它的定位

Skynet `lua-seri` 是同一进程内不同 Lua service 之间的快速 value codec。它不是持久化格式、跨机器格式或不可信输入格式。从源码可见，整数、double、指针和长度直接使用本机字节序及本机构型。

pack 使用 128 字节临时 block 链构造结果，最后合并到一块连续的 `skynet_malloc(len)` buffer，返回 `(lightuserdata, len)`，见 [`seri`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/lualib-src/lua-seri.c#L545) 和 [`luaseri_pack`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/lualib-src/lua-seri.c#L614)。

unpack 接受两种输入：

- Lua string：从 string 长度得到边界。
- lightuserdata + size：显式以 size 作为边界。

它只读 buffer，从不 free，见 [`luaseri_unpack`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/lualib-src/lua-seri.c#L570)。释放由消息 callback 或显式 `trash` 负责。

### 10.2 字节格式

每个 value 以一个 tag byte 开始：低 3 bit 是 type，高 5 bit 是 cookie。

| type | Lua value | cookie / 后续数据 |
| --- | --- | --- |
| 0 | nil | 无 |
| 1 | boolean | 0=false，1=true |
| 2 | number | 0=整数0，1=uint8，2=uint16，4=int32，6=int64，8=double |
| 3 | lightuserdata | 后续为本机 `void *` 字节 |
| 4 | short string | cookie 为 0..31 字节长度，随后原始字节 |
| 5 | long string | cookie 2 或 4 表示长度字段宽度，随后内容 |
| 6 | table | cookie 为 array 长度；31 表示长度另编码为 integer |

定义见 [`lua-seri.c` tags](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/lualib-src/lua-seri.c#L16)。顶层不保存 value 个数，而是连续解码到 buffer 末尾，所以顶层 nil 仍可被保留。

table 的编码顺序是：

```text
TABLE tag
array part: value[1] ... value[array_size]
hash part: key, value, key, value, ...
NIL tag as hash terminator
```

array 长度来自 `lua_rawlen`，hash 遍历时跳过 `1..array_size` 的整数 key。table metatable 本身不会序列化；如果 table 有 `__pairs`，encoder 会调用它来生成 hash entries，相关实现见 [`wb_table`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/lualib-src/lua-seri.c#L286)。

### 10.3 支持与不支持

| Lua 类型/特性 | Skynet `lua-seri` |
| --- | --- |
| nil / boolean | 支持 |
| integer / double | 支持，紧凑整数编码 |
| binary string | 支持 |
| lightuserdata | 支持，原样复制地址值 |
| 普通 table | 支持 |
| metatable | 不保留 |
| `__pairs` | 编码时调用 |
| 共享 table identity | 不支持，同一个 table 会重复展开 |
| 循环 table | 不支持，最终触发深度错误 |
| full userdata | 不支持 |
| Lua function / C function | 不支持 |
| thread/coroutine | 不支持 |

普通 table 没有 object ID 或 reference tag。`MAX_DEPTH` 为 32，递归过深时释放临时 block 并抛出错误，见 [`pack_one`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/lualib-src/lua-seri.c#L304)。这个限制避免循环无限递归，但不保留循环结构。

### 10.4 输入检查和信任边界

decoder 的 `rb_read` 在每次读取前检查剩余字节，截断的普通字段通常会报 `Invalid serialize stream`，见 [`rb_read`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/lualib-src/lua-seri.c#L118)。但它不是 hardened parser：

- 长度和总 buffer 使用 `int`，Lua string 的 `size_t` 会转成 `int`。
- 4 字节 string length 转成后续读取长度时没有完整处理大于 `INT_MAX` 的情况。
- 没有 magic、version、checksum、对象数或总元素数上限。
- lightuserdata 会直接还原任意地址值。
- 格式依赖本机 endian、`sizeof(void *)`、`sizeof(lua_Integer)` 和 double 表示。

这些选择与“只接收本进程可信 service 生成的 buffer”相匹配，不能把 `unpack` 暴露给网络或文件中的任意字节。

### 10.5 内存与异常策略

- 默认 Linux/jemalloc 构建中，Skynet allocator OOM 时 abort 整个进程，不走可恢复的 Lua OOM 路径。
- 明确检测到不支持类型、table 太深或 `__pairs` 失败时，encoder 会释放已分配的 block 链再抛错。
- pack 成功后的连续 buffer 不由 Lua userdata `__gc` 托管，调用者必须 send、trash 或转成 `packstring`。
- unpack 不消费 buffer；默认消息 callback 在 unpack 完成并返回 C 后释放它。

这里同样没有 Buffer Registry。Skynet 依靠 API 调用形态和单 owner 约定，而不是运行时追踪每个指针。

### 10.6 Lua 版本差异

当前 Skynet 发布线使用定制 Lua 5.4，v1.8.0 更新到 Lua 5.4.7，见 [`HISTORY.md`](https://github.com/cloudwu/skynet/blob/2251550a785480fb04c343da1eb8b42f9a8484fd/HISTORY.md#L1)。当前项目目标是 LuaJIT 2.1 / Lua 5.1 API。`lua_rawlen`、`lua_isinteger`、`lua_newuserdatauv` 等接口和 integer/number 语义都不同，所以 Skynet 当前 `lua-seri.c` 可用于理解契约，不能直接复制替换。

## 11. `shared table` 与 `lua-seri` 不是一件事

研究基线提交的标题是“修复 shared table 在 GC 标记和写入时的两处保护缺失”。该提交修改的是 Skynet 定制 Lua VM 中的共享只读对象保护：防止 shared object 被错误挂入某个 VM 的 GC gray 链，并阻止 `lua_rawset` 绕过只读检查。

它对应 `skynet.sharetable` 这类跨 VM 只读共享机制，不是 `lua-seri` 的 table reference 编码。当前 `lua-seri.c` 没有 shared reference/cycle 协议。两者不能据提交标题混为一谈：

```text
lua-seri:      把 Lua value 复制为消息 payload，再在目标 VM 重建
sharetable:    多 VM 观察同一个受保护的只读共享对象
```

当前项目的初心是 service 间不共享 Lua 对象，因此没有必要为了对齐这次上游提交引入 sharetable。

## 12. Skynet 没有解决或刻意不做的事情

完整理解 Skynet 也需要明确它的边界：

1. Mailbox 没有硬容量和发送失败 backpressure，过载最终由内存承担。
2. Payload 指针没有来源校验、generation、double-free 检测或 GC 自动兜底。
3. `DONTCOPY` 和 forward 模式都依赖调用者正确转移所有权。
4. `lua-seri` 不支持普通 table cycle 和共享 identity。
5. 序列化格式不是跨平台稳定 ABI，也不适合不可信输入。
6. `unpack` 不负责释放；脱离默认 callback 路径时必须人工安排 free。
7. OOM 采用进程 abort，而不是 per-service 错误恢复。
8. 动态 mailbox 只记录 overload，不阻止生产者继续放大积压。

这些并非都属于缺陷。它们是 Skynet 在可信、同进程、高性能 Actor runtime 中作出的边界选择。当前项目可以采用同样的信任前提，但仍可保留 bounded mailbox 和更明确的错误结果。

## 13. 与当前项目逐项比较

| 维度 | Skynet | 当前项目/既定方向 |
| --- | --- | --- |
| service 执行 | worker pool 调度 context | 每 service 固定 pthread + Lua VM + libuv loop |
| mailbox 并发 | spinlock MPSC | bounded spinlock MPSC |
| mailbox 容量 | 64 起步，满时 2 倍扩容 | 创建时固定容量，满时 `MAILBOX_FULL` |
| mailbox 元素 | `skynet_message` 按值 | `message_t` 按值 |
| runnable 通知 | `in_global` + global ready queue | `scheduled` + 目标 service 的 `uv_async` |
| 单 service 消费 | `in_global` 保证不并行 | 专属 pthread 天然单 consumer |
| 地址安全 | handle registry + context ref | stable tombstone + pool-locked send pin |
| 退出 drain | scheduler 延迟释放 queue | retire/close/wait pins 后由专属线程 drain |
| payload 正常回收 | callback 返回后 core free | recv 后转给 Lua，`unpack_remove/remove` free |
| send copy | string copy，pointer transfer | `pack` pointer transfer |
| backpressure | 无，只告警 overload | 显式 FULL/CLOSED |
| serializer 长度 | 由外部 `(ptr,size)` 给出 | buffer 内另有 4 字节长度，公开 size 未用于 decode 边界 |
| table cycle/ref | 不支持 | 复制来的增强版试图支持；非 ancestor shared ref 回归测试仍为 red |
| C function | 不支持 | 当前增强版允许无 upvalue C function |
| Buffer Registry | 无 | 已决定当前阶段不引入 |

当前 [`mailbox.c`](../src/mailbox.c) 用一把 test-and-test-and-set spinlock 保护 slot、head/tail/count/closed/scheduled。生产者只有在 `scheduled` 从 false 变为 true 时请求 `uv_async` 唤醒；consumer 只有在 pop 明确观察到 empty 时清零。它复用了 Skynet 的正确性核心，同时保留 dedicated-thread 模型和 bounded backpressure，没有必要为了“原子 push”再改成复杂 lock-free 算法。

当前消息路径形成以下单 owner 规则：

```text
compose          -> sender 栈 descriptor 持有 payload
push 失败        -> sender 调 message_dispose 释放 payload
push 成功        -> mailbox slot 持有 payload
recv             -> consumer 栈 descriptor 持有 payload
Lua binding      -> payload 转交 receiver Lua/runtime
unpack_remove    -> 解码成功或失败都 free payload
mailbox_delete   -> drain 后 message_dispose
```

消息局部所有权与 `service_t *`/`uv_async_t` 的外层生存期现在已经串成闭环：runtime 生成的 addr 以不复用 ID 和 tombstone 保持稳定，send pin 覆盖 push/notify，stop 在关闭 async 前等待 pin 归零。

当前 `lua-seri` 与 Skynet 当前版本不是同一协议。它带 4 字节内部长度、table ref/cycle 和 C function 扩展。非 ancestor 共享引用已经按其直接上游 ltask 的 `TABLE_MARK + REF` 协议修复，并由 [`serializer_shared_ref_spec.lua`](../tests/lua/serializer_shared_ref_spec.lua) 覆盖。仍需注意：[`seri_unpack`](../src/lua-seri.c) 从 buffer 前 4 字节自行读取长度，而不是以公开传入的 `size` 约束读取；该可信 buffer 边界和格式加固仍属于后续可选任务。

## 14. 当前实现与后续建议

### 已实现：stable handle 和 send pin

实现没有复制 Skynet 全套 handle storage，而是建立了以下最小闭环：

1. sender 在 pool registry lock 下按 ID/name 找到目标，并取得一个 send pin。
2. pin 成功后，即使目标同时开始 stop，`service_t`、mailbox 和 `uv_async_t` 也不能被 free。
3. stop 先从 registry 注销目标，禁止新的 pin。
4. 在 mailbox lock 下 close，使 close 与 push 有清晰线性化顺序。
5. stop 等待已有 send pin 归零，再关闭 async handle 和释放 mailbox。
6. sender 完成 `mailbox_try_push` 和必要的 notify 后释放 pin。

这对应 Skynet 最值得借鉴的 `handle_grab -> mq_push -> context_release` 路径。`tests/c/service_lifecycle_test.c` 覆盖旧 pin 阻塞 free、8 producer 与 stop/join 竞争，并进入 `make test-tsan`。

### 已实现：固定 payload ownership 表

保持现有精简约定即可：

| 结果 | payload owner |
| --- | --- |
| 参数验证失败、尚未接管 | 调用方仍持有 payload |
| mailbox push FULL/CLOSED | sender 释放 payload |
| mailbox push OK | mailbox/target runtime |
| consumer pop | consumer |
| normal unpack/remove | `unpack_remove` 正好释放一次 |
| drop during stop | drain 调 `message_dispose` |

不要让 send 返回失败后 payload 仍可能在目标处理，也不要让 send 返回成功后调用方再次 free。

### 已实现：notify 纳入同一个 pin

当前 send 在入队成功后调用 `uv_async_send`，并保证：

- notify 发生时 async handle 尚未 close/free。
- 入队成功但 notify 失败不能把所有权退回 sender，因为消息已经可被 consumer 观察。
- notify 失败应标记目标 runtime fault，并由停止流程 drain；不能静默遗留消息。

### 仍需补充的退出测试

至少覆盖：

- 每个 allocation/pthread/libuv 初始化失败点的故障注入。
- timer/socket/luv userdata 存活时的 loop close。
- `uv_async_send` 故障注入后的 runtime fault/drain。
- pool Lua GC/bootstrap shutdown 和精确资源计数归零。

### 暂不采用

- 不引入 Buffer Registry。
- 不采用 Skynet global ready queue。
- 不把 bounded mailbox 改成动态扩容。
- 不在生命周期工作中重写 serializer 格式。
- 不引入通用 forward/reserve 模式，除非出现明确的零拷贝转发需求。

## 15. 最终判断

Skynet 的 mailbox 本身并不神秘：一把短临界区自旋锁、一个动态 ring、一个防重复调度的 `in_global` 标志。它最成熟的部分是 mailbox 外围的生命周期协议。handle grab 保证 lookup 后对象仍活着，retire 阻止新 send，context ref 等待旧 send，mailbox release 再收尾残留 payload。这一结构直接回答了“push 已经原子，为什么仍会竞争”：竞争对象不仅是 queue slot，还包括目标 service、mailbox 和唤醒 handle 是否仍然存活。

当前项目已经补齐 `registry lookup/pin -> mailbox push -> uv_async_send -> unpin` 与 `unregister -> close -> wait pins -> drain -> free` 两条互斥闭环，并在可信 REQUEST/RESPONSE/ERROR 边界内验证了跨 service RPC、多返回值、嵌套调用和并发 pending 路径。有界 dispatch 现在每轮最多处理 256 条消息并执行一次 `on_idle`，积压通过 consumer 续唤醒交还 libuv 调度机会；当前主线下一步是修正剩余 Lua 公共 API 契约。消息、Lua 栈、payload 与 pool/bootstrap 的资源增长和归零验证移到后续发布稳定性阶段，逐初始化步骤故障注入和复杂 luv handle 异常关闭后置为可选运行时加固。现阶段继续信任上游生成的 native handle 与 `lua-seri` 裸 payload，不增加 Buffer Registry。任意 lightuserdata provenance 验证只在未来扩大信任边界时作为最终可选项。
