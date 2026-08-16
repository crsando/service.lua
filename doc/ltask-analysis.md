# cloudwu/ltask 调度与消息模型研究

## 1. 结论

当前项目的消息常量、session table 和 coroutine 调度代码直接继承自 ltask，但运行模型已经不同。
ltask 最值得参考的不是某个函数，而是它对三类状态的分离：

1. `MESSAGE_*` 描述进入 service 后应该执行什么逻辑。
2. session 把一个完成消息关联到等待中的 coroutine。
3. `MESSAGE_RECEIPT_*` 描述 scheduler 是否成功把出站消息转移到目标 inbox。

当前项目应该保留前两层的思想，但不应复制第三层。当前 native send 已经同步返回
accepted/full/not-found/stopping，额外实现 ltask receipt 只会制造第二套发送状态机。

针对当前 REQUEST/RESPONSE/ERROR 的可信 completion 模型，建议明确以下硬规则：

```text
MESSAGE_REQUEST                         -> 新的入站业务请求
MESSAGE_RESPONSE 且 session > 0         -> 已有 pending RPC 的成功完成
其他 type/session 组合                 -> 当前不支持，释放 payload
```

不能继续使用“不是已注册 request type，就是 response”的反向判定。ltask 能这样工作，是因为它
封闭控制所有消息生产者和类型；当前项目的 dispatcher 应使用显式的正向判定。

## 2. 研究基线

- 上游仓库：[cloudwu/ltask](https://github.com/cloudwu/ltask)
- 研究提交：[`ff776f1dfdb256310a022bdbcd8eac688dad5da8`](https://github.com/cloudwu/ltask/commit/ff776f1dfdb256310a022bdbcd8eac688dad5da8)
- 提交时间：2026-08-04 12:52:24 +08:00
- 重点源码：[`lualib/service.lua`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/lualib/service.lua)、
  [`src/ltask.c`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/src/ltask.c)、
  [`src/service.c`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/src/service.c)、
  [`src/queue.c`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/src/queue.c)

ltask 自己说明它是受 Skynet 启发的 Lua task library：N 个 OS worker 调度 M 个独立 Lua VM。
它不是“一 service 一线程”，也不是当前项目的“一 service 一 pthread + libuv loop”。

## 3. N:M 调度模型

ltask 的每个 service 拥有独立 Lua VM、inbox 和状态，但没有固定线程。未绑定的 service
可以在不同轮次由不同 worker 执行；同一时刻仍然最多只有一个 worker 运行该 service。

```text
service coroutine
      |
      | yield
      v
worker reports DONE
      |
      v
single scheduler owner
  - 搬运 out message
  - 写发送 receipt
  - 更新 service 状态
  - 把 runnable service 分配给 worker
      |
      v
worker resumes service
```

worker 把 service 从 `SCHEDULE` 改为 `RUNNING`，执行到 Lua 主 coroutine yield 或结束，再改为
`DONE/DEAD`。scheduler 通过全局 `schedule_owner` 保证同一时刻只有一个线程执行调度阶段，
见 [`thread_worker`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/src/ltask.c#L680)
和 [`schedule_dispatch`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/src/ltask.c#L477)。

当前项目不需要这套 worker 分配和 job stealing。pthread 与 libuv loop 已经确定 service 的执行位置，
把 service 迁移到别的 worker 会破坏 loop/handle 的线程归属。

## 4. 为什么 ltask 的 SPSC Queue 成立

ltask 的 Lua service 不能直接 push 另一个 service 的 inbox。每个 service 只有一个 `out` 指针：

```c
struct service {
    struct queue *msg;
    struct message *out;
    struct message *bounce;
    int receipt;
};
```

发送过程是：

```text
sender worker
  -> 把消息写入 sender.out
  -> yield service
  -> scheduler 取走 sender.out
  -> scheduler push destination.msg
  -> scheduler 写 sender.receipt
  -> sender 再次被调度并读取 receipt
```

`service_send_message` 只允许 `out` 中存在一条消息；Lua `post_message` 在写入后通过
`continue_session()` 主动 yield，见
[`service_send_message`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/src/service.c#L476)
和 [`post_message`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/lualib/service.lua#L236)。

因此目标 inbox 的唯一 producer 是 scheduler，目标 service 是唯一 consumer。ltask 的 queue
源码也明确写着 `Allow only one reader and one writer`，push 时只断言 tail 没有被其他 writer
改变，见 [`queue_push_close`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/src/queue.c#L58)。

当前项目允许多个 service pthread 直接向同一目标 mailbox 发送，因此 inbox 是 MPSC。
ltask 的 SPSC queue 在当前架构中不成立；当前 spinlock MPSC mailbox 是必要差异，不应回退。

## 5. Message 与 Receipt 是两套协议

### 5.1 Message type

ltask 定义六种入站消息，见
[`message.h`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/src/message.h#L7)：

| type | session | ltask 中的实际用途 |
| --- | ---: | --- |
| `MESSAGE_SYSTEM` | 通常 `> 0` | 调用 `sys_service` 管理方法，bootstrap 的 init 也是 SYSTEM |
| `MESSAGE_REQUEST` | `0` 或 `> 0` | 普通 `send` 或 `call` 请求 |
| `MESSAGE_RESPONSE` | `> 0` | RPC 成功结果，也用于 sleep/timeout 唤醒 |
| `MESSAGE_ERROR` | `> 0` | RPC 或 coroutine 失败结果 |
| `MESSAGE_SIGNAL` | `0` | service 死亡后通知 root |
| `MESSAGE_IDLE` | `0` | scheduler 驱动内部 idle/socket event |

REQUEST 的 session 语义和 Skynet 一致：

- `MESSAGE_REQUEST + session == 0` 是无需回复的 `send`。
- `MESSAGE_REQUEST + session > 0` 是需要回复的 `call`。
- 成功回复必须改成 `MESSAGE_RESPONSE` 并复用原 session。

SYSTEM 并不是“任意 runtime control packet”。它是另一套方法表 `sys_service`，由 `syscall`
发起，也使用正常的 RESPONSE/ERROR 完成路径，见
[`syscall`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/lualib/service.lua#L457)
和 [`SESSION[MESSAGE_SYSTEM]`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/lualib/service.lua#L886)。

### 5.2 Receipt type

Receipt 不会进入目标 service dispatcher。它是 scheduler 写回发送 service 的单槽结果：

| receipt | 含义 | bounce payload |
| --- | --- | --- |
| `RECEIPT_DONE` | 消息已进入目标 inbox | 无 |
| `RECEIPT_ERROR` | 目标不存在或已死亡 | 原消息退回发送方 |
| `RECEIPT_BLOCK` | 目标 bounded inbox 已满 | 原消息退回发送方 |
| `RECEIPT_RESPONSE` | scheduler 控制命令返回数据 | 只用于创建 service |

scheduler 在 [`dispatch_out_message`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/src/ltask.c#L186)
中 push 目标 inbox，然后调用 `service_write_receipt`。原消息在 ERROR/BLOCK 时通过 `bounce`
回到发送方，因此 payload 所有权没有模糊区间。

当前项目的 `_send_message` 已经直接返回：

```text
true
nil, SERVICE_NOT_FOUND
nil, SERVICE_STOPPING
nil, SERVICE_STOPPED
nil, MAILBOX_FULL
```

这等价于把 ltask 的 receipt 合并进 native send 返回值。当前源码中的 `MESSAGE_RECEIPT_*`
只是复制遗留常量，没有对应 side channel、scheduler 或 bounce 状态机；应该标记为 legacy/reserved，
不能让它们参与 dispatcher。

### 5.3 `to == 0` 切换了 type 命名空间

ltask 规定 system service ID 为 0、root service ID 为 1。发给普通 service 时，type 使用
`MESSAGE_*`；发给 ID 0 时，消息绕过 Lua service dispatcher，由 scheduler 把同一个 type 字段
解释成 `MESSAGE_SCHEDULE_NEW` 或 `MESSAGE_SCHEDULE_DEL`。这两个值也是 0 和 1，与
`MESSAGE_SYSTEM`、`MESSAGE_REQUEST` 数值重叠，见
[`dispatch_schedule_message`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/src/ltask.c#L137)。

这不是通用消息类型设计，而是由目标地址选择另一套内部协议。当前项目的 root service 本身就是 ID 0，
所以不能同时继承“ID 0 是 root”和“to 0 是 scheduler”两种语义。[`message.h`](../src/message.h)
中的 schedule 注释和 `MESSAGE_SCHEDULE_*` 宏属于失去运行前提的 ltask 遗留，不应据此扩展 dispatcher。

### 5.4 `syscall` 是目标 VM 内的管理 RPC

ltask 的 `syscall` 不是操作系统调用，也不是发给 ID 0 scheduler 的控制命令。它和普通 `call`
共用 session、pending coroutine、RESPONSE 和 ERROR 路径，区别只在请求 type 和目标方法表：

| API | 请求 type | 目标方法表 | 用途 |
| --- | --- | --- | --- |
| `ltask.call` | `MESSAGE_REQUEST` | 业务 `service` | 普通业务 RPC |
| `ltask.syscall` | `MESSAGE_SYSTEM` | 框架 `sys_service` | init、quit、memory、traceback |

完整流程是：

```text
syscall(target, command, ...)
  -> MESSAGE_SYSTEM + 非零 session
  -> target 创建 managed coroutine
  -> sys_service[command](...)
  -> MESSAGE_RESPONSE / MESSAGE_ERROR
  -> 调用方按 session 恢复
```

独立方法表避免业务 command 与管理 command 冲突，也让没有注册业务 handler 的 service 仍然可以
被初始化、查询或请求退出。不过 `syscall` 只提供命名空间隔离，不提供权限隔离；ltask 中知道地址的
service 就可以调用目标的管理方法。

当前项目暂不实现 SYSTEM dispatcher 或 `service.syscall`。`MESSAGE_SYSTEM` 保留为未来候选，可能用于
在目标 Lua VM 内执行 `quit`、traceback、memory 等管理操作。若未来用它实现 quit，应当只在目标线程
发起协作式 stop request，复用现有 control async 关闭流程，不能在 SYSTEM handler 内直接关闭
libuv handle、loop 或 Lua VM。若 quit 使用非零 session 的 call 形式，还必须先定义并保证 response
确认与进入 STOPPING 的顺序。

## 6. Coroutine 与 Session

ltask Lua 层维护三组主要关系：

```text
session -> suspended outbound coroutine
inbound coroutine -> source address
inbound coroutine -> request session
```

收到 REQUEST/SYSTEM 等新会话后，ltask 创建 managed coroutine，并记录调用方地址和 session。
handler 正常结束时发送 RESPONSE；coroutine 抛错时发送带 traceback 的 ERROR。调用方收到完成消息后，
根据 session 找到等待 coroutine，删除映射，然后恢复它。

ltask 把全局 `coroutine` 设为 nil，并只通过自己的 coroutine pool 创建业务执行单元，见
[`service.lua`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/lualib/service.lua#L37)。
这与当前项目新增的 managed-coroutine 校验方向一致：框架的 `running_thread` 只在框架恢复入口内有效，
业务代码不应手工嵌套恢复另一个框架 coroutine。

ltask 的 session 是 `unsigned int`，Lua 侧只是持续 `session_id = session_id + 1`，没有处理回绕和
pending ID 冲突。当前项目已经实现非零 uint32 回绕并跳过 pending ID，这一点比研究版本的 ltask
更完整，不能退回上游写法。

## 7. ltask 如何判断 Request 与 Response

ltask 使用 `SESSION[type]` 注册“会创建新 coroutine 的消息”：

```lua
local f = SESSION[type]
if f then
    -- REQUEST / SYSTEM / SIGNAL / IDLE
    local co = new_session(f, from, session)
    wakeup_session(co, type, msg, sz)
else
    -- RESPONSE / ERROR，或任何未知 type
    local co = session_coroutine_suspend_lookup[session]
    ...
end
```

完整入口见 [`schedule_message`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/lualib/service.lua#L903)。

这是一种封闭世界设计：所有合法生产者都由 ltask 控制，所以“不是新会话类型”可以被视为完成消息。
但它也有明显缺点：未知 type 会落入 response 分支。当前项目只复制了 REQUEST handler，没有复制
SYSTEM/SIGNAL/IDLE 注册，于是原来的 `elseif session then` 把几乎所有非 REQUEST 消息都误当 response；
而 Lua 中数值 0 也是真值。

当前项目应改用正向判定：

```lua
if type == MESSAGE_REQUEST then
    dispatch_request(...)
elseif type == MESSAGE_RESPONSE and session > 0 then
    dispatch_response(...)
else
    discard_unsupported(...)
end
```

这里还要区分“识别为 response”和“接受 response”：

1. type/session 组合合法，才允许查询 pending table。
2. pending session 存在，才删除映射并恢复 coroutine。
3. pending 不存在时释放 payload；在可信模型中这是协议违约，不需要增加来源验证或恢复机制。

## 8. 为什么发送后登记 Session 在 ltask 中没有抢跑

ltask.call 的顺序也是先 post request，再登记 pending session：

```text
post_request_message
register session -> running_thread
yield waiting coroutine
```

表面上 response 可能在登记前返回，实际不会恢复调用方：发送 service 在 `post_message` 内先 yield
给 scheduler，scheduler 可以把 request 交给目标，甚至让 response 进入调用方 inbox；但同一个 service
不会并发执行第二个 dispatcher。调用方重新获得执行权后先登记 session，随后再次 yield，才会消费 inbox。

当前项目虽然没有中央 scheduler，但每个 Lua VM 也只在自己的 libuv loop 线程串行执行 callback。
在禁止业务手工嵌套 `resume_session` 的前提下，同样不存在 response 在 send 与登记之间抢先进入 Lua
dispatcher 的竞态。这个结论依赖“单 VM 不并发”，不是通用多线程 RPC 规则。

## 9. Backpressure 与 Response 必达

ltask 的 inbox 是 bounded queue。请求发送遇到 BLOCK 时通常立即报 `{service} is busy`；response
遇到 BLOCK 时不会丢弃，而是 fork 一个任务，把消息交给 root 的 `send_retry` 队列持续重试。timer service
也为每个阻塞目标维护 response session 队列，见
[`post_response_message`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/lualib/service.lua#L276)
和 [`service/timer.lua`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/service/timer.lua#L17)。

这说明 ltask 的“response 尽量必达”不是由 RESPONSE 类型本身保证的，而是由 receipt、bounce、root
retry 和 service 生命周期共同保证的。当前项目已经明确把 RESPONSE/ERROR 成功投递作为可信前置条件，
因此暂不复制这套重试系统。以后若取消该前置条件，不能只检查 `_send_message` 返回值；必须同时定义：

- response payload 在失败和重试期间由谁持有；
- 重试是否保持同一发送者 FIFO；
- 目标或调用方停止时何时终止重试；
- 重试队列是否有上限。

## 10. Error 与退出传播

ltask 会把 handler/coroutine error 编码成 `MESSAGE_ERROR`，携带跨 service traceback。service quit 时：

1. 对仍在执行的入站 session 调用 `raise_error`。
2. dead service 向 root 发送 `MESSAGE_SIGNAL`。
3. root drain 尚未处理的 REQUEST/SYSTEM，收集 source/session。
4. root 再向这些调用者发送 ERROR。

相关路径见 [`resume_session`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/lualib/service.lua#L299)、
[`ltask.quit`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/lualib/service.lua#L699)
和 [`del_service`](https://github.com/cloudwu/ltask/blob/ff776f1dfdb256310a022bdbcd8eac688dad5da8/service/root.lua#L233)。

当前项目已经采用其中最小的 handler error 链路：保留入站 coroutine 的 from/session，正常结束发送
RESPONSE，command/handler error 发送只包含字符串的 ERROR，调用方返回 `nil, error_msg`。项目仍信任
RESPONSE/ERROR 必达并允许无限等待，没有复制 ltask 的退出取消、queued request 错误回复和 retry。

## 11. 与 Skynet、当前项目的对比

| 维度 | Skynet | ltask | 当前项目 |
| --- | --- | --- | --- |
| 执行模型 | M service / N worker | M Lua VM / N worker | 每 service 独立 pthread/libuv loop |
| service 是否迁移线程 | 可以 | 可以，可显式 bind | 不可以 |
| inbox producer | 多 producer，锁保护 | 单 scheduler producer | 多 service pthread producer |
| 发送路径 | sender 直接 push mailbox | sender out -> scheduler -> inbox | sender 直接 push mailbox |
| mailbox 满载 | 动态扩容 | bounded，返回 BLOCK receipt | bounded，native send 直接失败 |
| request type | protocol ID，如 PTYPE_LUA | 固定 REQUEST/SYSTEM | 当前只有 REQUEST |
| 成功完成 | PTYPE_RESPONSE | MESSAGE_RESPONSE | MESSAGE_RESPONSE |
| 错误完成 | PTYPE_ERROR | MESSAGE_ERROR | MESSAGE_ERROR（command/handler error） |
| timer 唤醒 | PTYPE_RESPONSE message | MESSAGE_RESPONSE message | libuv callback 直接恢复 |
| service 控制 | core command/特殊协议 | SYSTEM + service 0 scheduler | native API + control async |

ltask 比 Skynet 更接近当前代码的直接来源，但 Skynet 的 protocol registry 更适合未来存在多种 payload
协议的系统。当前阶段没有必要引入 registry：REQUEST payload 的第一个值作为 command 已足够。

## 12. 对当前项目的具体建议

### 当前设计决定

1. dispatcher 只把 `MESSAGE_RESPONSE/MESSAGE_ERROR + session > 0` 识别为 completion。
2. `MESSAGE_REQUEST + session == 0` 固定为 send；`MESSAGE_REQUEST + session > 0` 固定为 call request。
3. 只有 pending table 中存在 session 才恢复 coroutine；否则释放 payload。
4. 未支持 type 显式释放 payload，不能通过兜底分支进入 pending session。
5. 保持 managed coroutine 限制和已经实现的 uint32 session 安全回绕。
6. command/handler error 使用原 session 返回单字符串 ERROR；调用方得到 `nil, error_msg`。

### 保留但不启用

- `MESSAGE_SYSTEM`：暂不实现；保留为未来 `service.syscall` 管理命名空间，候选命令包括 quit、traceback 和 memory。
- `MESSAGE_SIGNAL`：只有出现明确的异步 service 事件消费者时再定义。
- `MESSAGE_RECEIPT_*`：为兼容现有数值暂时保留为 legacy/reserved，不进入 dispatcher。

### 不采用

- ltask 的 N:M worker scheduler、service 迁移和 job stealing。
- service `out` 单槽及每次 send 强制 yield。
- SPSC inbox。
- `to == 0` 表示 scheduler 的约定。ltask 中 system service 是 0、root 是 1；当前项目 root 本身就是 0。
- “type 不在 request handler table 中，就当作 response”的反向分派。
- 在当前可信 completion 模型下引入 receipt、root retry 和 timeout/cancel 状态机。

### 未来触发条件

只有出现下列需求时，才重新打开相应设计：

- 多种 payload codec 或业务协议：参考 Skynet 的 protocol registry，而不是堆叠特殊分支。
- response 可能投递失败：整体设计 response ownership、bounded retry 和停止条件。
- service 可以带 pending RPC 停止：扩展现有 ERROR，补齐退出传播和 queued request 回收。
- 需要 mailbox 驱动的 runtime 命令：先定义 SYSTEM 的生产者、权限、payload、返回契约和 quit 响应/停止顺序。

这个取舍保留了 ltask 最有价值的 session/coroutine 思路，同时避免把其中央 scheduler 的内部协议
误当成当前项目的公共消息 ABI。
