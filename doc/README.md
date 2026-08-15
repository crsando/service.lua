# 内部设计文档

本目录按 runtime 模块维护内部流程和实现不变量：

- [总体架构](architecture.md)：组件、线程归属、stable handle、锁顺序。
- [Service 生命周期](lifecycle.md)：创建、启动、停止、join、回收和失败回滚。
- [消息、邮箱与所有权](messaging.md)：MPSC mailbox、send 事务、路由和 backpressure。
- [RPC、Coroutine 与调度](rpc-scheduling.md)：session、timeout、错误、取消和公平性。
- [Serializer 与 Buffer Registry](serialization.md)：可选的后续安全增强。
- [原生运行时与 libuv](native-runtime.md)：binding、loop/luv、日志、metrics 和构建约束。
- [测试和验收策略](testing.md)：contract、unit、integration、stress 和 sanitizer。
- [Skynet 消息系统研究](skynet-analysis.md)：mailbox、消息所有权、context 退出和 `lua-seri` 的上游实现分析。

仓库根目录 [README](../README.md) 定义公开 Lua API、native ABI、消息/序列化 ABI 和开发任务状态。本目录不应重新定义冲突的公开接口；如内部设计需要改变公开契约，应先更新 README 和对应 contract test。
