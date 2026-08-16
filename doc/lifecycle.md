# Service 生命周期

## 状态定义

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
```

状态只允许单向移动：

```text
NEW -> STARTING -> RUNNING -> STOPPING -> STOPPED -> JOINED -> FREED
          |             ^
          `-------------'
        init fail/cancel
```

初始化失败或 STARTING 期间取消时，不发布 RUNNING，记录 `start_error` 后进入 STOPPED。是否成功不能只由 pthread 创建结果判断。

## 操作矩阵

| 状态 | send/call | start | stop | join | free |
| --- | --- | --- | --- | --- | --- |
| NEW | 拒绝或按明确配置预入队 | 转 STARTING | 转 STOPPED | 错误 | 仅创建回滚 |
| STARTING | 可入队，成功后处理 | 等待同一次 start | 设置 stop request | 等待 STOPPED 后 join | 禁止 |
| RUNNING | 接受 | already started | 转 STOPPING | 等待停止或报状态错误 | 禁止 |
| STOPPING | `SERVICE_STOPPING` | 错误 | 幂等成功 | 等待 STOPPED | 禁止 |
| STOPPED | `SERVICE_STOPPED` | 错误 | 幂等成功 | 转 JOINED | 禁止 |
| JOINED | `SERVICE_STOPPED` | 错误 | 幂等成功 | 返回已有结果 | 转 FREED |
| FREED | `SERVICE_STOPPED` | 错误 | 幂等成功 | 返回已有结果 | 幂等或错误 |

兼容实现允许 NEW/STARTING 预入队。此时尚未初始化 async 的 sender 只入队不唤醒；service pthread 完成初始化后无条件发送一次 inbox async，启动失败或取消则在 stop 路径 drain。

## 创建

创建流程按以下顺序执行，并记录每一步是否成功：

1. 校验 pool、source、name、mailbox size 和 config buffer。
2. 分配兼任 stable handle/tombstone 的 `service_t`。
3. 初始化 state mutex/condition 和 pin 计数。
4. 复制 source，接管或记录 config buffer 所有权。
5. 初始化 mailbox。
6. 在 pool lock 下检查容量和 name 唯一性，分配 ID 并注册 handle。

注册必须是最后一个对其他线程可见的创建步骤。失败按逆序回滚；失败不能消耗 `next_id`，不能留下 name、buffer 或半初始化 mutex。

第一版 ID 不复用，`service_t` tombstone 保留到 pool 销毁。JOINED 后可以释放 mailbox/source 等重资源，但 send 路由只按 ID 在 pool lock 内取得 pin，不能直接使用 tombstone 中已释放的字段。

## 启动握手

调用线程：

1. 在 state lock 下执行 NEW -> STARTING。
2. 调用 `pthread_create`。
3. 等待 `state_changed`，直到 `start_done`；不能只等待某个瞬时 state，因为 service 可能在调用线程醒来前已经从 RUNNING 进入 STOPPED。
4. `start_error == 0` 返回 0；否则抛出 `SERVICE_START_FAILED` 并 join 初始化线程。当前详细根因写日志，结构化传回调用方仍待实现。

service pthread：

1. 初始化 uv loop、inbox async 和 control async。
2. 创建 Lua VM、打开标准库。
3. 通过进程级 luv loader 绑定专属 loop。
4. 加载 source，始终传入 `(addr, config_ptr_or_nil)`；Lua 只借用 config 解包，`lua_pcall` 返回后由 native 释放。
5. 执行 source 并确认返回 function。
6. 如果 stop 尚未请求，发布 RUNNING 并 signal condition。
7. 如果 mailbox 已有预入队消息，触发 inbox async。
8. 运行 `uv_run(UV_RUN_DEFAULT)`。

任一步失败都保存包含阶段和 Lua/libuv 根因的错误，关闭已初始化资源，进入 STOPPED 并 signal condition。

## 停止请求

`service.quit`、外部 stop 和 pool shutdown 共用同一条控制路径：

1. 原子/锁内设置 `stop_requested`，重复调用不产生第二次关闭。
2. RUNNING 时通过 control async 唤醒 service pthread。
3. STARTING 时初始化线程在每个主要阶段检查请求；不再发布 RUNNING。
4. 不在调用 `quit` 的 Lua callback 内执行 `uv_run`、`uv_walk` 或 `uv_loop_close`。

`MESSAGE_SYSTEM`/`service.syscall` 暂未实现，但保留为未来从其他 service 请求目标执行协作式
`quit` 的候选入口。该入口只能在目标 Lua VM 内触发现有 stop request，不能另建关闭流程或在
SYSTEM handler 中直接销毁 loop/VM。若使用非零 session 请求 quit，需要先发送确认 response，
再让 control async 在 callback 返回后的安全边界进入 STOPPING；具体协议在实现前另行确定。

## RUNNING -> STOPPING

在 service pthread 的安全 callback 边界执行：

1. pool registry 注销 ID/name，禁止新 lookup pin。
2. 发布 STOPPING。
3. 关闭 mailbox，等待已经取得的 send pin 完成；pin 必须覆盖 `mailbox_try_push` 和 `uv_async_send`。
4. 让当前正在执行且未 yield 的 handler 返回到 dispatcher 边界。
5. 当前 handler 结束时，可先发送 RESPONSE 或 ERROR；可信 RPC handler 不得在发送 completion 前请求停止后再次 yield。
6. 当前阶段直接 drain mailbox 并销毁 payload。
7. 当前不恢复 suspended RPC，也不对尚未处理的 RPC 回复错误；目标在 completion 前停止属于违反可信 RPC 契约。
8. C 先关闭自己拥有的 inbox/control async handle；最后一个 native close callback 执行后，这些非-luv handle 已从 loop 移除。
9. 该 callback 再通过 Lua C API 调用当前 VM 中的 `luv.walk`，对尚未 closing 的 luv handle 调用 luv 自己的 `close`；不保存额外的 Lua function reference。随后继续运行 loop，直到 close callback 全部完成。

当前 RPC 不依赖关闭错误回复或 timeout 收尾。业务必须保证目标完成已经接受的 call 后再停止。

## Coroutine 取消

LuaJIT 2.1 没有通用的强制 coroutine close：

- 当前不单独恢复或取消 suspended RPC coroutine。
- 关闭 timer/socket 等由 runtime 持有的 handle。
- 最终 `lua_close` 回收 coroutine Lua 对象。
- 不执行 coroutine 中 yield 点之后的业务清理代码；需要外部资源清理的业务必须使用 runtime 管理的 handle 或显式 shutdown handler。

## 关闭 libuv 和 Lua

1. C 先对自己拥有的 inbox/control async handle 调用 `uv_close`；部分 luv 版本要求 `luv.walk` 不能看到不属于 luv 的 native handle。
2. 最后一个 native close callback 执行后，C 取得 `package.loaded.luv` 的 `walk/is_closing/close`，通过 luv 的公开 Lua 接口提交所有 luv handle 的关闭；不能使用 `uv_close(handle, NULL)` 绕过 `luv_close_cb`。
3. `uv_run(UV_RUN_DEFAULT)` 完成 luv close callback 和 pending request callback；callback 新建的 handle 在下一轮继续关闭。
4. `uv_loop_close` 返回 `UV_EBUSY` 时重复 walk/run，不能发布 STOPPED 或释放 Lua/service 内存。
5. `uv_loop_close` 成功后，不会再有 libuv callback 进入 Lua，此时执行 `lua_close` 释放已完成 close/unref 的 luv userdata 和 Lua VM。
6. 发布 STOPPED 并 signal condition；pthread 返回后由 join 释放 source、mailbox storage 等非线程亲和资源。

Lua/loop 的精确关闭顺序必须通过有 timer、socket 和 userdata finalizer 的测试验证，不能只依赖空 loop 示例。

## Join 和 free

- `join` 是阻塞等待和 pthread 回收操作，不是停止操作；它不会隐式设置 `stop_requested`。
- 推荐只由程序入口/bootstrap 所在的宿主线程调用。service 的业务 handler、timer/socket callback 和其他 libuv callback 不应 join 另一个 service，否则当前 event loop 会被阻塞，并可能形成跨 service 死锁。
- 只有非目标线程可以执行 `pthread_join`。
- 调用 join 前，目标应已经自行 `quit` 或由明确的外部控制路径请求 stop；否则 join 可以无限期等待。
- state lock/condition 保证同一 pthread 最多 join 一次。
- 第一个 join 保存 pthread 返回结果并发布 JOINED；并发/重复 join 复用结果，不会第二次调用 `pthread_join`。
- runtime pin 归零后才能释放 `service_t` 重资源。
- 当前 native `join` 成功后立即调用内部 free，释放 mailbox/source/config 并发布 FREED；`service_t` tombstone 自身留到 pool 销毁。
- FREED 后消息路由仍能把旧 ID 识别为 terminal handle，不能解引用已释放 runtime 字段。

当前阶段采用单 root 进程模型：程序入口 bootstrap root，宿主线程 join root；root pthread 完成自身 Lua/luv/libuv 关闭后退出，随后整个进程结束。pool 的长期复用、独立 GC 和完整 shutdown API 暂缓，不影响单个 service 必须在 pthread 返回前正确关闭线程归属资源这一要求。

## 当前实现边界

已实现并有自动化测试覆盖：

- ID lookup/pin 与 retire 使用同一把 pool lock 排序。
- stop 先 retire/close，service 线程等待 pin 后 drain，随后关闭 async/loop。
- handler 内 quit 不再嵌套调用 `uv_run`；control async 在 callback 返回后执行关闭。
- start 初始化握手、STARTING stop、source 初始化失败、重复 join 和 invalid ID 错误。

当前已覆盖 active timer 和已初始化 TCP handle 的基本关闭；尚未完成的必做项是逐初始化步骤故障注入、pending request/活动 socket 和关闭异常路径。RPC/coroutine 取消在可信接收方模型下不是当前目标。pool 的独立 GC/shutdown API 按当前“join root 后进程退出”的运行约束暂缓；任意伪造 lightuserdata 的进程级验证按可信上游假设移到最终可选项。

## Root 和进程退出

当前运行约束是程序入口只 bootstrap 一个 root，随后在宿主线程 join root。root 负责在业务层结束自己的生命周期并调用 `service.quit()`；join 返回表示 root pthread 已经完成线程归属资源的关闭。之后程序直接退出，由进程结束回收 pool 和其他进程级资源。

这个约束暂时搁置 pool 的独立 shutdown 问题，但不能用进程退出掩盖 service 内部的错误关闭：root pthread 返回前，所有 luv/libuv callback 必须结束，所有 handle 必须完成 close，`uv_loop_close` 必须成功，Lua VM 才能销毁。若 handler 永不返回，join 会继续等待；第一版不使用 `pthread_cancel` 强制拆除 Lua/luv 运行时。

## 必测故障点

- 每个 malloc、mutex/cond/mailbox 初始化失败。
- pool full 和重复 name。
- `pthread_create` 失败。
- `uv_loop_init`、`uv_async_init` 失败。
- Lua VM OOM、source 语法错、source 无 handler。
- luv 加载/绑定失败。
- STARTING 与 stop 并发。
- send pin 与 unregister/free 并发。
- handler 内 quit、外部 stop、重复 stop。
- self join、并发 join、重复 join。
- timer/socket 未关闭导致 `UV_EBUSY`。
