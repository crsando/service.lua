# service.lua 设计方案

> 文档定位：最初的合并设计稿，保留用于追溯。公开 API/ABI 以
> [README.md](README.md) 为准，内部实现约束以 [doc/](doc/) 下的模块文档为准。
>
> 文档状态：Draft
>
> 目标项目：`~/src/service.lua`
>
> 兼容基线：`lservice3`
>
> 运行环境：Linux、LuaJIT 2.1 / Lua 5.1 C API、pthread、libuv

## 1. 文档目的

`service.lua` 是一个进程内、多线程、Actor 风格的 Lua 服务运行时。每个 service 拥有独立的 pthread、LuaJIT VM、libuv loop 和消息邮箱；service 之间只通过消息通信。Lua 层提供简单的 `spawn`、`send`、`call`、`dispatch`、`sleep` 等接口，C 层负责线程、邮箱、唤醒、生命周期和序列化。

本项目保留 `lservice3` 的调用接口和熟悉的编码方式，但不复制其已知缺陷。新实现必须系统解决以下问题：

1. 多个 service 同时写入同一邮箱时的数据竞争。
2. 邮箱满时静默丢消息和泄漏消息内存。
3. 请求处理失败后调用方永久挂起。
4. 不存在、越界或已退出的 service 导致错误路由、断言或空指针崩溃。
5. 消息、Lua 栈、service、libuv handle 和动态库句柄泄漏。
6. service 退出、注销、join 和资源释放之间缺少明确顺序。
7. 序列化非祖先共享 table 引用无法解码；单个共享对象即可触发，较大对象图同样失败。
8. 示例 TCP 服务缺少帧大小限制、鉴权边界和可靠错误处理。
9. 缺少自动化测试、并发测试、内存检查和可重复构建。

本文是实现约束，不只是方向说明。除明确标为“可选扩展”的内容外，实现必须遵守这里定义的接口、状态机、所有权和验收标准。

## 2. 设计目标

### 2.1 必须实现

- 保持 `require "lservice3"` 及现有 Lua API 的调用形式。
- 保持 `lservice3_c` 原生模块名称和 `_` 前缀底层 API。
- 保持 service source 的两种形式：`@path/to/file.lua` 和 Lua 源码字符串。
- 保持 service source 接收 `(service_addr, config_ptr)` 并返回消息 handler 的约定。
- 保持 `dispatch(function)` 和 `dispatch(table)` 两种处理器形式。
- 保持 `send` 的单向语义以及 `call` 的请求/响应语义。
- 每个 service 使用独立 LuaJIT VM、pthread 和 libuv loop。
- 正确支持多个发送线程向同一 service 并发发送消息。
- 明确每一块内存和每一个 handle 的所有权。
- 所有可预期的外部输入错误必须转成错误返回或 Lua error，不得依赖 `assert` 终止进程。
- service 停止后必须不可再寻址，等待中的 RPC 必须得到错误或超时。
- 建立单元测试、集成测试、并发压力测试和 sanitizer 流程。

### 2.2 非目标

- 第一版不支持跨进程 Actor、分布式注册中心或网络透明 RPC。
- 第一版不提供抢占式 Lua 协程调度。
- 第一版不承诺任意平台或 Windows 支持。
- 第一版不把序列化数据作为长期存储格式。
- 第一版不复用已经释放的 service ID，以避免旧 ID 指向新 service。
- 第一版不追求无锁邮箱；在服务数量有限的前提下，正确性和可观测性优先。

## 3. 兼容性定义

兼容性分为三层：

1. **源码兼容**：原项目中正确使用公开 API 的 Lua 代码无需修改。
2. **行为兼容**：消息顺序、`send`/`call`、handler 参数和返回值保持一致。
3. **二进制格式兼容**：不要求与旧 `lua-seri` 字节流互通；指针只在当前进程、当前运行期有效。

旧项目中明显属于 bug 的行为不作为兼容目标，例如：未知名称被路由到 root、`recv_message(false)` 被强制改为阻塞、无效 ID 触发 C 断言、错误请求永久等待、ID 32 创建后不可读取。

## 4. 保留的编码习惯

### 4.1 项目风格概括

新项目保留原项目以下特点：

- Lua 作为公共接口和业务编排层，C 只承载运行时关键路径。
- API 以简单函数为主，不引入复杂 class 框架。
- 公共模块使用 `service.*`，底层绑定使用 `service._*`。
- service 文件以 `local service = require "lservice3" .input(...)` 开头。
- handler table 使用简短的 `local S = {}`，命令名直接映射为 `S.command`。
- 常量使用大写下划线命名，例如 `MESSAGE_REQUEST`。
- Lua 局部变量和函数使用 `snake_case`；service API 使用点调用。
- C 类型使用 `_t` 后缀，函数按模块使用 `service_`、`message_`、`mailbox_` 等前缀。
- 文件保持单一职责，头文件只暴露模块契约。
- 复杂边界允许使用简短中文注释，标识符和公开 API 保持英文。
- 构建入口仍提供简单的 `Makefile`，支持 `make`、`make test`、`make install` 和 `make clean`。

### 4.2 新项目统一规则

原项目存在缩进混用、全局变量泄漏和注释掉的大段旧实现。新项目在保留整体风格的同时统一为：

- Lua 使用 4 空格缩进，不使用 tab。
- C 使用 4 空格缩进，指针星号跟随变量名，例如 `service_t *service`。
- Lua 文件默认所有变量为 `local`；只有模块导出表可被外部访问。
- C 函数必须检查可能失败的分配、pthread、libuv 和 Lua C API 前置条件。
- `assert` 只用于无法由外部输入触发的内部不变量。
- 不保留已废弃实现的大段注释；设计原因写在文档或短注释中。
- 日志不得打印密码、认证码、完整消息体或裸凭据。
- 不在仓库提交 `.so`、账号配置、密码或真实交易连接信息。
- 核心模块不得依赖仅用于调试的 `inspect`。

## 5. 项目目录

```text
service.lua/
├── DESIGN.md
├── README.md
├── Makefile
├── service.lua.rockspec            # 可选发布入口
├── lua/
│   ├── lservice3.lua               # 兼容公共 API
│   └── service.lua                 # 可选别名，返回同一模块
├── src/
│   ├── lservice.c                  # Lua C API 绑定
│   ├── service.c
│   ├── service.h
│   ├── pool.c
│   ├── pool.h
│   ├── mailbox.c
│   ├── mailbox.h
│   ├── message.c
│   ├── message.h
│   ├── serializer.c
│   ├── serializer.h
│   ├── luv_loader.c
│   ├── luv_loader.h
│   ├── log.c
│   └── log.h
├── service/
│   ├── root.lua
│   ├── echo.lua
│   ├── user.lua
│   ├── remote.lua
│   └── gateway.lua
├── examples/
│   └── demo.lua
└── tests/
    ├── lua/
    │   ├── api_spec.lua
    │   ├── rpc_spec.lua
    │   ├── lifecycle_spec.lua
    │   └── serializer_spec.lua
    ├── c/
    │   ├── mailbox_test.c
    │   └── pool_test.c
    ├── fixtures/
    │   ├── echo.lua
    │   ├── failing.lua
    │   └── slow.lua
    └── integration/
        └── demo_spec.lua
```

`lua/lservice3.lua` 是唯一必须兼容的公共入口。`lua/service.lua` 如果提供，只能是薄别名，不得形成第二套状态。

## 6. 总体架构

```text
standalone Lua VM
    │
    │ service.bootstrap / service.new
    ▼
service_pool_t
    ├── id/name registry
    ├── buffer registry
    └── service_t[]
          ├── pthread
          ├── LuaJIT VM
          ├── libuv loop
          ├── uv_async inbox signal
          ├── bounded MPSC mailbox
          └── lifecycle state

sender Lua coroutine
    │ pack + MESSAGE_REQUEST
    ▼
target mailbox ──uv_async_send──> target loop
                                    │
                                    ▼
                              Lua dispatch handler
                                    │
                              MESSAGE_RESPONSE/ERROR
                                    │
                                    ▼
                           resume original coroutine
```

### 6.1 模块职责

| 模块 | 职责 |
| --- | --- |
| `lservice3.lua` | 参数归一化、session、协程调度、dispatch、timer、错误重抛 |
| `lservice.c` | 严格校验 Lua 参数，将 Lua API 映射到 C 运行时 |
| `pool` | service ID/name 注册、查找、注销、池级生命周期 |
| `service` | 线程、Lua VM、libuv loop、状态机、启动/停止/join |
| `mailbox` | 有界 MPSC FIFO、容量管理、关闭语义 |
| `message` | 消息结构、创建、销毁和 payload 所有权 |
| `serializer` | Lua 值编码/解码、共享引用、循环引用、边界校验 |
| `luv_loader` | 进程级加载 luv，一次解析符号，为每个 VM 绑定专属 loop |
| `log` | 线程安全日志，自动附带 service 上下文 |

## 7. 核心数据结构

### 7.1 消息

消息字段及数值保持兼容：

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

typedef struct message {
    service_id_t from;
    service_id_t to;
    session_id_t session;
    int type;
    void *payload;
    size_t payload_size;
} message_t;
```

`session == 0` 表示单向消息，不期待响应。请求、响应和错误使用相同 session 配对。

旧 receipt 常量保留在 Lua 内部以免破坏引用，但第一版不实现 receipt 协议：

```text
MESSAGE_RECEIPT_NONE      = 0
MESSAGE_RECEIPT_DONE      = 1
MESSAGE_RECEIPT_ERROR     = 2
MESSAGE_RECEIPT_BLOCK     = 3
MESSAGE_RECEIPT_RESPONCE  = 4   # 保留旧拼写
MESSAGE_RECEIPT_RESPONSE  = 4   # 正确拼写别名
```

### 7.2 Service pool

```c
typedef struct service_pool {
    pthread_mutex_t lock;
    pthread_cond_t pins_changed;
    service_t *services[MAX_SERVICES];
    service_id_t next_id;
} service_pool_t;
```

规则：

- 默认 `MAX_SERVICES = 32`，合法 ID 是 `0..31`。
- 第一个创建的 service 是 root，ID 为 0。
- `next_id` 单调递增，第一版不复用 ID。
- name 必须为空或在 pool 内唯一，最大 31 字节并保证 NUL 结尾。
- 所有 services/name/state 的跨线程读取都通过 pool lock 或原子状态完成。
- 查找失败返回明确的 `SERVICE_NOT_FOUND`，绝不映射为 0。
- 达到容量时 `service.new` 返回 Lua error，不返回空 lightuserdata。

### 7.3 Service

```c
typedef enum service_state {
    SERVICE_NEW,
    SERVICE_STARTING,
    SERVICE_RUNNING,
    SERVICE_STOPPING,
    SERVICE_STOPPED,
    SERVICE_JOINED,
    SERVICE_FREED,
} service_state_t;

typedef struct service {
    service_pool_t *pool;
    service_id_t id;
    char name[MAX_SERVICE_NAME_LEN];
    bool routable;
    unsigned send_pins;

    pthread_t thread;
    pthread_mutex_t state_lock;
    pthread_cond_t state_changed;
    service_state_t state;
    bool start_done;
    int start_error;

    lua_State *L;
    int handler_ref;
    char *source;
    void *config;

    uv_loop_t loop;
    uv_async_t inbox_async;
    uv_async_t control_async;
    mailbox_t *inbox;

    bool stop_requested;
} service_t;
```

`service_t` 在第一版兼任 stable tombstone，直到 pool 销毁才释放结构和同步原语；JOINED 后释放 mailbox/source/config 等重资源。`uv_loop_t` 和 `uv_async_t` 直接嵌入，减少独立分配和遗漏释放。只有 service 自己的线程可以操作其 loop 上的普通 handle；其他线程必须持有 send pin，且只能调用线程安全的 `uv_async_send` 和 mailbox API。

### 7.4 Mailbox

第一版采用短临界区 spinlock 保护的有界环形 FIFO，而不是 intrusive lock-free 队列：

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

接口：

```c
mailbox_t *mailbox_new(size_t capacity);
mailbox_result_t mailbox_try_push(
    mailbox_t *box, const message_t *message, bool *notify);
bool mailbox_try_pop(mailbox_t *box, message_t *out);
void mailbox_close(mailbox_t *box);
void mailbox_delete(mailbox_t *box);
```

`mailbox_try_push` 返回 `MAILBOX_OK`、`MAILBOX_FULL` 或 `MAILBOX_CLOSED`。成功时按值复制 message 描述符并接管 payload；失败时调用方仍持有 payload。`notify` 只在成功且 `scheduled` 从 false 变为 true 时置为 true。

`mailbox_try_pop` 成功时把描述符复制到 consumer 栈并转移 payload；只有一次明确的 empty pop 才清除 `scheduled`。这个状态与 push 在同一把锁下排序，等价于 Skynet `in_global` 的防丢调度原则，但唤醒目标是 service 自己的 `uv_async`，不使用 global ready queue。

spinlock 使用 acquire exchange、relaxed wait/pause 和 release store。锁内禁止 malloc/free、Lua、日志和 libuv 调用，保持持锁时间有界。

默认容量为 1024，可通过创建参数 `mailbox_size` 配置，但设置上下限，例如 `16..65536`。容量必须按元素数量解释，不依赖 2 的幂。

## 8. 生命周期设计

### 8.1 状态转换

```text
NEW -> STARTING -> RUNNING -> STOPPING -> STOPPED -> JOINED -> FREED
          │                         ▲
          └──── initialization fail ┘
```

只允许以下操作：

| 当前状态 | 操作 | 结果 |
| --- | --- | --- |
| `NEW` | start | 创建线程，进入 `STARTING` |
| `STARTING` | send | 可入队，初始化完成后处理 |
| `RUNNING` | send/call | 正常处理 |
| `RUNNING` | stop/quit | 幂等进入 `STOPPING` |
| `STOPPING` | send/call | 立即返回 service stopping 错误 |
| `STOPPED` | join | 回收 pthread，进入 `JOINED` |
| `JOINED` | free | 释放资源，进入 `FREED` |

### 8.2 创建

`service_new` 的步骤必须可回滚：

1. 验证 pool、source、name、容量和配置大小。
2. 分配并清零 `service_t`。
3. 复制 source；config buffer 所有权转给 service。
4. 初始化 state mutex/condition 和 mailbox。
5. 最后在 pool 中注册 ID/name。
6. 任一步失败都按逆序释放，pool 中不得残留半初始化对象。

libuv loop 和两个 async handle 由 `service_start` 创建的目标 pthread 初始化，不在 `service_new` 的调用线程初始化。

### 8.3 启动

`service_start`：

1. 在 state lock 下完成 `NEW -> STARTING`。
2. 创建 pthread。
3. service 线程初始化 loop/async，创建 Lua VM、加载 luv/source，借用 config 解包并取得 handler；source 初始化返回后 native 释放 config buffer。
4. 初始化成功后发布 `RUNNING` 并唤醒等待 start 的线程。
5. 初始化失败时记录可读错误，关闭 mailbox，发布 `STOPPED`。

公开 `service.start` 等待初始化握手完成后返回：成功为 `0`；失败抛出包含 source 和根因的 Lua error。这样不会把“pthread 创建成功”误报为“service 启动成功”。在 `STARTING` 期间入队的消息必须在成功后正常处理，失败时统一销毁或回复错误。

### 8.4 停止

`service.quit()` 可能在 handler 内调用，禁止在当前 libuv callback 内嵌套执行 `uv_run` 或立即关闭 loop。

正确流程：

1. `service.quit` 只设置幂等的 `stop_requested`。
2. 当前 dispatch 批次结束后，由 control path 进入 `STOPPING`。
3. pool 立刻注销 name 和 ID，使新发送失败。
4. 关闭 mailbox，等待已经获取的 send pin 完成；当前阶段直接释放残留 payload，RPC error 在阶段 3 实现。
5. `uv_walk` 对未关闭 handle 调用 `uv_close`。
6. 继续运行 loop，直到所有 close callback 完成且 `uv_loop_alive` 为 false。
7. 关闭 Lua VM、关闭 loop并发布 `STOPPED`。
8. 不在 dispatch 尾部再次执行关闭逻辑，重复 quit 只观察同一个 stop request。

### 8.5 Join 和释放

- 禁止线程 join 自己；这种调用返回明确错误。
- `join` 对同一 service 只执行一次 pthread_join，重复调用返回既有结果。
- service 的公开 lightuserdata 地址在 join 后只可用于查询最终状态，不可发送。
- native join 在确认 pin 归零后释放 mailbox/source 等重资源；同步原语和 `service_t` tombstone 由 pool 最终释放。
- `bootstrap` 必须定义关闭策略：root 退出时请求所有子 service 停止，逐个 join，再释放 pool。
- 如果某子 service 在配置的 grace period 内不退出，记录错误并使 bootstrap 返回失败；第一版不使用 `pthread_cancel` 强杀 Lua VM。

## 9. Lua 公共接口

模块名继续为：

```lua
local service = require "lservice3"
```

### 9.1 模块状态字段

为兼容旧代码保留：

| 字段 | 含义 |
| --- | --- |
| `service.self` | 当前 service 的 opaque lightuserdata；standalone 为 nil |
| `service.uv` | 当前 VM 已绑定专属 loop 的 luv 模块 |
| `service.pool` | 当前 pool 的 opaque lightuserdata |
| `service.config` | 当前 service 解包后的配置；无配置时为空 table |
| `service.yield_session` | `coroutine.yield` 的兼容别名 |

这些字段由 `input` 初始化。service 文件不得直接修改 `self` 和 `pool`。

### 9.2 `service.input`

```lua
service.input(service_addr, config_ptr) -> service
```

- service source 的标准入口。
- 有 `service_addr` 时绑定 `self`、pool 和 config。
- 无 config 时 `service.config = {}`，不得为 nil。
- standalone 调用 `service.input()` 时清空 service 上下文，但可按需创建 pool。
- config 解包成功后立即释放 config buffer，并把 C 侧指针清空，防止悬空所有权。

### 9.3 创建与控制

```lua
service.new {
    source = "@service/echo.lua", -- 必需；也可传 Lua 源码字符串
    name = "echo",                -- 可选
    config = {},                  -- 可选
    pool = service.pool,          -- 可选
    mailbox_size = 1024,          -- 可选扩展
} -> addr

service.start(addr_or_id) -> 0
service.join(addr_or_id) -> 0
service.spawn(options) -> service_id
service.quit() -> nil
```

兼容规则：

- table config 通过 `service.pack` 传给新 VM。
- 非 table config 只允许 nil 或由本模块生成的受管 buffer 指针。
- `spawn` 等价于 `new + start + get_id`。
- standalone 模式下 `get_id(addr)` 必须返回 addr 的真实 ID，不能无条件返回 0。
- `quit` 幂等，只请求当前 service 停止。

### 9.4 查询

```lua
service.get_id([addr]) -> integer
service.get_addr([id]) -> addr|nil, error?
service.lookup(name) -> id|nil
service.get_pool([addr]) -> pool|nil
service.get_async([addr]) -> lightuserdata|nil
service.get_uv_loop([addr]) -> lightuserdata|nil
```

- `get_id()` 在 service 内返回当前 ID；standalone 无参数时返回 0 仅用于 root 兼容场景。
- `lookup` 找不到返回 nil，不再返回 0。
- `get_addr` 不产生调试输出。
- 查询函数校验 ID、slot 和状态；addr/lightuserdata 来源当前信任上游兼容层。完整 provenance 校验是未来开放非可信 native 边界时的可选增强。
- `get_async` 和 `get_uv_loop` 只用于兼容和诊断，业务代码不应直接操作返回的 C 指针。

### 9.5 消息发送

```lua
service.send(id_or_name, ...) -> true | nil, error
service.loopback(...) -> true | nil, error
service.send_message(to, session, type, msg, sz) -> true | nil, error
service.recv_message(blocking) -> from, to, session, type, msg, sz | nil
```

- `send` 使用 `MESSAGE_REQUEST`、session 0。
- 目标可为整数 ID 或注册名称。
- 名称不存在、目标停止、邮箱满或序列化失败时返回 `nil, error`。
- `_send_message` 成功后接管 payload；失败时绑定层销毁 message 和 payload。
- `recv_message(false)` 必须真正非阻塞。
- `recv_message(true)` 只供内部兼容；service 线程依靠 libuv 唤醒，不在 Lua callback 内阻塞 pthread。

### 9.6 同步 RPC

```lua
service.call(id_or_name, ...) -> ...
```

执行步骤：

1. 验证当前处于 service coroutine 中，standalone 或普通 libuv callback 中调用时报错。
2. 验证目标并分配非零 session。
3. 先把当前 coroutine 记录到 session table，再发送请求，避免极快响应产生竞态。
4. 发送失败时删除 session 记录并立即抛错。
5. yield 当前 coroutine。
6. `MESSAGE_RESPONSE` 解包并返回全部值。
7. `MESSAGE_ERROR` 解包并通过 `error(message, level)` 重抛。

session ID 是每个 service 独立的 `uint32_t` 计数器。跳过 0；发生回绕时扫描当前等待表，不能复用尚未完成的 ID。

默认 RPC 超时为 30 秒，可通过 `service.config.rpc_timeout_ms` 配置；设为 0 表示显式禁用。超时后删除 session、恢复 coroutine 并抛出 `rpc timeout`。迟到响应必须释放 payload 并记录 debug 日志，不得恢复已经结束的 coroutine。

为了保持接口不变，第一版不要求增加公开 `call_timeout`；超时由配置控制。后续可作为可选扩展增加。

### 9.7 Dispatch

函数形式：

```lua
return service.dispatch(function(command, ...)
    -- ...
end)
```

table 形式：

```lua
local S = {}

function S.echo(...)
    return ...
end

return service.dispatch(S)
```

规则：

- 每个 request 在独立 Lua coroutine 中执行。
- handler 返回值通过 `MESSAGE_RESPONSE` 回给 `session > 0` 的调用方。
- 未知命令、handler Lua error、序列化响应失败都生成 `MESSAGE_ERROR`。
- 错误 payload 至少包含稳定字符串：`code: message\ntraceback`。
- session 0 的单向请求发生错误时只记录日志，不发送响应。
- `resume_session` 必须检查 coroutine 状态；恢复失败时清理其所有 session 元数据，并向上游回复错误。
- 每次 async callback 最多处理 `dispatch_batch_size` 条消息，默认 256。剩余消息通过再次触发 async 继续处理，避免饿死 timer 和 socket callback。
- C 回调使用 `lua_pcall(..., 0, 0, ...)` 或在成功后恢复原栈顶，确保每次回调 Lua 栈深不变。

### 9.8 Timer

```lua
service.sleep(ms) -> nil
service.set_timeout(ms, callback) -> luv_timer
service.get_session() -> coroutine|nil
service.resume_session(co, ...) -> result
```

- `sleep` 只能在 service coroutine 中调用。
- timer callback 恢复 coroutine 前检查 service 尚未停止、coroutine 尚在等待。
- timer 始终执行 `stop + close`，即使 callback 抛错也不泄漏 handle。
- 停止 service 时，所有未完成 sleep 以 `service stopped` 错误恢复或被统一取消。

### 9.9 Bootstrap

```lua
service.bootstrap {
    source = "@service/root.lua",
    config = {},
    start = "boot",
} -> true | nil, error
```

流程：

1. 创建 pool 和 root。
2. 启动 root，确认进入 RUNNING。
3. 向 root 发送 `start` 指定的命令，默认 `boot`。
4. 等待 root 退出。
5. 请求其余 service 有序退出并 join。
6. 清空 pool、验证没有未释放 buffer/message/handle。
7. 成功返回 true，任一 service 初始化或关闭失败返回 `nil, error`。

## 10. 原生 C 接口

`luaopen_lservice3_c` 继续导出以下函数：

| 函数 | 参数 | 返回 |
| --- | --- | --- |
| `_pool_new` | 无 | pool lightuserdata |
| `_lookup` | pool, name | id 或 nil |
| `_get_pool` | service addr | pool |
| `_get_async` | service addr | async handle pointer |
| `_get_addr` | service addr, id | service addr 或 nil |
| `_get_uv_loop` | service addr | loop pointer |
| `_new` | pool, name, source, config, options? | service addr |
| `_start` | service addr | 0 或 Lua error |
| `_stop` | service addr | 0；幂等 |
| `_join` | service addr | 0 或 Lua error |
| `_get_id` | service addr | integer |
| `_send_message` | pool, from, to, session, type, ptr, sz | true 或 nil,error |
| `_recv_message` | service addr, blocking | 六个消息字段或无返回值 |
| `remove` | ptr, sz | 无 |
| `pack` | 任意 Lua 参数 | ptr, sz |
| `unpack` | ptr, sz? | 解包值，不释放 ptr |
| `unpack_remove` | ptr, sz? | 解包值并释放 ptr |

兼容层可以增加返回值，因为旧代码忽略返回值仍可工作；不得减少现有参数或改变成功结果类型。

当前 native ABI 只接受可信兼容层生成的 lightuserdata，必做校验包括：

- 指针非 NULL。
- ID、slot、状态和容量范围有效。
- 消息所有权转换符合 send/unpack/remove 契约。

完整的 runtime registry、magic/generation、pool provenance 和任意 buffer 指针验证保留为最终可选增强；只有未来允许不可信 Lua/native 调用时才成为发布要求。常规参数验证失败仍使用 `luaL_error` 或明确的 `nil,error`。

## 11. 消息所有权

所有权规则必须直接体现在 API 注释和测试中：

| 阶段 | `message_t` 所有者 | payload 所有者 |
| --- | --- | --- |
| `pack` 返回后 | 无 | 发送方 Lua/C binding |
| compose 成功后 | 发送 binding | message |
| mailbox push 成功后 | mailbox/目标 service | message |
| mailbox push 失败后 | 发送 binding | message，随后立即销毁 |
| pop 后 | 接收 binding | message |
| 六字段压入 Lua 栈后 | 接收 binding 释放外壳 | 接收 Lua 逻辑 |
| `unpack_remove` 后 | 已释放 | 已释放 |
| 丢弃迟到响应后 | runtime | runtime 调用 remove |

`message_destroy` 默认释放 payload。接收 binding 若把 payload 转交 Lua，必须先把 `message->payload = NULL`，再销毁 message 外壳，避免双重释放。

任何错误路径都必须遵守同一规则，包括：目标不存在、邮箱满、service stopping、序列化失败、响应发送失败和初始化失败。

## 12. RPC 错误协议

错误码使用稳定短字符串：

| code | 场景 |
| --- | --- |
| `SERVICE_NOT_FOUND` | ID/name 不存在 |
| `SERVICE_STOPPING` | 目标正在退出 |
| `MAILBOX_FULL` | 目标邮箱达到上限 |
| `UNKNOWN_COMMAND` | handler table 无对应命令 |
| `HANDLER_ERROR` | handler 抛出 Lua error |
| `SERIALIZE_ERROR` | 请求或响应无法序列化 |
| `RPC_TIMEOUT` | 超过配置时间 |
| `SERVICE_STOPPED` | 等待期间目标退出 |

线上兼容 payload 使用单个字符串参数：

```text
HANDLER_ERROR: service/user.lua:42: invalid account
stack traceback:
    ...
```

Lua 层内部可同时保留结构化字段用于日志，但 `service.call` 对业务代码表现为普通 Lua error。

## 13. 序列化设计

### 13.1 兼容值类型

必须支持：

- nil
- boolean
- Lua number
- string，包括二进制零字节
- table
- table 循环引用和共享引用
- lightuserdata，同进程地址语义
- 无 upvalue 的 C function，同进程地址语义

明确不支持：

- full userdata
- Lua function/closure
- coroutine/thread
- 带 upvalue 的 C closure

不支持的类型必须返回 Lua error，不能生成部分 buffer。

### 13.2 新格式

新格式使用固定头：

```text
magic       4 bytes  "LSR3"
version     1 byte
flags       1 byte
reserved    2 bytes
payload_len 4 bytes  little-endian uint32
payload     N bytes
```

设计规则：

- 所有整数长度使用明确字节序和固定宽度。
- 解码前验证 magic、version、payload_len 和实际注册长度。
- 默认最大 payload 16 MiB，可配置但必须有硬上限。
- 默认最大嵌套深度 128、最大 table 对象数 100000、最大元素数 1000000。
- table 第一次出现即分配递增 object ID；再次出现统一编码 REF，不再使用旧实现中混合的短数组和扩展引用分支。
- 解码引用必须确认 ID 已存在且类型为 table。
- `__pairs` 不默认参与序列化，避免执行用户代码造成副作用；如兼容确有需要，通过显式选项开启并单独测试。

### 13.3 Buffer registry（可选）

当前阶段信任 `lua-seri` 与上游传入的 `(ptr,size)`，不实现 Buffer Registry。若未来扩大 native 信任边界，可选方案是维护进程级受管 buffer registry：

- `pack` 成功后注册 `(ptr, size, owner_state)`。
- `_send_message` 成功后将 owner 从 sender 转为 message。
- `unpack` 只读，不改变 owner。
- `unpack_remove` 原子注销并释放。
- `remove` 对已释放指针返回 Lua error，测试中可发现 double free。
- service 退出时报告其尚未转移的 buffer，测试模式下视为失败。

lightuserdata 和 C function 的内容仍是裸地址，只允许同一进程、对象存活期间传递。不得写入磁盘、网络或跨重启使用。

### 13.4 异常安全

编码器使用临时 write buffer。任意 Lua error、OOM、深度超限或不支持类型发生时，保护调用必须释放全部 block 和引用表。解码器在成功前不转移输入 buffer 所有权；`unpack_remove` 即使解码失败也必须释放输入 buffer，然后重新抛错。

## 14. libuv 集成

- 每个 service 创建一个独立 `uv_loop_t`。
- luv 动态库通过 `pthread_once` 只加载和解析一次。
- 进程结束前不 `dlclose`，避免 Lua C closure 指向卸载代码。
- 每个新 Lua VM 调用 `luv_set_loop(L, &service->loop)` 后执行 `luaopen_luv`。
- 模块表写入该 VM 的 `package.loaded["luv"]`。
- 加载函数开始和结束时记录 Lua 栈顶，失败或成功都恢复预期栈深。
- `uv_async_send` 的返回值必须检查；失败时消息不能假装已投递。
- `uv_loop_close` 返回 `UV_EBUSY` 时列出残留 handle，并使测试失败。

## 15. 调度和公平性

每次 inbox async callback：

1. 保存 Lua 栈顶。
2. 最多 pop 256 条消息。
3. 对每条消息调用 Lua dispatch。
4. descriptor 位于 ring/consumer 栈，不产生逐消息外壳分配。
5. consumer 必须最终 pop 到 empty 以清除 `scheduled`；批次耗尽时主动再次 `uv_async_send`。
6. 恢复 Lua 栈顶并返回 libuv。

同一发送者向同一目标发送的消息必须保持 FIFO。不同发送者之间只保证 mailbox 获取锁后的全局入队顺序，不承诺确定性排序。

长时间运行的 handler 仍会阻塞该 service 的 loop，这是协作式模型的固有限制。文档应要求业务 handler 主动通过 `service.call`、`service.sleep` 或其他异步 API yield，不能执行无限 CPU 循环。

## 16. 示例服务设计

### 16.1 Root

- 负责创建和记录子 service ID。
- `boot` 完成示例调用后不隐式遗留线程；显式进入服务期或触发有序 shutdown。
- `quit` 依次向子 service 发送 quit，等待完成后停止自己。

### 16.2 Echo

- 使用函数形式 dispatch。
- 原样返回所有参数。
- 用于基本 RPC、并发和序列化集成测试。

### 16.3 User

- `ping` 使用 `service.sleep` 演示 timer 和协程恢复。
- 示例中不使用 `if id then` 判断整数 ID，因为 Lua 中 0 也是真值；应显式验证 ID 类型和范围。
- `quit` 只请求当前 service 停止。

### 16.4 Remote 文本端口

- 默认只绑定 `127.0.0.1`，外部绑定必须由配置显式开启。
- 一行一个命令，兼容 `\n` 和 `\r\n`。
- 单行最大 64 KiB，buffer 超限立即关闭连接。
- 命令映射到本 service 的白名单 handler，不允许任意 service 路由。
- accept、read、close 每一步处理 libuv 错误且保证 client 只关闭一次。

### 16.5 Gateway JSON 端口

- 默认只绑定 `127.0.0.1:8432`。
- 一行一个 JSON 对象，最大帧 1 MiB。
- JSON decode 失败返回结构化错误，不访问失败结果。
- 内部命令名统一为 `request_handler`，定义和派发必须一致。
- `send_json` 在引用前声明为 local。
- actor 和 method 必须经过 allowlist；不能把网络输入直接作为任意内部 service ID。
- 对外开放时必须提供鉴权 hook、连接数限制、读超时和每连接速率限制。
- client registry 使用稳定连接 ID 或 client handle 作为 key，不使用临时 peer table 身份。

示例协议：

```json
{"type":"request","actor":"echo","method":"echo","args":["hello"]}
```

响应：

```json
{"type":"response","ok":true,"result":["hello"]}
```

错误：

```json
{"type":"response","ok":false,"error":{"code":"UNKNOWN_COMMAND","message":"method is not allowed"}}
```

## 17. 配置和凭据

- 配置通过 `service.config` 传入，仓库只提交无秘密的示例配置。
- 密码、认证码和交易账号从环境变量、进程外配置文件或 secret manager 注入。
- `.gitignore` 至少覆盖 `.env`、`secrets.lua`、`accounts.local.lua` 和构建产物。
- 示例账号必须明显使用无效占位值。
- 文档提醒：已进入 Git 历史的真实凭据必须轮换，删除文件不能撤销泄漏。
- source 的 `@path` 由可信启动代码提供，不接受远程客户端指定。可选配置允许限制 source root，解析后拒绝逃逸该目录的路径。

## 18. 日志和可观测性

每条运行时日志自动包含：

```text
timestamp level service_id service_name thread_id component message
```

最低日志事件：

- service 创建、启动成功、初始化失败、停止、join。
- mailbox full、send to stopped service。
- RPC timeout、unknown command、handler traceback。
- libuv close 后残留 handle。
- pool 销毁时未释放 message/buffer/service。

计数器至少包含：

- 每个 service 的 mailbox 当前长度和高水位。
- sent/received/dropped/rejected 消息数。
- pending RPC 数量、成功数、错误数、超时数。
- handler 执行时间直方图。

第一版可只通过 debug API 或日志暴露指标，不要求接入外部监控系统。

## 19. 错误处理原则

- 参数错误：Lua 层或 binding 立即报错，消息不入队。
- 资源耗尽：返回可识别错误，释放所有已分配资源。
- 业务错误：转为 `MESSAGE_ERROR`，调用方恢复并得到 traceback。
- 目标状态错误：发送前检查，失败不 yield。
- 未预期内部不变量破坏：记录 fatal 日志；测试构建允许 assert，发布构建仍应尽可能有序退出。
- 日志本身不得成为业务控制流。
- C 函数返回值使用 0 表示成功，非零使用明确枚举或 pthread/libuv 原始错误码，不使用无含义的固定 1。

## 20. 构建与依赖

### 20.1 必需依赖

- C11 编译器
- pthread
- LuaJIT 2.1
- libuv
- luv，且必须导出 `luaopen_luv` 和 `luv_set_loop`

gateway 示例额外依赖 `lua-cjson`。`inspect` 只允许作为开发依赖，不得被核心模块无条件 require。

### 20.2 Makefile 目标

```text
make             构建 lservice3_c.so
make test        运行 C、Lua 和集成测试
make test-tsan   运行 mailbox/service 并发测试
make test-asan   运行内存和未定义行为检查
make lint        编译告警、Lua 语法和静态检查
make install     安装 C 模块和 lua/lservice3.lua
make clean       只删除明确的构建目录
```

构建要求：

- 使用独立 `build/`，不在源码根生成并提交 `.so`。
- 默认 `-std=c11 -Wall -Wextra -Wpedantic`。
- CI 构建增加 `-Werror`。
- 通过 `pkg-config` 查找 LuaJIT 和 libuv，允许用户覆盖 include/lib 参数。
- 显式链接 pthread、uv 和平台需要的 dl。
- `clean` 不使用宽泛的递归删除。

## 21. 测试方案

### 21.1 Serializer 单元测试

- nil、boolean、正负数、浮点、空字符串、二进制字符串。
- 空表、数组、哈希、混合表。
- 自引用、间接环、共享子表。
- 1、31、32、33、1000 个共享引用对象。
- 最大深度、最大 payload、最大元素限制。
- lightuserdata 往返。
- 不支持类型返回错误且不泄漏。
- 截断头、错误 magic、错误长度、非法 tag、非法 ref ID。
- `unpack_remove` 成功和失败都正好释放一次。
- fuzz 随机输入不得越界读取、崩溃或无限循环。

### 21.2 Mailbox 测试

- 单生产者 FIFO。
- 2、4、16 个生产者并发向一个消费者发送唯一序号。
- 验证不丢失、不重复、不损坏，生产者内顺序保持。
- 容量边界和 mailbox full。
- close 与 push 并发。
- ThreadSanitizer 下无 data race。

### 21.3 Service 生命周期测试

- source 字符串和 `@file` 启动。
- Lua 语法错误、缺少 handler、luv 加载失败。
- start 前发送、运行中发送、停止中发送。
- 重复 start、stop、quit、join。
- 自己 join 自己返回错误。
- root 退出后所有子 service 被 join。
- service name 冲突、容量达到 32、请求 ID 31 和拒绝 ID 32。
- 停止后 lookup 返回 nil。
- 每个状态转换可观察且只发生一次。

### 21.4 RPC 测试

- send 单向调用。
- call 多返回值和 nil 返回值。
- 嵌套 call：A -> B -> C -> A 在业务允许时可调度，不阻塞线程。
- handler error 返回 traceback。
- unknown command 返回错误。
- 目标不存在、stopping、stopped。
- mailbox full 时 call 不进入等待。
- 超时、迟到响应、重复响应和未知 session。
- session 接近 `UINT32_MAX` 后安全回绕。

### 21.5 libuv 集成测试

- timer sleep 和多个并发 timer。
- service 停止时 timer/socket 全部关闭。
- inbox 高负载时 timer 不被无限饿死。
- TCP 拆包、粘包、空行、`\r\n`、超长行。
- gateway 非法 JSON、未授权 actor/method、连接异常关闭。

### 21.6 资源测试

- ASan/UBSan：无越界、UAF、double free。
- LSan/Valgrind：完成 100 万条消息后无按消息增长的泄漏。
- 每个 async callback 前后 Lua stack top 相同。
- bootstrap 完成后 pool 中 service、buffer、message、libuv handle 计数归零。

## 22. 性能策略

交易系统场景采用 Skynet 风格的短临界区 spinlock，并保留有界容量和显式背压。优化顺序：

1. 建立 mailbox、RPC 和 serializer 基准。
2. 观察 spin 次数、竞争 producer 数和 p99/p999 延迟。
3. 保持锁内只有 descriptor copy 和 ring 状态更新；payload 分配、释放和 notify 都在锁外。
4. message descriptor 已按值存储，不再逐消息分配外壳。
5. 只有基准证明 spinlock 是主要瓶颈时，才评估分片 mailbox 或经过验证的 bounded lock-free MPSC。

基准至少记录：

- 单发送者和多发送者的 messages/second。
- send 与 call 的 p50/p95/p99 延迟。
- 不同 payload 大小的序列化吞吐。
- mailbox 长度和 batch size 对 timer 延迟的影响。

任何队列替换都必须保持 `mailbox_try_push/pop/close` 契约，Lua 和 service 层不感知具体实现。

## 23. 安全边界

- 该运行时默认只信任进程内 Lua service source，不是恶意代码沙箱。
- `lightuserdata` 和 C function 传输允许接收方获得进程地址，只能用于可信 service。
- 网络 gateway 是信任边界，必须验证 JSON 类型、大小、actor、method 和参数数量。
- 外部错误响应不包含完整内部路径或敏感 traceback；详细 traceback 只写服务端日志。
- 文件 source 路径、动态库路径和 package path 来自可信启动配置。
- release 构建不得把 debug credentials、消息正文或认证头写日志。

## 24. 实现阶段

### 阶段 1：工程骨架

- 建立目录、Makefile、CI、公共头文件和测试入口。
- 固定 API contract 测试，使旧式 echo/root service 可加载。

### 阶段 2：Serializer

- 实现受管 buffer、固定头、table/ref 编解码和限制。
- 完成 malformed input、共享引用和 fuzz 测试。

### 阶段 3：Pool、mailbox 和 service

- 实现 MPSC mailbox、pool 注册和生命周期状态机。
- 在 TSAN/ASan 下完成并发和回滚测试。

### 阶段 4：Lua 调度层

- 实现 send/call/session/dispatch/error/timer。
- 完成异常传播、超时、迟到响应和栈平衡测试。

### 阶段 5：libuv 与示例

- 实现一次性 luv loader 和每 VM loop 注入。
- 重写 echo/user/root/remote/gateway 示例并完成端到端测试。

### 阶段 6：稳定性

- 长时间压力测试、故障注入、资源计数、文档和安装验证。
- 达到验收条件后才标记第一个稳定版本。

### 最终可选增强

- 只有未来允许不可信 Lua/native 调用时，再实现 service/pool/buffer lightuserdata provenance、magic/generation 和 stale handle 验证。

## 25. 兼容验收清单

- [ ] `require "lservice3"` 成功。
- [ ] `service.input(...)` 返回同一个 service 模块表。
- [ ] 旧式 `return service.dispatch(S)` service 可直接运行。
- [ ] `new/start/join/spawn/bootstrap` 调用形式不变。
- [ ] `send/loopback/call` 参数形式和成功返回值语义不变。
- [ ] `sleep/set_timeout/get_session/resume_session` 可用。
- [ ] 所有旧 `_` 前缀 native 函数仍存在。
- [ ] `pack/unpack/unpack_remove/remove` 接口保持 lightuserdata + size 形式。
- [ ] 消息类型数值保持 0 到 4。
- [ ] root ID 保持 0，默认 service 上限保持 32 个合法槽位。
- [ ] `@file.lua` 和源码字符串均可作为 source。
- [ ] LuaJIT 2.1 / Lua 5.1 环境可构建和运行。
- [ ] 旧 bug 行为没有被误当作兼容要求。

## 26. 发布验收条件

第一版发布前必须全部满足：

1. 核心 C 代码在 `-Wall -Wextra -Wpedantic -Werror` 下无告警。
2. 所有 Lua 文件通过语法检查，核心模块没有未声明全局变量。
3. serializer、mailbox、lifecycle、RPC 测试全部通过。
4. 16 个生产者并发压力测试在 TSAN 下无竞争、无丢失、无重复。
5. 100 万条消息压力测试后没有按消息增长的内存和 Lua 栈泄漏。
6. handler error、unknown command、dead service、mailbox full 和 timeout 都不会永久挂起 coroutine。
7. 所有 service 退出后 pool 注册、消息、buffer 和 libuv handle 计数归零。
8. gateway 对非法 JSON、超长帧和未授权方法有稳定响应。
9. 仓库不包含二进制构建产物、真实账号、密码和认证码。
10. README 给出依赖、构建、最小示例、错误语义和关闭方式。

## 27. 最终设计原则

`service.lua` 继续采用原项目最有价值的模型：一个 service 对应一个线程、一个 LuaJIT VM、一个 libuv loop 和一个 inbox；Lua API 保持小而直接，业务代码通过普通 table/function 编写 handler。

新实现的核心提升不是增加更多 API，而是把原有隐含契约变为可验证的不变量：

- 消息要么成功投递，要么明确失败，不能静默消失。
- 每个请求最终得到响应、错误或超时，不能永久悬挂。
- 每个对象在任意时刻只有一个明确所有者。
- service 的创建、运行、停止、注销和释放必须遵循单向状态机。
- 外部输入错误不能使整个进程崩溃。
- 并发正确性、资源归零和接口兼容必须由自动化测试证明。

只有这些条件成立后，性能优化和更多网络能力才有稳定基础。
