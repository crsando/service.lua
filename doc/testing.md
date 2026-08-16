# 测试和验收策略

## 原则

测试按风险分层。旧实现上的已知失败保留为可执行回归，不通过删除断言、吞掉错误或放宽契约制造绿色结果。

每个问题标记 FIXED 需要：

1. 根因修复。
2. 旧实现失败、新实现通过的测试。
3. 成功和错误路径所有权验证。
4. README/模块文档同步。
5. 并发问题通过 TSAN。
6. 生命周期/内存问题通过 sanitizer 或精确资源计数。

## 测试层次

### Contract

固定不依赖内部结构的兼容表面：

- `require "lservice3"` 和所有 Lua 公共函数。
- `require "lservice3_c"` 和全部 native export。
- message type 数值和 service/session ID 宽度。
- source/handler 形式和基本返回类型。

contract 测试应该从重写第一天保持通过。行为契约暂未实现时以独立 known-fail regression 表达，不能污染“表面是否意外消失”的信号。

### C Unit

- mailbox FIFO/full/close/MPSC 和 batch finish/rearm。
- pool ID/name/stable handle/pin。
- message ownership。
- serializer cursor/header/tag/limits。
- 状态机合法/非法 transition。

这些测试不启动完整 Lua service，便于 TSAN、ASan 和故障注入。

### Lua Unit

- pack/unpack value graph。
- API 参数和错误码。
- managed coroutine call validation 和 uint32 session allocator。
- dispatch function/table。

### Integration

- source string 和 `@file`。
- standalone/bootstrap/root/child 生命周期。
- send、self-call、cross-service call、nested call。
- dispatch 256 条边界、每轮 `on_idle`、timer 公平性、socket、stop 和 join。
- managed coroutine validation、session 回绕和可信 response happy path。

### Stress

- 16 producer mailbox。
- 100 万消息无按消息增长泄漏。
- mailbox batch 对 timer latency 的影响。
- 重复 bootstrap/create/stop/join。
- session 回绕和大量 pending RPC。

## Make Targets

当前和目标入口：

| target | 作用 | 当前状态 |
| --- | --- | --- |
| `make` | 构建 native module | 基线可用 |
| `make test-contract` | Lua/native/message ABI 表面 | 已建立 |
| `make test` | 默认基线/稳定测试 | 基线可用 |
| `make test-regression` | 已知设计回归 | 允许红，逐项转绿 |
| `make test-asan` | ASan/UBSan/LSan | 待实现 |
| `make test-tsan` | mailbox MPSC 与 send-pin/stop/free 并发 | 已建立 |
| `make lint` | strict C + Lua 静态检查 | 待实现 |

默认 `make test` 最终必须包含 contract、C unit、Lua unit 和不需要外部服务的 integration。known-fail 不进入默认绿色套件。

## Sanitizer

### ASan/UBSan

- malformed serializer input。
- invalid ID/size；任意 ptr provenance 测试只在可选 native 边界增强启用后加入。
- create/start 失败回滚。
- stop/drain/close/free。
- function/lightuserdata 表示转换。

### LSan/Valgrind

- mailbox 残留 payload；message descriptor 不做逐条分配。
- serializer block/ref table。
- source/config/handle。
- Lua VM、luv module 和动态库策略。
- timer/socket/async handle。

进程级永久保留的 luv dlopen handle 和明确的 tombstone registry 需要文档化 suppression 或内部计数，不能用宽泛 suppression 隐藏其他泄漏。

### TSAN

- 多 producer mailbox。
- 并发 service start 只初始化一次 luv loader，每个 VM 绑定独立 loop。
- lookup/pin 与 unregister/free。
- STARTING/start handshake/stop。
- concurrent stop/join。
- log/metrics registry。

## 精确资源断言

测试模式提供 runtime snapshot：

```text
services_active
service_pins
messages_live
buffers_live
buffers_bytes
pending_rpc
lua_states_live
uv_handles_live
threads_unjoined
```

bootstrap 成功结束后除明确 process-lifetime 资源外全部为 0。压力测试比较前后 snapshot，避免只凭 RSS 判断泄漏。

## Lua Stack

每个 native callback：

1. 记录 `lua_gettop`。
2. 执行成功、handler error、decode error、stop 等路径。
3. 返回前恢复并断言 stack top。

长时间消息测试同时采样 Lua memory，防止每 callback 遗留 nil/result。

## 可选故障注入矩阵

当前主线假定底层启动步骤成功。未来需要覆盖运行时故障时，再对创建/启动的资源取得步骤逐项注入失败：

| 阶段 | 期望 |
| --- | --- |
| service/handle alloc | pool 不变，config owner 明确 |
| mutex/cond/mailbox init | 逆序销毁已完成步骤 |
| registry insert | name/ID/next_id 不损坏 |
| pthread create | 回到 terminal state，可释放 |
| uv loop/async init | start 返回根因，线程可 join |
| Lua/luv/source/handler | mailbox drain，config 释放 |
| send compose/push/notify | ptr/message 所有权唯一 |
| completion serialize/send | 当前可信路径成功投递；故障行为在未来扩大边界后定义 |

## 发布门槛

- strict C 编译零告警。
- 核心 Lua 无未声明全局变量。
- contract、unit、integration 全绿。
- TSAN 16 producer 无 race/丢失/重复。
- ASan/UBSan/LSan 无未解释问题。
- 100 万消息资源计数无增长。
- 可信前置条件成立时，所有已接受 RPC 最终得到 response。
- shutdown 后 runtime 资源归零。
- 仓库无凭据、二进制产物或未说明许可证代码。
