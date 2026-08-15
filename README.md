# service.lua

`service.lua` 是一个面向 LuaJIT 2.1 / Lua 5.1 的进程内、多线程、Actor 风格服务运行时。

项目当前处于重新实现阶段。仓库中的 C/Lua 代码来自 `lservice3` 兼容基线，用于固定调用形式、复现旧问题和验证迁移结果，不代表本文描述的运行时已经完成。已知问题见 [PROBLEM.md](PROBLEM.md)，内部设计见 [doc/](doc/)。

## 项目初心

本项目希望让 Lua 业务代码用很少的概念获得清晰的并发隔离：

- 一个 service 拥有一个 pthread、一个独立 LuaJIT VM、一个独立 libuv loop 和一个有界邮箱。
- 不同 service 不共享 Lua 对象，只通过消息交互。
- 业务接口保持简单，以 `spawn`、`send`、`call`、`dispatch`、`sleep` 为主。
- Lua 负责编排和业务逻辑；C 只负责线程、邮箱、唤醒、路由、生命周期和序列化等运行时关键路径。
- 优先保证正确性、错误可见性和资源所有权，再讨论无锁结构或极限吞吐。

“兼容”指保留正确使用 `lservice3` 公开接口的 Lua 源码和行为习惯，不包括旧实现中的静默丢消息、错误路由、进程断言、永久挂起或泄漏。

## 核心模型

### Service

service 是隔离和调度单元。每个 service：

- 只在自己的 pthread 上执行 Lua 和操作普通 libuv handle。
- 拥有独立 Lua VM，不能直接读取另一个 service 的 Lua table、userdata 或 coroutine。
- 通过邮箱接收序列化消息。
- 使用 Lua coroutine 承载请求，以便在 `call` 和 `sleep` 时协作式让出执行权。

这是可重入的协作式 Actor 模型，不是严格的 run-to-completion Actor。handler 在 `call`、`sleep` 或其他异步边界 yield 后，service 可以处理其他消息；handler 恢复时，共享的 service 局部状态可能已经改变。

### Pool 和地址

一个 pool 管理一组 service 的 ID、name、状态和生存期：

- 默认最多 32 个 service，合法 ID 为 `0..31`。
- 第一个创建的 service 是 root，ID 为 0。
- ID 单调递增，第一版不复用。
- name 可为空；非空 name 在 pool 内唯一，最多 31 字节。
- Lua 可见的 addr 是 opaque lightuserdata，不允许业务代码解引用。
- 高频消息路由按 pool+ID 验证并取得存活 pin；`_start/_stop/_join` 等低频 native 控制接口当前只接受可信上游传入的 runtime handle。

当前第一版让 `service_t` 兼任稳定 handle：ID 不复用，join 后释放 Lua VM、loop、mailbox、source 等重资源，但 tombstone 保留到 pool 销毁。消息发送不直接使用查询得到的裸指针，而是在 pool lock 内取得短期 send pin；pin 覆盖 mailbox push 和必要的 `uv_async_send`，stop/free 必须等待 pin 归零。运行时生成的旧 addr 因此只会得到 stopped/freed 结果，不会因 allocator 地址复用指向新 service。项目现阶段信任上游 Lua/runtime 不伪造 native handle；完整 provenance 校验保留为最后的可选增强。

### 消息和投递

邮箱是短临界区 spinlock 保护的 bounded MPSC FIFO：

- 同一发送者向同一目标成功提交的消息保持 FIFO。
- `message_t` 描述符按值存入 ring，不为每条消息分配外壳；payload 仍按单 owner 转移。
- `scheduled` 合并重复唤醒，只有未调度 mailbox 接受第一条消息时才调用 `uv_async_send`。
- consumer 必须持续 pop 到一次明确的 empty，才能清除 `scheduled` 并允许下一次入队重新唤醒。
- 不同发送者只保证 mailbox 获得 spinlock 后的全局入队顺序。
- `send` 返回 `true` 表示消息已被运行时接受并转移所有权，不表示 handler 已经执行。
- `send` 返回 `nil, error` 表示消息未被目标接受，目标以后也不能处理该消息。
- mailbox full、目标不存在或目标停止都必须显式失败。
- 一次 RPC 最终必须得到 response、error 或 timeout，不能永久等待。

入队成功后的 `uv_async_send` 异常属于目标 runtime fault。它不能把已经接受的消息重新报告为“未投递”；运行时必须进入故障停止流程，销毁或错误回复邮箱中的消息。

### 生命周期

service 使用单向状态机：

```text
NEW -> STARTING -> RUNNING -> STOPPING -> STOPPED -> JOINED -> FREED
```

初始化失败记录 `start_error` 并从 `STARTING` 进入 `STOPPED`。`FREED` 表示运行资源已释放；公开 handle 的验证元数据可以继续作为 tombstone 存在。

停止是协作式过程：先禁止新路由并关闭邮箱，等待 send pin 归零，再由 control async 在目标线程关闭 libuv handle，最后 join pthread。当前阶段会销毁尚未处理的 payload；挂起 RPC/sleep 的错误恢复属于阶段 3。运行时不能强制抢占一个永不 yield 的 Lua handler，因此关闭超时只能报告失去响应，不能在其线程仍运行时释放 pool 或 service 内存。

详细流程见 [生命周期设计](doc/lifecycle.md)。

## 兼容性和稳定性分层

| 层级 | 稳定性承诺 |
| --- | --- |
| Lua 公共 API | 函数名、参数形式、成功结果和错误语义保持兼容 |
| `lservice3_c` Lua C ABI | 导出函数名、Lua 栈参数和返回值保持兼容 |
| 消息 ABI | message type 数值、32 位 service/session ID 保持稳定 |
| 序列化 ABI | 当前沿用 `lua-seri`，只稳定 Lua API，不承诺字节格式 |
| 内部 C ABI | `service_t`、`pool_t`、`mailbox_t` 布局不对外稳定 |
| 跨进程/持久化 | 不支持；指针、C function 和序列化 buffer 不能跨进程或重启使用 |

原生模块入口必须为：

```c
int luaopen_lservice3_c(lua_State *L);
```

运行基线为 Linux、LuaJIT 2.1 / Lua 5.1 C API、pthread、libuv 和 luv。

## 最小示例

```lua
-- service/echo.lua
local service = require "lservice3" .input(...)

return service.dispatch(function(command, ...)
    if command == "echo" then
        return ...
    end
    error("unknown command: " .. tostring(command))
end)
```

```lua
local service = require "lservice3"

assert(service.bootstrap {
    source = "@service/root.lua",
    config = {},
    start = "boot",
})
```

source 支持 `@path/to/file.lua` 和 Lua 源码字符串两种形式。service source 接收 `(service_addr, config_ptr)`，执行后必须返回由 `service.dispatch` 生成的 handler function。

## Lua 公共 API

公共模块只有一个：

```lua
local service = require "lservice3"
```

除非接口明确返回 `nil, error`，参数错误、非法调用上下文和不能恢复的运行时错误均抛出 Lua error。

### 模块字段

| 字段 | 类型 | 规范 |
| --- | --- | --- |
| `service.self` | `lightuserdata\|nil` | 当前 service addr；standalone 为 nil |
| `service.pool` | `lightuserdata\|nil` | 当前 pool；由 `input/new/bootstrap` 管理 |
| `service.uv` | `table` | 已绑定当前 service 专属 loop 的 luv 模块 |
| `service.config` | `table` | 当前 service 配置；无配置时必须是空 table |
| `service.yield_session` | `function` | `coroutine.yield` 的兼容别名 |

业务代码不得修改 `self`、`pool`，不得直接操作 `get_async/get_uv_loop` 返回的 C 指针。

### `service.input`

```lua
service.input(service_addr?, config_ptr?) -> service
```

- service source 的标准入口。
- 有 addr 时绑定 `self/pool`，借用 config buffer 完成解包；source 初始化返回后由 native 统一释放该 buffer，初始化异常路径同样只释放一次。
- config 缺省时设置 `service.config = {}`。
- 无 addr 时进入 standalone 上下文并清空旧 service 状态。
- 返回同一个 `service` 模块 table。

### 创建和控制

```lua
service.new(options) -> addr
```

`options` 字段：

| 字段 | 必需 | 类型 | 说明 |
| --- | --- | --- | --- |
| `source` | 是 | string | `@file.lua` 或 Lua 源码 |
| `name` | 否 | string | pool 内唯一名称，最多 31 字节 |
| `config` | 否 | table/lightuserdata/nil | table 自动 pack；指针必须来自 `service.pack` |
| `pool` | 否 | lightuserdata | 缺省使用或创建 `service.pool` |
| `mailbox_size` | 否 | integer | `16..65536`，默认 1024 |

创建成功返回 opaque addr；验证、分配、注册或初始化资源失败时抛错，不返回 NULL lightuserdata。

```lua
service.start(addr_or_id) -> 0
```

创建 pthread 并等待初始化握手。只有 Lua VM、luv、source 和 handler 全部初始化成功才返回 0。重复 start 或初始化失败抛出 `SERVICE_START_FAILED`；当前详细 Lua/libuv 根因写入 runtime log，后续还需随错误对象返回调用方。

```lua
service.join(addr_or_id) -> 0
```

等待目标 pthread 退出并回收其 join 状态。`join` **只等待，不会请求目标停止**；目标必须先自行调用 `service.quit()`，或已经由其他控制路径收到 stop 请求，否则调用方会一直阻塞。

`service.join` 主要供程序入口/bootstrap 所在的宿主线程使用。不要在 service 的业务 handler、timer/socket callback 或其他 libuv callback 中用它等待另一个 service：这会阻塞当前 service 的 event loop，并可能与对方的消息或退出流程形成死锁。禁止 service join 自己；重复 join 返回已有结果，不能第二次调用 `pthread_join`。

当前阶段的标准用法是：程序入口只 bootstrap 一个 root service；root 完成业务关闭后调用 `service.quit()`；宿主线程 `service.join(root_addr)` 等待 root pthread 完整关闭 Lua/luv/libuv 资源并退出，随后进程结束。暂不把 pool 的独立复用和整体销毁作为当前实现目标。

```lua
service.spawn(options) -> service_id
```

等价于 `new + start + get_id`。任一步失败都回滚已取得的资源。

```lua
service.quit() -> nil
```

幂等请求当前 service 停止。它不在当前 Lua/libuv callback 内嵌套运行 loop 或立即释放 service。

### 查询

```lua
service.get_id(addr?) -> integer
```

- 有 addr 时返回该 addr 的真实 ID。
- service 内无参数时返回当前 ID。
- standalone 无参数返回 0 只用于 root 兼容场景。

```lua
service.get_addr(id_or_addr?) -> addr|nil, error?
```

- addr 参数原样验证后返回。
- integer 参数在当前 pool 查询稳定 handle；terminal handle 仍可供 join/诊断使用，但不能发送。
- 不存在或越界时返回 `nil, error`，不打印调试输出。

```lua
service.lookup(name) -> service_id|nil
```

名称存在时返回 ID；不存在时返回 nil。未知名称绝不能映射到 root ID 0。

```lua
service.get_pool(addr?) -> pool|nil
service.get_async(addr?) -> lightuserdata|nil
service.get_uv_loop(addr?) -> lightuserdata|nil
```

`get_pool` 返回 addr 所属 pool；无 addr 时返回当前上下文 pool。后两个接口只用于兼容和诊断。

### 消息发送和接收

```lua
service.send(id_or_name, ...) -> true | nil, error
```

将参数 pack 为 `MESSAGE_REQUEST`、session 0。成功表示目标 mailbox 已接受消息；失败时不会执行目标 handler。

```lua
service.loopback(...) -> true | nil, error
```

等价于 `service.send(service.get_id(), ...)`。

```lua
service.send_message(to, session, message_type, ptr, size) -> true | nil, error
```

兼容用低层入口，from 和 pool 取当前 service 上下文。ptr 必须来自 `service.pack`。一旦 native binding 成功验证并接管 ptr，无论最终入队成功还是失败，该 ptr 都会被转移或释放，调用方不得再次使用。

```lua
service.recv_message(blocking) -> from, to, session, message_type, ptr, size
                                | nil
```

- `blocking=false` 必须真正非阻塞。
- service loop 正常依赖 async 唤醒，不在 libuv callback 中阻塞 pthread。
- 返回的 ptr 由接收方拥有，必须正好调用一次 `unpack_remove` 或 `remove`。

### RPC

```lua
service.call(id_or_name, ...) -> ...
```

- 只能在运行时管理的 service coroutine 中调用。
- 目标和 session 在发送前完成验证和登记。
- response 返回全部值，包括中间或末尾 nil。
- error 以普通 Lua error 重抛。
- 默认超时 30 秒；`service.config.rpc_timeout_ms = 0` 可显式禁用。
- timeout 后迟到响应只释放 payload，不得再次恢复 coroutine。

session 是每 service 独立的非零 `uint32_t`。回绕时跳过 0 和仍在等待的 ID。

### Dispatch

```lua
service.dispatch(function_handler) -> native_handler
service.dispatch(handler_table) -> native_handler
```

函数形式接收 `(command, ...)`。table 形式使用 `handler_table[command](...)`。

- 每个 request 在独立 coroutine 中执行。
- `session > 0` 时，返回值编码为 `MESSAGE_RESPONSE`。
- unknown command、handler error 和 response serialize error 编码为 `MESSAGE_ERROR`。
- session 0 的 handler error 只记录日志。
- 每次 inbox callback 默认最多处理 256 条消息，之后重新唤醒以保证 timer/socket 公平性。

### Coroutine 和 timer

```lua
service.get_session() -> coroutine|nil
```

返回当前由 runtime 恢复的 coroutine；普通 luv callback 或 standalone 上下文返回 nil。

```lua
service.resume_session(co, ...) -> true, ... | false, error
```

兼容的受管 coroutine 恢复入口，结果形式与 `coroutine.resume` 一致。runtime 内部必须在失败时清理 session 元数据并向上游 RPC 回复错误。

```lua
service.sleep(milliseconds) -> nil
```

只能在 service coroutine 中调用。停止时尚未完成的 sleep 被取消并以 `SERVICE_STOPPED` 恢复或在 teardown 中统一释放。

```lua
service.set_timeout(milliseconds, callback) -> luv_timer
```

创建一次性 timer。callback 前停止 timer，callback 后关闭 handle；callback 抛错也不能泄漏 handle。

### Bootstrap

```lua
service.bootstrap {
    source = "@service/root.lua",
    config = {},
    start = "boot",
} -> true | nil, error
```

创建 pool/root，等待 root 启动，发送入口命令，等待 root 退出，然后请求所有子 service 停止并 join。只有 pool 中的 service、message、buffer 和 libuv handle 全部完成回收才返回 true。

### Serializer

```lua
service.pack(...) -> ptr, size
service.unpack(ptr, size?) -> ...
service.unpack_remove(ptr, size?) -> ...
service.remove(ptr, size) -> nil
```

- `pack` 返回由 `lua-seri` 分配的可信进程内 buffer。
- `unpack` 只读，不改变所有权。
- `unpack_remove` 无论解码成功或失败都正好释放一次 buffer。
- `remove` 释放但不解码；当前阶段由调用方保证 ptr、size 和释放次数正确。
- 支持 nil、boolean、number、binary string、table、循环/共享 table、lightuserdata 和无 upvalue 的 C function。
- 不支持 full userdata、Lua closure、thread/coroutine 和带 upvalue 的 C closure。

## `lservice3_c` 原生 ABI

原生模块仅面向可信的 `lua/lservice3.lua` 兼容层和诊断代码。ID、容量和状态仍需正常校验；service/pool lightuserdata 的来源当前信任上游运行时，不把 native ABI 暴露给网络或不可信 Lua。若未来扩大信任边界，再启用完整 registry/provenance 校验。

| 函数 | Lua 栈签名 | 成功结果 |
| --- | --- | --- |
| `_pool_new` | `()` | `pool` |
| `_lookup` | `(pool, name)` | `id` 或 nil |
| `_get_pool` | `(addr)` | `pool` |
| `_get_async` | `(addr)` | async pointer 或 nil |
| `_get_addr` | `(addr, id)` | addr 或 nil,error |
| `_get_uv_loop` | `(addr)` | loop pointer 或 nil |
| `_new` | `(pool, name, source, config_ptr, options?)` | addr |
| `_start` | `(addr)` | 0 |
| `_stop` | `(addr)` | 0，幂等 |
| `_join` | `(addr)` | 0 |
| `_get_id` | `(addr)` | uint32 ID |
| `_send_message` | `(pool, from, to, session, type, ptr, size)` | true 或 nil,error |
| `_recv_message` | `(addr, blocking)` | 六个字段或无返回值 |
| `pack` | `(...)` | ptr,size |
| `unpack` | `(ptr, size?)` | 解包后的全部值 |
| `unpack_remove` | `(ptr, size?)` | 解包后的全部值并释放 ptr |
| `remove` | `(ptr, size)` | 无返回值 |

错误返回使用稳定短码：

| code | 含义 |
| --- | --- |
| `SERVICE_NOT_FOUND` | ID/name/addr 不存在 |
| `SERVICE_START_FAILED` | service 初始化失败 |
| `SERVICE_STOPPING` | 目标正在停止 |
| `SERVICE_STOPPED` | 目标已停止或等待期间停止 |
| `MAILBOX_FULL` | mailbox 达到容量 |
| `UNKNOWN_COMMAND` | handler table 无命令 |
| `HANDLER_ERROR` | handler 抛出 Lua error |
| `SERIALIZE_ERROR` | 请求或响应不能序列化 |
| `RPC_TIMEOUT` | RPC 超时 |

## 消息 ABI

service 和 session ID 都是精确的 32 位无符号整数：

```c
typedef uint32_t service_id_t;
typedef uint32_t session_id_t;

typedef enum message_type {
    MESSAGE_SYSTEM   = 0,
    MESSAGE_REQUEST  = 1,
    MESSAGE_RESPONSE = 2,
    MESSAGE_ERROR    = 3,
    MESSAGE_SIGNAL   = 4,
} message_type_t;
```

内部 message 的语义字段固定为：

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

字段语义和数值稳定，但 `message_t` 的 padding、字段名及完整内存布局不是对外插件 ABI。外部代码必须通过 `lservice3_c` 调用，不得跨动态库直接分配内部 message。

receipt 常量只为旧代码保留，第一版不实现 receipt 协议：

```text
MESSAGE_RECEIPT_NONE      = 0
MESSAGE_RECEIPT_DONE      = 1
MESSAGE_RECEIPT_ERROR     = 2
MESSAGE_RECEIPT_BLOCK     = 3
MESSAGE_RECEIPT_RESPONCE  = 4
MESSAGE_RECEIPT_RESPONSE  = 4
```

## 序列化 ABI

当前阶段信任现有 `lua-seri` 和内部 payload 指针约定，不引入 Buffer Registry，也不重写序列化格式。稳定边界是 `pack/unpack/unpack_remove/remove` 的 Lua 调用形式；字节格式只允许在同一进程和同一运行期使用，不作为持久化或外部 ABI。

`LSR3` 和受管 buffer 方案保留在 [序列化设计](doc/serialization.md) 中作为可选的后续安全增强，不属于当前开发路径。

## 项目结构

```text
service.lua/
├── README.md                公开契约和开发任务
├── DESIGN.md                初始合并设计稿，供追溯
├── PROBLEM.md               兼容基线已知问题
├── doc/                     模块化内部设计
├── lua/lservice3.lua        Lua 公共兼容层
├── src/                     C runtime 与 binding
├── service/                 示例 service
├── examples/                启动示例
└── tests/                   contract、回归和集成测试
```

## 构建和测试

当前基线：

```sh
make
make test
make test-contract
make test-regression       # 旧 serializer 当前预期失败
```

目标构建入口还包括 `test-tsan`、`test-asan`、`lint` 和可重复安装；完成前在下方任务列表保持未勾选。

## 开发任务列表

任务只有在根因修复、自动化测试通过、错误路径所有权验证且文档同步后才能勾选。

### 阶段 0：基线和契约

- [x] 复制无敏感配置的兼容基线。
- [x] 建立 `DESIGN.md` 和 `PROBLEM.md`。
- [x] 明确 Actor 可重入语义、投递结果和兼容边界。
- [x] 明确 stable handle/pin 原则和协作式停止边界。
- [x] 建立 Lua API、native ABI 和 message ABI 表面测试。
- [ ] 初始化新项目 Git 历史并记录旧项目来源 commit。
- [ ] 增加顶层 LICENSE/NOTICE，核对所有复制代码的许可证和署名。
- [ ] 将默认构建迁移到 `build/` 并通过严格编译。

### 阶段 1：Mailbox

- [x] 用 bounded spinlock MPSC mailbox 替换 SPSC queue。
- [x] message 描述符按值入队，移除逐消息外壳分配。
- [x] 用 `scheduled` 合并 `uv_async` 唤醒且不丢失空转非空事件。
- [x] 实现 `OK/FULL/CLOSED` 和失败消息释放。
- [x] 增加 1/2/4/16 producer 测试。
- [x] mailbox 测试通过 ThreadSanitizer。
- [x] 在完整生命周期中验证 close/send/free 并发。

### 阶段 2：Pool、handle 和生命周期

- [x] 对运行时生成的 addr 实现不产生 UAF/ABA 的 stable tombstone。
- [x] 实现 registry lookup pin 与 stop/free 同步。
- [x] 实现 active name 唯一性、ID `0..31` 和不复用策略。
- [x] 实现单向状态机和 start 初始化握手。
- [x] 实现 STARTING stop、初始化失败的基本回滚和 config 单 owner。
- [ ] 为每个 allocation/pthread/libuv 初始化失败点增加故障注入。
- [ ] 将结构化 start/loop-close 根因返回调用方，而不只写日志。
- [x] 实现 control async 和非重入的有序 stop。
- [ ] 用 timer/socket/luv userdata 覆盖 handle close 和 loop close 异常路径。
- [ ] 使用 `pthread_once` 加载 luv 并为每个 VM 绑定独立 loop。
- [x] 实现 join/self-join/repeated join 契约。
- [ ] bootstrap 后 service/message/buffer/handle 计数归零。

### 阶段 3：Lua 调度、RPC 和 timer

- [ ] 重写 send/call/dispatch/session 调度层。
- [ ] 实现 `MESSAGE_ERROR`、unknown command 和 traceback。
- [ ] 实现 RPC timeout、取消、迟到/重复响应处理。
- [ ] 实现 uint32 session 安全回绕。
- [ ] 实现 dispatch batch 和 timer/socket 公平性。
- [ ] 停止时取消 sleep、出站 RPC 和挂起入站 handler。
- [x] inbox C -> Lua callback 使用零返回值并恢复进入时 stack top。

### 阶段 4：可选安全增强

- [x] 评估 Buffer Registry；当前阶段信任内部消息契约，不引入。
- [ ] 评估是否需要版本化序列化格式。
- [ ] 按实际输入边界决定 malformed input 和 fuzz 范围。

### 阶段 5：示例、网络和发布

- [ ] 重写 root/echo/user 示例并完成端到端测试。
- [ ] 按需恢复 remote/gateway，默认只绑定 localhost。
- [ ] 增加帧限制、路由 allowlist、鉴权 hook 和速率限制。
- [ ] 增加 `test-asan`、`test-tsan`、`lint` 和 CI。
- [ ] 100 万消息测试无按消息增长的内存或 Lua 栈泄漏。
- [ ] 完成安装、错误语义、关闭方式和发布说明。

### 阶段 6：可选的非可信 native 边界

- [ ] 若未来允许不可信 Lua/native 调用，再验证任意 lightuserdata、pool 归属、terminal addr 和 stale handle；当前可信上游场景不以此阻塞发布。

## 设计文档索引

- [总体架构](doc/architecture.md)
- [Service 生命周期](doc/lifecycle.md)
- [消息、邮箱与所有权](doc/messaging.md)
- [RPC、Coroutine 与调度](doc/rpc-scheduling.md)
- [Serializer 与 buffer registry](doc/serialization.md)
- [原生运行时与 libuv](doc/native-runtime.md)
- [测试和验收策略](doc/testing.md)
- [Skynet 消息系统研究](doc/skynet-analysis.md)

`README.md` 是公开 API/ABI 和任务状态的规范入口；`doc/` 描述内部实现约束；`DESIGN.md` 保留为最初的合并设计稿。三者冲突时，新代码以 README 的公开契约和对应模块文档为准。
