# service.lua

`service.lua` 是一个面向 LuaJIT 2.1（Lua 5.1 C API）的**进程内多线程 Actor 运行时**。

每个 service 独占一个 pthread、一个 LuaJIT VM、一个 libuv loop 和一个有界邮箱。service 之间不共享 Lua 对象，只通过序列化后的消息通信。业务代码在 coroutine 里用同步写法完成 RPC 和等待。

```lua
local service = require "service"

local S = {}

function S.boot()
    service.spawn { name = "echo", source = "@service/echo.lua" }
    print(service.call("echo", "echo", "hi", nil, 42))   --> hi  nil  42
    assert(service.call("echo", "quit"))
    service.quit()
end

return S
```

## 特性

- **线程隔离**：一个 service 对应一个线程、一个 VM、一个 loop。不同 service 的 Lua 状态完全独立，没有全局解释器锁。
- **同步写法的 RPC**：`service.call` 在当前 coroutine 内挂起，等到响应后恢复，等待期间 service 照常处理其他消息。
- **显式失败**：目标不存在、正在停止或邮箱已满时，`send` 和 `call` 返回 `nil, err`，不会静默丢消息。handler 抛出的错误会作为 `nil, err` 回到调用方。
- **内置 libuv**：每个 service 里的 `require "luv"` 已绑定到该 service 自己的 loop，timer、socket、子进程等可以直接使用。
- **可接入外部线程**：C/C++ 回调线程可以通过 `service.get_async()` 唤醒 service，再由 `service.on_idle` 在 service 线程内取走数据（见[使用指南](doc/guide.md#外部线程接入)）。
- **可选调度器**：`service.scheduler` 提供绝对时间和每日定时任务。

## 依赖

- Linux、pthread
- LuaJIT 2.1
- libuv，以及作为 C 模块安装的 luv（`luv.so` 必须能通过 `package.cpath` 找到）

## 构建、测试与运行示例

```sh
make                # 生成 build/service_c.so，所有构建产物都在 build/ 下
make test           # contract、单元、集成和示例端到端测试
make test-tsan      # 用 ThreadSanitizer 运行 C 测试
sudo make install   # 安装到 $(DESTDIR)$(PREFIX)，PREFIX 默认为 /usr/local
make clean          # 删除 build/
```

可覆盖的变量：`PREFIX`、`DESTDIR`、`BUILD`（输出目录）、`CC`、`CFLAGS`、`LUAINC`（缺省时取 `pkg-config --cflags luajit`，取不到则用 `-I/usr/local/include/luajit-2.1`）。

示例需在仓库根目录运行，因为 `@service/...` 路径相对于当前工作目录：

```sh
LUA_PATH='./lua/?.lua;;' LUA_CPATH='./build/?.so;;' luajit examples/demo.lua
LUA_PATH='./lua/?.lua;;' LUA_CPATH='./build/?.so;;' luajit examples/scheduler.lua
```

`examples/demo.lua` 依次演示 spawn、多返回值 call、错误返回、send、sleep、可重入回调和有序关闭。运行时 stderr 会出现一条 `unknown command: nope` 的 ERROR 日志，这是示例有意触发的错误。

## 目录

```text
lua/service.lua            Lua 公共 API
lua/service/scheduler.lua  可选调度器
src/                       C 运行时（service、mailbox、luv 加载、序列化、日志）与 Lua 绑定
service/                   示例 service：root、echo、user
examples/                  入口示例：demo.lua、scheduler.lua
tests/                     contract、C 单元、Lua 集成测试
doc/                       文档
```

## 文档

| 文档 | 内容 |
| --- | --- |
| [使用指南](doc/guide.md) | 编写 service、启动与关闭、常用模式和常见陷阱 |
| [API 参考](doc/api.md) | Lua 公共 API、错误码、`service_c` 原生接口、消息类型 |
| [调度器](doc/scheduler.md) | `service.scheduler` 的用法与语义 |
| [内部实现](doc/internals.md) | 线程模型、邮箱、唤醒、生命周期、luv 加载、序列化 |
| [已知限制与路线](doc/known-issues.md) | 当前限制、已知问题和改进方向 |
| [测试](tests/README.md) | 测试分层与运行方式 |

## 状态

项目源自 `lservice3`，已严格改名为 `service`：`require "service"`、`require "service_c"`、`require "service.scheduler"`，原生入口是 `luaopen_service_c`。旧名字不提供兼容别名，已安装的 `lservice3*` 文件需要手动清理。

当前实现已用于实际项目，但仍有若干待完善之处，例如 `bootstrap` 只 join root、`call` 没有超时、没有 pool 整体销毁等。详见[已知限制与路线](doc/known-issues.md)。
