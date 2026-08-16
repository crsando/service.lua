# 已知问题清单

> 项目：`service.lua`
>
> 基线：从 `lservice3` 复制的兼容实现
>
> 更新日期：2026-08-15
>
> 设计方案：参见 [DESIGN.md](DESIGN.md)

## 1. 文档用途

当前目录中的 C/Lua 代码是原项目的兼容基线，不是 `DESIGN.md` 所描述的新运行时实现。本文件集中记录审查和验证过程中发现的问题，防止复制代码后把旧行为误认为已经完成的新设计。

每个问题包含状态、严重程度、证据、影响和解决方向。修改代码时应同时增加或更新测试，并在问题真正修复后变更状态；不能只因增加了注释或规避了一个示例就标记完成。

## 2. 状态和严重程度

状态：

| 状态 | 含义 |
| --- | --- |
| `OPEN` | 问题仍存在于新项目复制的代码中 |
| `KNOWN-FAIL` | 已有自动化回归用例，当前仍失败 |
| `ACCEPTED` | 已知行为由当前明确的信任边界接受，不作为当前修复项 |
| `EXCLUDED` | 原项目存在，但相关敏感或废弃文件没有复制到新项目 |
| `LEGACY` | 只为追溯保留，不属于默认测试或正式接口 |
| `FIXED` | 已修复且有自动化测试证明 |

严重程度：

| 等级 | 含义 |
| --- | --- |
| `P0` | 凭据泄漏或可直接造成严重安全事故，需要立即处理 |
| `P1` | 可导致进程崩溃、数据竞争、消息丢失、永久挂起或持续泄漏 |
| `P2` | 功能错误、边界错误、资源回收不完整或明显不可靠 |
| `P3` | 文档、测试、可维护性和工程一致性问题 |

## 3. 总览

| ID | 严重程度 | 状态 | 摘要 |
| --- | --- | --- | --- |
| SEC-001 | P0 | EXCLUDED | 原仓库 Git 历史包含明文交易凭据 |
| CONC-001 | P1 | FIXED | 已使用 spinlock MPSC mailbox 替换 SPSC queue |
| MSG-001 | P1 | FIXED | mailbox full/closed 已返回错误并释放失败消息 |
| RPC-001 | P1 | FIXED | handler/unknown command 通过 `MESSAGE_ERROR` 返回 |
| RPC-002 | P1 | ACCEPTED | 当前允许 RPC 无限等待，不实现 timeout/cancel |
| ROUTE-001 | P1 | FIXED | 未知名称返回 nil，不再映射到 root |
| ROUTE-002 | P1 | FIXED | ID 在 native 边界校验并返回 `SERVICE_NOT_FOUND` |
| MEM-001 | P1 | FIXED | `message_t` 改为按值传递，不再分配逐消息外壳 |
| MEM-002 | P1 | FIXED | async callback 使用零返回值并恢复原 stack top |
| LIFE-001 | P1 | PARTIAL | 已 retire/pin/drain/free；pool GC 和资源计数待补 |
| LIFE-002 | P1 | FIXED | quit 只请求停止，由 control async 有序关闭 |
| SER-001 | P1 | KNOWN-FAIL | 普通共享 table 引用无法解码 |
| SER-002 | P1 | OPEN | 解码和 remove 信任任意裸指针及内部长度 |
| GATE-001 | P1 | OPEN | gateway 当前请求链路不可工作 |
| GATE-002 | P1 | OPEN | gateway 暴露任意 actor/method 且无鉴权边界 |
| LIMIT-001 | P2 | FIXED | ID 限定为 `0..31`，失败不消耗 next_id |
| API-001 | P2 | OPEN | 多个 Lua 公共 API 参数转发或默认值错误 |
| RPC-003 | P2 | FIXED | session 在 uint32 范围安全回绕并跳过 pending ID |
| PROTO-001 | P2 | FIXED | REQUEST/RESPONSE/ERROR 使用显式 type/session 分派 |
| LIFE-003 | P2 | PARTIAL | 基本初始化失败已回滚，完整故障注入矩阵待补 |
| NET-001 | P2 | OPEN | TCP 输入 buffer 无上限，默认绑定所有网卡 |
| REG-001 | P2 | OPEN | registry key 使用无边界 `strcpy` |
| LUV-001 | P2 | OPEN | 每个 service 重复 `dlopen` luv 且句柄未统一管理 |
| TEST-001 | P3 | LEGACY | 原测试引用不存在的 `lservice2` 并无限运行 |
| DOC-001 | P3 | OPEN | 复制代码仍含未使用依赖、死字段和注释实现 |

## 4. 安全问题

### SEC-001：原仓库 Git 历史包含明文交易凭据

- 严重程度：`P0`
- 状态：`EXCLUDED`
- 原始证据：原项目 `accounts.lua` 包含账号、密码、app ID 和认证码，并从首次提交起存在于 Git 历史。
- 新项目状态：`accounts.lua`、`.con` 文件和相关秘密没有复制；[.gitignore](.gitignore) 已忽略常见本地秘密文件。

影响：

- 如果凭据仍有效，任何可读取仓库历史的人都可能直接使用它们。
- 从当前工作树删除文件不能撤销 Git 历史中的泄漏。

必须采取的外部动作：

1. 将历史中的所有账号、密码、认证码按已泄漏处理并轮换。
2. 审查远端仓库、镜像、CI 日志和其他 clone。
3. 后续只通过环境变量、进程外配置或 secret manager 注入。

该问题不能仅靠新项目代码标记为 `FIXED`，凭据轮换完成前仍有外部风险。

### GATE-002：网络 gateway 缺少鉴权和路由白名单

- 严重程度：`P1`
- 状态：`FIXED`
- 证据：[service/gateway.lua:10](service/gateway.lua#L10)、[service/gateway.lua:46](service/gateway.lua#L46)

gateway 默认绑定 `0.0.0.0`，并把客户端提供的 `actor` 和 `method` 用于内部路由。虽然当前请求链路因其他 bug 尚不可用，但一旦只修正命令名，就会把任意内部 RPC 暴露给网络客户端。

影响：

- 未授权调用内部 service。
- 传入越界 actor ID 可走到 C 层断言或空指针路径。
- 可远程触发高开销 handler、停止命令或敏感操作。

解决方向：

- 默认绑定 `127.0.0.1`。
- actor/method 使用配置白名单，网络输入不能直接成为内部 service ID。
- 对外开放前增加鉴权、连接数限制、读超时和速率限制。
- 参见 `DESIGN.md` 第 16.5、17、23 节。

### SER-002：序列化接口信任任意裸指针

- 严重程度：`P1`
- 状态：`OPEN`
- 证据：[src/lua-seri.c:827](src/lua-seri.c#L827)、[src/lservice.c:169](src/lservice.c#L169)

`unpack` 从传入地址直接读取 4 字节长度，再按该长度读取内存；Lua 侧传入的 size 没有参与验证。`remove` 也直接 `free` 任意 lightuserdata。原生 binding 没有确认指针由本模块分配、是否仍存活或 size 是否一致。

影响：

- 可信 Lua 代码误用时可导致越界读、double free、invalid free 或进程崩溃。
- 如果未来让不可信 Lua 代码接触这些 API，会形成进程内存安全边界缺失。

解决方向：

- 建立受管 buffer registry，记录 pointer、size、状态和所有者。
- `unpack/remove/_send_message` 必须原子验证和转移所有权。
- 新序列化头包含 magic、version 和显式长度上限。
- 参见 `DESIGN.md` 第 10、11、13 节。

## 5. 并发和消息问题

### CONC-001：SPSC 队列被用作 MPSC 邮箱

- 严重程度：`P1`
- 状态：`FIXED`
- 修复：[src/mailbox.c](src/mailbox.c)、[src/service.c](src/service.c)
- 测试：[tests/c/mailbox_test.c](tests/c/mailbox_test.c)、`make test-tsan`

队列实现明确假定只有一个 writer。实际架构允许任意多个 service 线程向同一个目标 service 发送消息，因此多个线程可能同时读取相同 tail、写入相同槽位并更新 tail。

可能结果：

- C 数据竞争和未定义行为。
- 两条消息互相覆盖或其中一条消失。
- debug 构建触发 `assert(tail == expected)` 并终止进程。
- release 构建关闭 assert 后静默损坏队列。

当前实现使用 test-and-test-and-set spinlock 保护容量检查、slot 写入、head/tail/count 和 scheduled 状态。1、2、4、16 个 producer 测试及 ThreadSanitizer 已通过。

### MSG-001：队列满时消息静默丢失

- 严重程度：`P1`
- 状态：`FIXED`
- 修复：[src/mailbox.c](src/mailbox.c)、[src/lservice.c](src/lservice.c)
- 测试：[tests/c/mailbox_test.c](tests/c/mailbox_test.c)、[tests/lua/mailbox_spec.lua](tests/lua/mailbox_spec.lua)

`queue_push_ptr` 在满时返回 1，但 `service_send` 忽略返回值，仍调用 `uv_async_send` 并返回固定成功值。新分配的 `message_t` 和 payload 没有释放。

影响：

- 单向消息静默丢失。
- RPC 调用方已经 yield，但目标永远不会收到请求。
- 每次失败泄漏消息和 payload。
- 上层无法做重试、限流或错误响应。

mailbox 现在返回 `OK/FULL/CLOSED`。push 失败时 native binding 释放 payload 并向 Lua 返回错误；`call` 在登记 pending 和 yield 前返回 `nil, error_msg`。

### MEM-001：每条消息泄漏 `message_t`

- 严重程度：`P1`
- 状态：`FIXED`
- 修复：[src/mailbox.c](src/mailbox.c)、[src/lservice.c](src/lservice.c)、[src/message.c](src/message.c)
- 测试：[tests/c/mailbox_test.c](tests/c/mailbox_test.c)

旧实现为每条消息 malloc 一个 `message_t` 外壳，pop 后若只转交字段就会泄漏。当前 mailbox 把 descriptor 按值存入 ring，发送和接收 binding 使用栈上 descriptor，彻底移除了这类分配及对应泄漏路径。payload 仍按单 owner 契约独立释放。

mailbox 测试验证 descriptor 是副本、FULL/CLOSED 不接管 payload，且 delete 会 drain 已接受消息。payload 的整条 Lua 生命周期仍需后续 sanitizer 和资源计数覆盖。

### MEM-002：async 回调持续增长 Lua 栈

- 严重程度：`P1`
- 状态：`FIXED`
- 证据：[src/service.c:35](src/service.c#L35)

C 回调使用 `lua_pcall(L, 1, 1, 0)` 请求一个返回值。Lua dispatch handler 没有返回值时，Lua 会补一个 nil；成功分支没有弹出该结果。每次 `uv_async` callback 都会留下一个栈元素。

影响：高频或长时间运行时 Lua 栈和关联内存持续增长，最终可能触发内存错误。

callback 现在保存进入时的 stack top，使用 0 个 Lua 返回值，并在成功或异常后统一 `lua_settop` 恢复。后续百万消息压力测试仍会继续观察 Lua 内存，但不再存在逐 callback 留下 nil 的路径。

## 6. RPC 和错误传播问题

### RPC-001：handler error 不会形成 `MESSAGE_ERROR`

- 严重程度：`P1`
- 状态：`FIXED`
- 修复：[lua/lservice3.lua](lua/lservice3.lua)、[tests/lua/rpc_spec.lua](tests/lua/rpc_spec.lua)

request coroutine 捕获错误后重新抛给 `resume_session`。该层在清理入站 coroutine 的
from/session 映射前构造 `MESSAGE_ERROR`；table handler 找不到 command 时返回固定的
`command not found`。调用方 dispatcher 删除 pending 并恢复 coroutine，`service.call`
返回 `nil, error_msg`。session 0 的单向请求没有等待方，不发送 completion。

### RPC-002：没有默认超时和取消

- 严重程度：`P1`
- 状态：`ACCEPTED`
- 证据：[lua/lservice3.lua:299](lua/lservice3.lua#L299)、[lua/lservice3.lua:331](lua/lservice3.lua#L331)

当前 `service.call` 不创建 timer。未知命令和 handler 异常已由 ERROR 完成；目标在接受请求后停止、
消息或 completion 丢失仍会让 coroutine 永久等待。

当前决定：允许 `service.call` 无限期等待。目标保证 RESPONSE/ERROR 成功进入调用方 mailbox，
且在发送 completion 前不会停止；timeout、取消和迟到响应处理不是当前实现目标。

### RPC-003：session ID 安全回绕

- 严重程度：`P2`
- 状态：`FIXED`
- 证据：[lua/lservice3.lua:195](lua/lservice3.lua#L195)、[tests/lua/rpc_spec.lua](tests/lua/rpc_spec.lua)

旧实现的 `session_id` 无限制递增；超过 uint32 后 native binding 会拒绝请求，调用方无法继续发起 RPC。

当前分配器在 `UINT32_MAX` 后回绕到 1，跳过 0 和 pending table 中仍被占用的 ID。
回归测试直接覆盖最大值、回绕和占用 ID 跳过。

## 7. 路由和 ID 问题

### ROUTE-001：未知名称被路由到 root

- 严重程度：`P1`
- 状态：`FIXED`
- 证据：[src/lservice.c:33](src/lservice.c#L33)、[lua/lservice3.lua:250](lua/lservice3.lua#L250)

`_lookup` 找不到 name 时返回整数 0，而 root service 的合法 ID 也是 0。`send("typo", ...)` 和 `call("typo", ...)` 因而会把请求发送到 root，而不是报告不存在。

影响：错误服务执行、难以定位的 unknown command、RPC 挂起，甚至误触发 root 管理命令。

当前 `_lookup` miss 返回 nil；`send/call` 在 pack 前返回或抛出 `SERVICE_NOT_FOUND`，不会落到 ID 0。

### ROUTE-002：无效 ID 可使进程退出

- 严重程度：`P1`
- 状态：`FIXED`
- 证据：[src/service.c:60](src/service.c#L60)、[src/lservice.c:128](src/lservice.c#L128)

越界 ID 在 `service_pool_get_service` 触发 assert。范围内但尚未创建的 ID 返回 NULL，随后 `service_send` 解引用 `s->q`。负 Lua integer 转换为 unsigned 后也会进入越界路径。

native binding 在转换前检查 uint32 和 `0..31` 范围，`service_pool_pin` 再验证 slot/routable；不存在时返回 `SERVICE_NOT_FOUND`。当前信任上游不伪造 service/pool lightuserdata；完整 provenance 校验保留为最终可选安全任务。gateway 仍是必须独立验证的不可信输入边界。

### LIMIT-001：service 上限 off-by-one 和 pool 计数损坏

- 严重程度：`P2`
- 状态：`FIXED`
- 证据：[src/service.h:18](src/service.h#L18)、[src/service.c:325](src/service.c#L325)

数组声明为 `MAX_SERVICES + 1`，创建逻辑允许 `id == MAX_SERVICES`，但 getter 只允许 `< MAX_SERVICES`，所以 ID 32 可以创建却不可访问。

达到上限后 `pool->id` 已先递增，失败时没有回滚。后续 `service_pool_lookup_service` 按损坏后的 `pool->id` 遍历，可能读取 services 数组之外。

合法范围固定为 `0..MAX_SERVICES-1`。容量和 active name 唯一性在 pool lock 内、递增 `next_id` 之前检查；C 生命周期测试覆盖第 33 次创建失败且计数不变。

## 8. 生命周期和资源问题

### LIFE-001：service 退出后没有完成注销和释放

- 严重程度：`P1`
- 状态：`PARTIAL`
- 证据：[src/service.c:368](src/service.c#L368)、[src/service.c:417](src/service.c#L417)

线程函数在 `service_init_lua` 返回后直接退出，没有调用 `service_free`，也没有从 pool 移除 service。`service_free` 本身也不释放 source、async handler、service 对象、pool、mutex 或剩余消息。

影响：

- service/VM/queue/handle/source 内存泄漏。
- lookup 仍能找到已退出 service。
- 向已退出 service 发送消息可能积压、挂起或操作已经关闭的 async handle。
- ID 无法可靠复用，bootstrap 无法证明资源归零。

当前已经实现单向状态、registry retire、send pin、mailbox drain、join 后重资源释放和 stable tombstone。仍缺 pool 的 Lua GC/bootstrap 销毁、精确资源计数，以及复杂 luv userdata 的关闭验证，因此暂不标记为完全 FIXED。

### LIFE-002：stop 重入且被调用两次

- 严重程度：`P1`
- 状态：`FIXED`
- 证据：[lua/lservice3.lua:347](lua/lservice3.lua#L347)、[lua/lservice3.lua:413](lua/lservice3.lua#L413)、[src/service.c:409](src/service.c#L409)

handler 调用 `service.quit` 时立即进入 `_stop`。C stop 在当前 libuv callback 内调用 `uv_stop`、`uv_walk`、嵌套 `uv_run` 和 `uv_loop_close`。dispatch 返回前又看到 `quit == true`，再次调用 `service.quit`。

最小测试目前可以退出，但这不证明重入关闭合法；复杂 timer/socket handle 下可能出现 `UV_EBUSY`、重复 close 或未定义行为，且所有 libuv 返回值都被忽略。

`quit` 现在只设置幂等 stop request 并通知 control async。消息 callback 返回后，目标 service 线程等待 send pin、drain mailbox、关闭 handle 并让主 `uv_run` 自然退出，不再嵌套运行 loop。

### LIFE-003：初始化失败缺少完整回滚

- 严重程度：`P2`
- 状态：`PARTIAL`
- 证据：[src/service.c:315](src/service.c#L315)、[src/service.c:377](src/service.c#L377)

问题包括：

- 多处 malloc、queue、uv loop 和 async 初始化返回值未检查。
- `pthread_create` 失败后仍把可能未初始化的 thread 值写入 service。
- Lua 初始化失败时关闭了 `L`，但 `s->L` 仍保存悬空指针。
- service 已注册到 pool 后发生初始化失败，没有注销。
- config 在 source 未执行时可能无人释放。

当前创建流程最后注册，start 等待 `start_done`，Lua/source 初始化失败会 retire、drain、关闭 loop、join 并释放 config/source/mailbox。尚未为每一个 malloc/pthread/libuv 失败点建立可控故障注入，详细根因也只进入日志而未随错误对象返回，所以保留 PARTIAL。

### LUV-001：luv 动态库句柄按 service 重复加载

- 严重程度：`P2`
- 状态：`FIXED`
- 证据：[src/loadluv.c:82](src/loadluv.c#L82)、[src/loadluv.c:129](src/loadluv.c#L129)、[tests/c/service_lifecycle_test.c:47](tests/c/service_lifecycle_test.c#L47)

旧实现让每个 service 都调用 `dlopen/dlsym`，并遗失栈上 `luv_lib` 中的 handle。重复增加动态库引用计数没有必要，也没有明确函数指针的进程级生命周期。

现在由唯一的 loader 实现使用 `pthread_once` 加载并解析一次，保存成功或失败结果，handle 保留到进程退出。`luaopen_luv` 不属于 once：每个 VM 仍先绑定自己的 `uv_loop_t`，再创建并缓存自己的 luv module table。并发双 service 测试验证 loader 只初始化一次、VM/loop 不共享，关闭其中一个不影响另一个。

## 9. 序列化问题

### SER-001：共享 table 引用无法解码

- 严重程度：`P1`
- 状态：`KNOWN-FAIL`
- 证据：[src/lua-seri.c:697](src/lua-seri.c#L697)
- 回归测试：[tests/regression/serializer_shared_ref_spec.lua](tests/regression/serializer_shared_ref_spec.lua)

扩展引用解码先从 ref table 取出对象，然后在对象类型为 table 时反而抛出 `Invalid ref object id`：

```c
lua_rawgeti(L, s->ref_index, id);
if (lua_type(L, -1) == LUA_TTABLE)
    luaL_error(L, "Invalid ref object id %d", id);
```

这不是只在“超过 32 个对象”时出现。一个 table 在兄弟位置被引用两次即可失败；祖先循环引用走另一条短引用路径，所以循环自引用基线测试可以通过。

验证命令：

```sh
make test-regression
```

当前预期结果：失败并输出 `Invalid ref object id 2`。修复后该目标必须通过，并保留 1、31、32、33、1000 个共享对象测试。

其他序列化风险：

- 格式使用本机整数、double、指针和字节序，不适合作为跨进程/持久化格式。
- lightuserdata 和 C function 只复制裸地址，不管理指向对象生命周期。
- 解码长度信任 buffer 头，缺少全局 payload/depth/object 限制。
- `__pairs` 序列化会执行用户元方法，可能产生副作用。

## 10. Lua API 问题

### API-001：多个公共 API 实现与签名不一致

- 严重程度：`P2`
- 状态：`OPEN`

已确认项目：

1. [lua/lservice3.lua:64](lua/lservice3.lua#L64)：`config` 没有 `local`，污染 service VM 的全局环境。
2. [lua/lservice3.lua:95](lua/lservice3.lua#L95)：`get_uv_loop(addr)` 忽略 addr，始终使用 `service.self`；standalone 调用可把 NULL 传入 C。
3. [lua/lservice3.lua:101](lua/lservice3.lua#L101)：standalone 下 `get_id(addr)` 无条件返回 0，无法查询第二个 service 的真实 ID。
4. [lua/lservice3.lua:129](lua/lservice3.lua#L129)：`get_addr` 把 lightuserdata 写入 stderr，Lua IO 可能因参数类型报错；查询 API 还产生无条件调试输出。
5. [lua/lservice3.lua:154](lua/lservice3.lua#L154)：`send_message` 调用 `_send_message` 时漏传 pool，所有参数整体错位。
6. [lua/lservice3.lua:161](lua/lservice3.lua#L161)：`blocking = blocking or true` 使显式 false 也变成 true。
7. [src/service.c:390](src/service.c#L390)：底层所谓 blocking 也没有等待，只是最多 pop 两次。
8. [lua/lservice3.lua:424](lua/lservice3.lua#L424)：`type(entry.source == "string")` 检查的是 boolean 的类型，不能验证 source 类型。
9. [lua/lservice3.lua:138](lua/lservice3.lua#L138)：没有 config 时 `service.config` 可能是 nil，而不是稳定的空 table。
10. `_send_message` 成功不返回状态，`service.send` 因而无法报告成功、full 或 stopped。

解决方向：保持函数名和参数形式兼容，但修正 bug 行为；为查询、发送和启动定义明确返回契约，并建立 API contract 测试。

## 11. 消息协议问题

### PROTO-001：消息类型没有完整分派

- 严重程度：`P2`
- 状态：`FIXED`
- 修复：[lua/lservice3.lua](lua/lservice3.lua)、[tests/lua/rpc_spec.lua](tests/lua/rpc_spec.lua)

dispatcher 显式处理 REQUEST，以及 session 大于 0 的 RESPONSE/ERROR。其他 type/session 组合
直接释放 payload，不进入 pending lookup。合法 completion 仍需命中 pending session 才恢复
coroutine；当前可信模型不校验 response 来源，也不处理重复 completion。

## 12. Gateway 和网络问题

### GATE-001：gateway 当前无法处理一次有效请求

- 严重程度：`P1`
- 状态：`OPEN`
- 证据：[service/gateway.lua:36](service/gateway.lua#L36)、[service/gateway.lua:41](service/gateway.lua#L41)、[service/gateway.lua:45](service/gateway.lua#L45)

请求链存在多个独立阻断点：

1. 收到 JSON 后发送命令名 `handler`，但 table 注册的是 `request_handler`。
2. `client` 是 luv full userdata，当前 serializer 不支持 full userdata；在派发命令前 `service.send` 就会序列化失败。
3. `request_handler` 定义在局部 `send_json` 声明之前，因此其中的 `send_json` 解析为全局变量，调用时为 nil。
4. `resp` 没有用于响应，代码固定发送字符串 `"msg handled"`。
5. JSON decode 的 `ok` 未用于提前返回，错误没有协议响应。
6. client registry 使用 peer table 作为 key；再次 `getpeername()` 得到的 table 身份不保证相同，删除可能失败。

解决方向：socket handle 不能跨 service serializer 传递。网络 callback 应把纯 Lua 数据交给 handler，并在原 gateway service 中用 connection ID 映射回 client。命令名、局部函数声明顺序和响应协议必须统一。

### NET-001：TCP buffer 无上限且默认外部暴露

- 严重程度：`P2`
- 状态：`OPEN`
- 证据：[service/gateway.lua:10](service/gateway.lua#L10)、[service/gateway.lua:118](service/gateway.lua#L118)、[service/remote.lua:41](service/remote.lua#L41)

gateway 和 remote 把每次 chunk 连接到 Lua string，直到遇到换行；客户端可以持续发送不含换行的数据，造成无界内存增长和反复字符串复制。两者默认绑定 `0.0.0.0`。

解决方向：设置最大帧、最大连接数、读超时；超限关闭连接；默认只监听 localhost，外部绑定必须显式配置。

## 13. 其他 C 实现问题

### REG-001：registry key 可能溢出

- 严重程度：`P2`
- 状态：`OPEN`
- 证据：[src/registry.c:23](src/registry.c#L23)

registry 分配固定 32 字节 key，随后使用无边界 `strcpy`。当前 registry 路径没有暴露为主要 Lua API，但一旦调用方传入超过 31 字节的 key 就会覆盖相邻内存。

解决方向：在 API 边界验证长度并使用有界复制；最好把 key 长度作为契约，不依赖隐含数组大小。

### DOC-001：核心代码仍含不必要依赖和未完成结构

- 严重程度：`P3`
- 状态：`OPEN`

示例：

- [lua/lservice3.lua:2](lua/lservice3.lua#L2) 无条件 require `inspect`，实际使用只存在于注释调试代码中。
- Lua 层保留多个未使用 session table、receipt 常量和整段注释实现。
- C 返回值常使用固定 1，无法表达真实错误。
- 中英文注释、tab/space 和命名存在混用。

这些问题不会单独造成最高优先级事故，但会隐藏真正的状态和所有权，使修改更容易引入回归。处理时应先完成 P1 契约，再清理死代码，避免把格式整理和行为修复混成难以审查的大提交。

## 14. 测试和工程问题

### TEST-001：legacy 测试不可作为自动化入口

- 严重程度：`P3`
- 状态：`LEGACY`
- 证据：[tests/legacy/test.lua:2](tests/legacy/test.lua#L2)

原 `test.lua` 引用不存在的 `lservice2`，包含大量注释实验，并在最后启动长期 signal loop。它被原样保留仅用于追溯，不纳入默认测试。

当前新增测试：

- [tests/lua/serializer_spec.lua](tests/lua/serializer_spec.lua)：普通值、二进制字符串、嵌套 table、循环引用。
- [tests/lua/lifecycle_spec.lua](tests/lua/lifecycle_spec.lua)：最小 service 启动、dispatch 和退出。
- [tests/lua/rpc_spec.lua](tests/lua/rpc_spec.lua)：managed coroutine 校验、uint32 session 回绕和同 service RPC。
- [tests/lua/mailbox_spec.lua](tests/lua/mailbox_spec.lua)：mailbox full 的 Lua 错误链路。
- [tests/c/mailbox_test.c](tests/c/mailbox_test.c)：1/2/4/16 producer、FIFO、full 和 close。
- [tests/c/service_lifecycle_test.c](tests/c/service_lifecycle_test.c)：pin/free 同步、8 producer stop 竞争、name/ID 上限。
- [tests/regression/serializer_shared_ref_spec.lua](tests/regression/serializer_shared_ref_spec.lua)：共享引用已知失败。

仍缺少：

- 跨 service RPC、多返回值和可信 response 压力测试。
- pool/bootstrap 资源归零和复杂 luv handle 关闭测试。
- ASan/UBSan/LSan/Valgrind。
- gateway 协议和恶意输入测试。
- serializer malformed input 和 fuzz。

## 15. 修复优先级

建议按以下顺序推进，避免在不稳定基础上扩展功能：

1. 完成 SEC-001 的外部凭据轮换确认。
2. 补齐 lifecycle 故障注入、复杂 luv handle 关闭和 pool/bootstrap 销毁。
3. 在可信 REQUEST/RESPONSE/ERROR 边界内补齐跨 service、多返回值和压力测试。
4. 用 LSan、长消息测试或资源计数确认消息、Lua 栈和 payload 长期不增长。
5. 修正其余公共 API contract。
6. 按需要评估 serializer 安全增强和网络 gateway。
7. 清理死代码、统一编码风格、补齐性能和工程工具。
8. 只有未来扩大 native 信任边界时，才实现任意 lightuserdata、pool 归属和 stale addr provenance 验证；当前不阻塞发布。

## 16. 问题关闭标准

问题只有同时满足以下条件才能标为 `FIXED`：

1. 根因已修复，而不是只绕过一个示例输入。
2. 有能够在旧实现上失败、在新实现上通过的自动化测试。
3. 错误路径的内存和 handle 所有权已验证。
4. 相关接口和行为同步写入 `DESIGN.md` 或 README。
5. 并发问题通过 TSAN 或等价工具验证。
6. 生命周期/内存问题通过 sanitizer 或资源计数验证。
7. 没有通过弱化断言、忽略返回值或隐藏日志来制造“通过”。

当前还证明 spinlock MPSC mailbox 在 1/2/4/16 producer 下无丢失、重复或 producer 内乱序，并通过 TSAN 覆盖 send pin 与 retire/close/join 竞争。它仍不证明复杂 luv handle、pool teardown 和可信 RPC 的跨 service 压力路径可用于生产。
