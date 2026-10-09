# 测试

所有命令都在仓库根目录执行。Lua 测试通过 `LUA_PATH=./lua/?.lua`、`LUA_CPATH=./build/?.so` 使用工作区中的代码，不依赖已安装的版本。

```sh
make test             # 默认测试套件（下面除 tsan 以外的全部测试）
make test-contract    # 公共接口与 ABI 契约
make test-mailbox     # 邮箱 C 单元测试
make test-service     # 生命周期 C 测试
make test-lua         # tests/lua/ 下的 Lua 集成测试
make test-scheduler   # 只运行调度器的两个测试
make test-examples    # 端到端运行 examples/
make test-tsan        # 用 ThreadSanitizer 运行邮箱和生命周期测试
make test-regression  # 序列化共享引用回归测试
```

## 分层

| 目录 | 内容 |
| --- | --- |
| `contract/` | `api_surface_spec.lua`：`service`、`service_c` 的导出表面。`serializer_module_spec.lua`：独立编译的序列化模块。`message_abi_test.c`：消息类型数值和 ID 位宽 |
| `c/` | `mailbox_test.c`：FIFO、满和关闭的语义、唤醒合并，以及 1/2/4/16 个生产者的并发测试。`service_lifecycle_test.c`：send pin 与 join/free 的同步、并发 retire/close/join、启动期间 stop、luv handle 的关闭、32 个 service 和名字约束 |
| `lua/` | 序列化（小数键、`__pairs`、循环和共享引用）、生命周期、邮箱满和停止时的错误、RPC（多返回值含 nil、立即与延迟错误、嵌套调用、128 个并发 pending）、跨 service 的 RPC、256 条分发边界与 `on_idle`、table source、bootstrap（返回值、入口错误、`quit(err)`、分发循环错误、启动失败、子 service 回收）、调度器 |
| `legacy/` | 历史上的 `test.lua`，仅作追溯，引用了已不存在的模块，不参与运行 |

`examples/demo.lua` 和 `examples/scheduler.lua` 由 `test-examples` 运行：每个示例都必须在 10 秒内自行退出，并打印出预期的最后一行。

## 约定

- 修改公共 API 时，需要同步更新 `contract/api_surface_spec.lua` 和 [doc/api.md](../doc/api.md)。
- 涉及并发的修改需要通过 `make test-tsan`。
- 修复 [doc/known-issues.md](../doc/known-issues.md) 中的条目时，需要补充回归测试，并更新或删除对应条目。
