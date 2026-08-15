# 原生运行时与 libuv

## Lua Binding 规则

`lservice.c` 是 Lua ABI 与 runtime 的唯一边界：

- 使用 `luaL_check*` 或显式类型检查验证所有参数。
- Lua integer 转换到 uint32/size_t 前检查负值、范围和精度。
- service/pool lightuserdata 当前只来自可信兼容层；native ABI 不对网络或不可信 Lua 开放。
- native 函数只返回 README 定义的成功值或 `nil,error`；参数错误可抛 Lua error。
- 外部输入不能触发 `assert`、NULL dereference、invalid free 或越界访问。
- 每个函数在注释中标记每个 pointer 参数的进入/退出所有权。

内部 C 函数统一 0 成功、非零明确错误码。不能用无含义的固定 1 表示所有结果。

完整的 handle provenance/magic/generation 验证不是当前发布阻塞项，保留为信任边界扩大后的可选增强。这个决定不放宽 ID、size、状态和消息所有权的常规校验。

## C 类型和内部 ABI

公开稳定类型：

```c
typedef uint32_t service_id_t;
typedef uint32_t session_id_t;
```

`service_t`、`service_pool_t`、`mailbox_t` 和 handle 布局是私有 ABI。除 runtime 自身测试外，不安装这些内部头文件。

编译期使用 `_Static_assert` 验证 ID 宽度、message type 数值和 serializer header 常量。

## libuv Loop 归属

- 每个 service 独立 `uv_loop_t`。
- loop 和普通 handle 只由 service pthread 初始化、操作和关闭。
- 其他线程只在持有有效 send pin 时调用 libuv 明确标记为线程安全的 `uv_async_send`。
- async handle 的 data 指向 pinned runtime object；close callback 前 runtime 不能释放。
- callback 进入 Lua 前保存 stack top，退出时恢复。

inbox async 负责业务消息，control async 负责 stop/fault 等生命周期事件。二者分离，避免业务 batch 和关闭请求互相递归。

## luv Loader

luv 动态库进程级加载一次：

```text
pthread_once
    -> locate trusted luv.so
    -> dlopen(RTLD_NOW | RTLD_GLOBAL)
    -> resolve luaopen_luv
    -> resolve luv_set_loop
    -> retain handle until process exit
```

这里的“一次”只指 `dlopen/dlsym`。luv 的 C 代码和函数地址由进程共享，但 Lua table、registry、userdata 和 callback 状态不能跨 VM 共享。宿主 VM 加载 `lservice3_c` 时优先从其 `package.cpath` 确定路径；直接使用 native C API 时，由第一个 service VM 惰性完成同一初始化。第一次初始化的成功或失败结果在进程内保持不变，不按 service 重试或切换 luv 版本。

每个 service VM：

1. `luv_set_loop(L, service_loop)`。
2. 在保护调用中执行 `luaopen_luv(L)`，要求恰好返回一个 module table。
3. 写入 `package.loaded["luv"]`。
4. 恢复预期 Lua stack depth。

不在 service stop 时 `dlclose`。Lua/C function 序列化可能让其他 VM 保存动态库代码地址。

并发启动多个 service 时，`pthread_once` 只串行化首次动态库初始化；各 service 的 `luv_set_loop/luaopen_luv` 仍在各自 pthread 上操作各自 VM。测试必须证明 loader 初始化计数为 1、VM 和 loop 地址不同，并且关闭一个 service 不改变另一个 service 的 RUNNING 状态和 loop 可用性。

POSIX 允许 `dlsym` 结果用于函数指针，但直接赋值会触发 `-Wpedantic`。实现使用有尺寸断言的 `memcpy` 在 `void *` 对象和函数指针对象之间复制表示，并在 Linux CI 上验证。

## Source 加载

- `@path` 使用二进制读取和显式 size，不依赖 `strlen`。
- source path 来自可信启动配置，不接受网络客户端输入。
- 检查文件大小上限和所有 IO 返回值。
- chunk name 保留 `@path`，使 traceback 包含正确文件名。
- 源码字符串使用显式长度接口，后续如支持 binary chunk 必须由配置启用。
- source 必须返回 function；其他结果是 `SERVICE_START_FAILED`。
- config buffer 在 source 初始化期间由 native 持有；`service.input` 只调用 `unpack` 借用读取，`lua_pcall` 成功或失败返回后由 native 释放。业务代码不得保存 config_ptr。

## 日志

日志模块默认自身线程安全，不能要求使用方可选安装锁：

- 内部 mutex 保护输出和 callback registry。
- 使用 `clock_gettime`/`localtime_r` 等线程安全接口。
- 一条记录一次格式化后写出，避免多个 `fprintf` 交错。
- 日志 callback 在锁外调用或明确禁止回调 logger/runtime，防止死锁。

每条 runtime 日志至少包含：

```text
timestamp level service_id service_name thread_id component event message
```

禁止记录密码、认证码、完整请求 payload 和裸凭据。

## Metrics 和资源审计

进程/每 service 维护：

- service state transitions 和启动/停止错误。
- mailbox length/high watermark。
- message accepted/rejected/received/dropped/live。
- buffer live/bytes/owner。
- pending RPC/success/error/timeout。
- libuv handle created/closed/live。
- handler duration 和 dispatch batch。

debug API 可以暴露快照，但 metrics 不参与控制流。bootstrap teardown 使用内部精确计数验证资源归零。

## 分配和故障注入

所有 malloc/pthread/libuv/Lua 初始化调用检查返回值。测试构建允许注入“第 N 次操作失败”：

- allocation。
- mutex/condition init。
- mailbox init。
- pthread create。
- uv loop/async init 和 async send。
- Lua VM/source/handler init。
- serializer registry insert。

每个失败点验证反向回滚，不只检查返回错误。

## 构建约束

目标参数：

```text
-std=c11 -Wall -Wextra -Wpedantic
CI: -Werror
```

Linux/POSIX feature macro 由 Makefile 统一定义，例如 `_POSIX_C_SOURCE=200809L`。不使用隐式函数声明、空 struct、非标准 `strlcpy` 或已弃用 `usleep`。

通过 `pkg-config` 查找 LuaJIT/libuv，并显式链接 pthread、uv 和平台所需 dl。构建产物只进入 `build/`。

## 安全边界

- service source 被视为可信代码；runtime 不是 Lua 沙箱。
- buffer ptr 是受管能力，普通 lightuserdata value 不是。
- gateway/network 是独立信任边界，不能直接调用 native ABI。
- native debug pointer API 不暴露给不可信 service。
- runtime 错误优先隔离目标 service；只有内部不变量已经破坏且无法安全继续时才升级进程 fatal。
