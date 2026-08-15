# 总体架构

## 目的

本文定义 `service.lua` 的内部组件、线程归属、Actor 语义和模块依赖。公开接口以仓库根目录的 [README](../README.md) 为准。

## 运行时拓扑

```text
host Lua VM
    |
    | bootstrap/new/start
    v
service_pool_t
    |-- service handle 0 (root)
    |-- service handle 1
    `-- service handle N
          |
          | pins runtime resources while active
          v
       service_t
          |-- pthread
          |-- lua_State
          |-- uv_loop_t
          |-- inbox uv_async_t
          |-- control uv_async_t
          `-- mailbox_t
```

一个进程可以存在多个 pool，但消息默认只在同一 pool 内路由。service ID 只在所属 pool 内有意义。

## Actor 语义

### 隔离

- 每个 service 使用独立 Lua VM，不共享 Lua registry、global table、coroutine 或 GC heap。
- 业务数据必须 pack 后进入目标 mailbox。
- lightuserdata 和 C function 只是可信 service 间的进程内地址语义，不构成安全沙箱。
- full userdata 不跨 service 传输；socket/timer 等 luv handle 只能留在创建它的 service。

### 单线程和可重入

同一 service 的 Lua 代码始终只由自己的 pthread 执行，因此不会有两个线程同时操作同一个 `lua_State`。

每个 request 使用独立 coroutine。handler 在不 yield 的区间内不会被另一个 handler 抢占；一旦在 `call`、`sleep` 或异步等待处 yield，dispatcher 可以恢复其他 coroutine。业务状态因此具有“yield 点可重入”语义。

运行时不提供抢占式调度。无限 CPU 循环会阻塞该 service 的消息、timer、socket 和停止控制流程。

## 模块边界

| 模块 | 核心职责 | 不负责 |
| --- | --- | --- |
| `lua/lservice3.lua` | 参数归一化、session、coroutine、dispatch、timer、错误重抛 | pthread、跨线程锁、裸内存验证 |
| `lservice.c` | Lua 栈校验、public/native ABI、所有权边界 | 业务调度策略 |
| `pool` | ID/name registry、stable handle、pin、pool shutdown | Lua handler 执行 |
| `service` | pthread、VM、loop、状态机、start/stop/join | 序列化格式 |
| `mailbox` | bounded MPSC FIFO、close、容量和水位 | 目标查找、async 生命周期 |
| `message` | message/payload 单一所有权 | 路由策略 |
| `serializer` | value 编解码、限制、引用图 | service 生命周期 |
| `buffer registry`（可选） | 后续按需要验证 ptr/size/owner | 当前消息路径 |
| `luv loader` | 进程级加载符号、每 VM 绑定 loop | 网络业务协议 |
| `log/metrics` | 线程安全结构化日志和资源计数 | 业务控制流 |

模块必须通过头文件契约交互，不能从其他模块读取未公开结构字段。

## 线程归属

### Host/parent 线程可以执行

- 创建 pool 和稳定 handle。
- 初始化不依赖 libuv loop 的 mutex、condition 和 mailbox。
- 注册 service ID/name。
- 创建 pthread 并等待 start condition。
- 通过 mailbox 和 `uv_async_send` 向已 pin 的 service 投递。
- join 已停止的 pthread。

### Service 自己的线程执行

- 创建和关闭 `lua_State`。
- 初始化、运行和关闭 `uv_loop_t`。
- 初始化和关闭 loop 上的普通 handle。
- 加载 luv、source 和 handler。
- pop mailbox、dispatch Lua、处理 timer/socket callback。
- 执行 stop control path。

为了保持 loop 归属清楚，`uv_loop_init`、`uv_async_init` 建议在 service pthread 中完成。`STARTING` 期间允许先向 mailbox 入队；线程进入 RUNNING 后若发现 mailbox 非空，主动触发一次 inbox async。

## Stable handle 与 runtime object

公开 addr 必须晚于它指向的重资源存活。当前最多 32 个 service 且 ID 不复用，因此第一版不额外分配 handle 对象，而是让 `service_t` 兼任稳定 tombstone：

```c
typedef struct service {
    service_pool_t *pool;
    uint32_t id;
    bool routable;
    unsigned send_pins;
    service_state_t state;
    mailbox_t *inbox;
    /* Lua/libuv/thread runtime fields */
} service_t;
```

- registry slot 在 pool lock 内验证 ID/routable 并递增 `send_pins`。
- lookup/pin 是一个临界区；pin 存在期间 mailbox 和 async 不能关闭或释放。
- stop 先从 registry 注销可路由身份，再等待发送 pin 归零。
- native join 后释放 `service_t` 中的重资源，结构本身作为 tombstone 保留到 pool 销毁。
- 第一版不复用 ID，所以不会发生旧 ID 指向新 service 的 ABA；未来若复用必须增加 generation/token。

这种实现避免了每次 send 的额外 handle allocation。当前信任上游不伪造 lightuserdata，native debug 指针不得暴露给不可信 Lua；完整 provenance 验证放到最后作为可选增强。pool Lua GC 仍是生命周期闭环的必做项。

## 全局锁顺序

为避免停止、错误回复和跨 service send 形成环，统一顺序：

```text
buffer_registry.lock
pool.registry_lock
service.state_lock
mailbox.lock
```

规则：

1. 不允许逆序获取锁。
2. 不在持有 mailbox lock 时向另一个 service 发送错误。
3. 不在持有 pool/state/mailbox lock 时调用 Lua 或运行 libuv loop。
4. registry lookup 只在锁内验证并获取 pin；耗时工作在解锁后进行。
5. stop drain 先把 message 移到线程私有列表，再逐条回复/销毁。
6. 日志模块使用自己的内部锁，日志 callback 不能回调 runtime。

实现时应在 debug 构建加入 lock-order assertion 或线程局部持锁标记。

## 关键不变量

- 同一时刻每个 message 和 payload 只有一个所有者。
- 没有 pin 时才能释放 `service_t` runtime resources。
- RUNNING 之前不执行业务 handler；STOPPING 之后不接受新业务消息。
- 只有 service pthread 操作其 Lua VM 和普通 libuv handle。
- 任何 Lua/C ABI 输入错误都不能触发进程级 assert。
- 每次 C -> Lua callback 退出时 Lua stack top 恢复到进入值。
- pool 销毁前所有 pthread 已 join，所有 runtime pin 已归零。

## 模块依赖方向

```text
Lua API
  -> native binding
      -> pool/handle
      -> service lifecycle
          -> mailbox/message
          -> serializer
          -> luv loader
          -> log/metrics
```

mailbox 和 serializer 应可独立做 C 单元测试，不依赖 Lua service 启动流程。

## 非目标

- 跨进程或分布式 Actor。
- 恶意 Lua 代码沙箱。
- 抢占式 coroutine。
- 任意平台 ABI。
- 持久化序列化协议。
- 第一版无锁 mailbox。
