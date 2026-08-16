# 消息、邮箱与所有权

## 消息结构

语义字段：

```c
typedef struct message {
    service_id_t from;
    service_id_t to;
    session_id_t session;
    int type;
    void *payload;
    size_t payload_size;
} message_t;
```

`REQUEST + session == 0` 表示单向消息。RPC 使用 REQUEST 与相同非零 session 的
RESPONSE/ERROR 配对；RESPONSE 表示成功，ERROR 表示失败。

## Mailbox

第一版采用 spinlock bounded MPSC ring。结构示意如下：

```c
typedef struct mailbox {
    spinlock_t lock;
    message_t *items;
    size_t capacity;
    size_t head;
    size_t tail;
    size_t count;
    bool closed;
    bool scheduled;
} mailbox_t;
```

spinlock 采用 test-and-test-and-set：acquire `atomic_exchange` 取得锁，竞争时 relaxed load 配合 CPU pause，release store 解锁。临界区内只做状态判断、描述符复制和游标更新，不分配/释放 payload，也不调用 libuv。

接口：

```c
mailbox_t *mailbox_new(size_t capacity);
mailbox_result_t mailbox_try_push(
    mailbox_t *box, const message_t *message, bool *notify);
bool mailbox_try_pop(mailbox_t *box, message_t *out);
void mailbox_close(mailbox_t *box);
void mailbox_delete(mailbox_t *box);
```

`try_push` 返回 OK/FULL/CLOSED。OK 时把描述符复制进 ring 并取得 payload 所有权；FULL/CLOSED 时不取得 payload。`notify` 只有在 OK 且 `scheduled` 从 false 变为 true 时才为 true。

`try_pop` 成功时把描述符复制到 `out`，payload 所有权转给 consumer。弹出最后一条消息时仍保持 `scheduled`；只有下一次 pop 确认队列为空时才清零。producer 与这个 empty pop 由同一把锁排序，因此不会丢失空到非空的唤醒。`delete` 会关闭并 drain 残留 payload；调用方必须先保证不会再有线程进入 mailbox。

## Send 事务

当前阶段信任 `lua-seri` 返回的 payload 指针，不使用 Buffer Registry；所有权仍按下列边界转移。

一次 `_send_message`：

1. 校验 Lua 参数、ID 范围和 message type。
2. 在 pool registry lock 内查找目标并获取 send pin。
3. 在 state/mailbox 边界确认目标仍接受消息。
4. 在栈上组成 `message_t` 描述符；不分配消息外壳。
5. `mailbox_try_push`。
6. FULL/CLOSED 时释放 payload，返回稳定错误。
7. OK 时 mailbox 取得 payload 所有权；仅当 `notify == true` 时调用 `uv_async_send`。
8. 释放 send pin。

stop 的对应顺序是：先注销目标阻止新 pin，再关闭 mailbox，等待已有 pin 结束，最后关闭 async handle。因此持有有效 send pin 的线程不会向已释放/closing 的 async handle 发送。

当前 `send_pins` 受 `pool->lock` 保护。lookup 和递增计数在同一个临界区完成，不能拆成“先返回裸指针、以后再递增”两步。pin 取得后立即释放 pool lock；mailbox push 和 libuv notify 不占用 registry lock，避免不同目标的消息投递被整个串行化。unpin 将计数减到 0 时通过 `pins_changed` 唤醒停止线程。

send 与 retire 竞争只有三种可观察结果：

| 线性化顺序 | 结果 |
| --- | --- |
| retire 先于 pin | pin 失败，返回 `SERVICE_STOPPING/STOPPED` |
| pin 先于 retire，close 先于 push | mailbox 仍存活，push 返回 CLOSED |
| push/notify 先于 close | 消息已接受，stop 等待 unpin 后处理或 drain |

pin 是 runtime 的短期生存期引用，不属于 payload，不随消息进入 mailbox，也不阻止 stop 改变状态；它只阻止 pin 覆盖的 runtime 资源被关闭或释放。

若在上述保证下 `uv_async_send` 仍失败：

- 消息已经被 runtime 接受，发送 API 返回成功，不能声称“目标绝不会处理”。
- 记录 runtime fault 并请求目标进入 STOPPING。
- stop drain 销毁消息；当前不向 RPC 来源补发错误。
- metrics 增加 notify failure，不能增加普通 mailbox rejection。

## 接收和批处理

inbox async callback：

1. 保存 Lua stack top。
2. pop 并处理消息。
3. 将 message 字段交给 Lua dispatcher。
4. payload 转给 Lua；栈上的 descriptor 随 binding 返回自然销毁。
5. Lua dispatcher 必须 `unpack_remove` 或 `remove` payload。
6. 持续 pop 到一次 empty，以清除 `scheduled`。若以后增加批次上限，批次耗尽时必须主动再次 `uv_async_send`，不能等待 producer 重复唤醒。
7. 恢复 stack top。

不得先检查长度再 pop 来决定正确性；`try_pop` 本身是唯一事实来源。

## 所有权状态

| 阶段 | descriptor location | payload owner |
| --- | --- | --- |
| `pack` 成功 | 无 | 调用方 Lua VM |
| native compose 后 | sender C stack | binding |
| push 成功 | mailbox ring slot | mailbox/service |
| push 失败 | sender C stack | binding，随后释放 |
| pop 后 | receiver C stack | receive binding |
| 字段交给 Lua | receiver C stack | receiver Lua/runtime |
| `unpack_remove/remove` | 无 | 已释放 |

低层 `_send_message` 一旦成功验证并接管 ptr，就消费该 ptr；即使 mailbox full，binding 也负责释放。参数验证在接管之前失败时 payload owner 不变。

调用方不得在 native binding 接管 ptr 后再次使用或释放它。

## 路由规则

- name lookup miss 返回 nil，不映射到 0。
- ID 必须在 `0..31`，slot 存在且 handle 可 pin。
- from/to/session 从 Lua integer 转换前检查负数和 uint32 上限。
- service stopping/stopped/freed 不接受新消息。
- 同一 pool 内路由；跨 pool 必须明确拒绝。
- native ABI 是可信 runtime 接口，但仍验证 from 是否属于 pool。

## 顺序保证

- 单个发送线程对同一目标按成功 push 顺序 FIFO。
- 同一个 Lua service 的发送发生在单线程，因此天然满足 producer order。
- 多 producer 的全局顺序由获取 mailbox lock 的顺序决定，不保证可重复。
- RESPONSE/ERROR 可以与后续 REQUEST 交错，session 而非位置决定匹配。
- send 不提供处理完成确认；需要结果时使用 call。

## Backpressure

mailbox 满时立即返回 `MAILBOX_FULL`，第一版不阻塞 producer，也不覆盖旧消息。

- `send` 返回 `nil, MAILBOX_FULL`。
- `call` 在登记 pending 和 yield 前返回 `nil, "mailbox full"`；失败 payload 由 native send 路径释放。
- runtime 记录 mailbox high watermark 和 rejection count。
- 业务可选择重试、丢弃、限速或切换到 RPC；runtime 不暗中重试以免破坏顺序和放大负载。

## Close 和 drain

`mailbox_close` 与 push 在同一 spinlock 下线性化。close 返回后所有后续 push 都得到 CLOSED。

drain 在不持有 mailbox lock 的情况下处理弹出的私有 message：

- REQUEST 且 session > 0：记录/drop；这表示目标违反了必须在停止前完成已接受 call 的可信 RPC 契约。
- REQUEST 且 session == 0：记录/drop。
- RESPONSE/ERROR：释放 payload；当前不恢复 pending RPC。
- SYSTEM/SIGNAL：按 control contract 处理或释放。

## 资源计数

至少维护：

- queued/accepted/received/dropped message descriptor。
- created/destroyed/live payload buffer。
- sent/accepted/rejected/received/dropped message。
- mailbox current length/high watermark/full count。
- async notify failure。

测试结束时 live message 和 runtime-owned buffer 必须为 0。

## 并发测试

- 1/2/4/16 producer，各自发送单调序号。
- 消费者验证不丢失、不重复、不损坏和 producer 内顺序。
- 容量 1、边界容量、非 2 次幂容量。
- push/full/pop 竞争。
- close 与 push 竞争。
- unregister、send pin、close async 和 free 竞争。
- TSAN 下无 data race。
- 故障注入 `uv_async_send` 失败时所有权归零。

当前 `tests/c/service_lifecycle_test.c` 已覆盖旧 pin 阻塞 free、8 producer 与 retire/close/join 的竞争，以及 STARTING stop；`make test-tsan` 同时运行 mailbox 和 service 生命周期用例。notify 故障注入和复杂 luv handle 仍待补充。
