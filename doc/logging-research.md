# 日志机制调研

本文记录当前日志实现的问题，以及 skynet、ltask 的日志机制对比，作为后续改造 logger 的参考。调研时间：2026-10。

## 1. 当前实现

`src/log.c/.h` 原样引入 rxi/log.c（MIT）。

- **输出位置**：全部写 stderr。`log_log` 用 `init_event(&ev, stderr)` 调用 `stdout_callback`，名字叫 stdout，实际写的是 stderr。没有调用过 `log_add_fp` 或 `log_add_callback`。
- **格式**：`HH:MM:SS ERROR src/xxx.c:NN: <msg>`。
- **级别**：只用到 `log_error`。从没调用过 `log_set_level` 或 `log_set_quiet`，Lua 侧也无法调整。
- **Lua 入口**：`service._log_error(addr, msg)`（`src/lservice.c`），固定输出为 `service <id> handler: <msg>`。
- **不经过 log 的输出**：`service.root` 失败时写到 stderr 的 `service.root: <err>`，以及 scheduler 在 `_log_error` 不可用时退回 `io.stderr` 的输出。
- **状态共享范围**：log 的状态是 `log.c` 里的静态变量 `L`。同一进程只会 dlopen 一份 `service_c.so`，所以这份状态由所有 service 线程共享。

### 1.1 已知问题

1. **不是线程安全的**（与 `internals.md` 的描述不符）。rxi/log.c 不自带锁，需要使用方调用 `log_set_lock` 注入，而我们从未调用。
   - 一行日志分三次 stdio 调用写出：`fprintf` 写前缀、`vfprintf` 写正文、`fprintf` 写换行。每次调用各自加锁，三次之间没有锁，加上 stderr 无缓冲，多线程同时输出会交错。
   - `localtime()` 返回静态缓冲区，多线程并发调用时存在数据竞争。
   - 如果以后允许在运行时修改 level 或输出目标，配置字段也会有竞争。
2. **前缀和位置信息有误导**。scheduler、`on_idle` 和 idle hook 的错误都显示为 `handler:`。Lua 来源的日志，`file:line` 固定是 `src/lservice.c:263`。
3. **请求错误没有 traceback**。`resume_session` 只记录错误消息本身。
4. **部分错误被静默丢弃**。`resume_session` 只在 `from ~= nil` 时记录日志，所以经公开接口 `service.resume_session` 恢复的非 session coroutine 出错时不会留下任何记录。
5. **无法调整级别**（见 known-issues 第 5 节）。被调用方的业务错误也一律按 ERROR 输出。

## 2. skynet：日志作为服务

源码：`skynet-src/skynet_error.c`、`service-src/service_logger.c`。

- `skynet_error()` 在调用方线程格式化消息：不超过 256 字节时先写栈缓冲区再复制到堆上，更长的消息直接按需分配。然后作为 `PTYPE_TEXT` 消息发给名为 `logger` 的服务，logger 的句柄只查一次，缓存在静态变量里。
- 如果还找不到 logger（`logger == 0`），直接 `return`，日志被丢弃。
- `service_logger` 是普通服务，在自己的线程里顺序写 stdout 或文件。写文件时加时间戳（使用 `localtime_r`），每条都调用 `fflush`。
- 收到 `PTYPE_SYSTEM` 消息时 `freopen` 重新打开文件，配合 SIGHUP 和 logrotate 使用。
- 通过配置项 `logservice` 可以换成自定义的 logger 服务，包括 Lua 服务。

| 优点 | 缺点 |
| --- | --- |
| 只有一个线程写，不会交错，写日志时无需加锁 | logger 启动前的日志被丢弃 |
| 调用方只入队，不做 IO | 异步写出，崩溃时队列里的日志会丢失 |
| 出口可以完全自定义 | 没有级别 |
| 支持文件轮转 | 队列不限长度，日志刷屏时内存上涨 |
| | 依赖消息系统，消息系统出问题时日志也发不出 |

## 3. ltask：共享日志队列

源码：`src/logqueue.c`、`src/ltask.c`（`pushlog`/`poplog`）、`lualib/service.lua`、`service/logger.lua`、`service/root.lua`。

- 全局一个 `logqueue`：自旋锁保护的链表，带 freelist。
- push 时在 C 里记下 `timestamp`（来自 `timer_now`）和 `service_id`，内容是 `ltask.pack(level, message)`。
- `ltask.log.info/error` 在消息前加 `( 服务标签 )`。只有这两个级别，源头不做过滤。
- `service/logger.lua` 每 1 秒（`ltask.sleep(100)`）调用一次 `poplog` 把队列取空，用 `io.write` 输出，退出时（`S.quit`）再取空一次。
- root 遇到致命错误时会直接调用 `writelog()` 取空队列，然后退出。这是关键路径上的同步兜底。
- 另有 `debuglog`：每个调度线程一个 chunk 缓冲区，进程退出时统一写入文件。它只用于调度器调试，和业务日志无关。

| 优点 | 缺点 |
| --- | --- |
| 不经过消息系统，push 只是一次短暂的自旋锁 | 延迟最长 1 秒，崩溃时可能丢掉最近 1 秒的日志 |
| 时间戳在产生时记录，写出延迟不影响准确性 | 只在出口过滤级别 |
| 队列创建后即可记录，不依赖 logger 服务已启动 | 队列不限长度 |
| 调用方不做 IO | 关闭、重定向、接 journal 都要靠替换 logger 服务 |

## 4. 对比

| | skynet | ltask | 当前项目 |
| --- | --- | --- | --- |
| 写出方式 | 异步，经过消息系统 | 异步，独立队列，轮询取空 | 同步，各线程直接写 |
| 崩溃时 | 队列里的会丢 | 最近 1 秒内的会丢 | 不丢 |
| 启动早期 | 丢弃 | 能记录 | 能记录 |
| 是否交错 | 不会 | 不会 | **会**（bug） |
| 级别 | 无 | info/error，只在出口过滤 | 只有 error |
| 自定义出口 | 强 | 中 | 无 |
| 文件轮转 | SIGHUP 时 freopen | 无 | 无 |

## 5. 结论

本项目不适合采用 skynet 那样把日志做成服务的方案：

1. 邮箱有容量上限，`send` 在最繁忙的时候失败，日志也就丢在最需要它的时候。
2. 最关键的日志恰好出现在 service 不可用的时候：启动失败、dispatcher 崩溃、pool 关闭。
3. `bootstrap` 会回收整个 pool，日志服务也会跟着停掉。

推荐方向：

1. **核心路径保持同步**：在源头按级别过滤；在锁内把整行拼好，用一次 `write(2)` 写出；时间取 `localtime_r`。支持 text 和 journal（`<N>` 前缀）两种格式，检测到 `JOURNAL_STREAM` 时自动切换。日志落到哪里由进程外部决定，比如 shell 重定向或 systemd。
2. **以后如需高吞吐或自定义出口**，可以借鉴 ltask：
   - 一个全局 logqueue，push 时记下时间戳和 service id；
   - 由专门的 C 线程或宿主线程取空，不交给某个 service；
   - 给队列设上限，超出时丢弃并计数；
   - ERROR 及以上仍走同步路径；
   - 在 `pool_delete` 和 `atexit` 时把队列取空。
3. **如果要支持进程内写文件**，借鉴 skynet 收到 SIGHUP 时 reopen 的做法。

## 6. 运维场景

| 场景 | 做法 |
| --- | --- |
| 全局关闭 | `SERVICE_LOG_LEVEL=off`，或在宿主线程启动 service 前调用 `service.log_config { level = "off" }` |
| 重定向 | 优先在进程外完成：`2>>app.log`，或 systemd 的 `StandardError=file:...` |
| systemd/journald | stderr 默认进入 journal。输出 `<3>`/`<4>`/`<6>`/`<7>` 前缀，并去掉自带的时间戳，之后可用 `journalctl -p err` 过滤 |
| 嵌入 C/C++ 宿主 | 在 C 层暴露回调接口，接入宿主的日志系统 |

不支持把 Lua 回调作为日志出口：日志在任意 service 线程中产生，不能跨线程调用 Lua。

## 7. 落地结果（2026-10）

按第 5 节推荐方向的第 1 点实现，第 2、3 点暂不做。

- `src/log.c` 替换为自写实现，去掉 rxi/log.c：
  - 每条记录拼成一行（最长 4096 字节），一次 `write(2)` 写出，不经过 stdio；
  - 时间用 `localtime_r`；
  - level 和 format 用原子变量存储，可在任意线程修改；
  - 环境变量在 `pthread_once` 中只读一次。
- 配置分三层，后者覆盖前者：内置默认值（`info`、format 自动判断）、环境变量 `SERVICE_LOG_LEVEL` / `SERVICE_LOG_FORMAT`、`service.log_config`。环境变量按进程隔离，配置粒度是整个进程。
- journal 格式：每行带 `<N>` 前缀，不带时间戳。stderr 与 `JOURNAL_STREAM` 指向同一个流时自动启用。
- Lua 接口：`service.log.debug/info/warn/error`（带调用处的 Lua 位置）、`service.log_config`、`service._log`。`_log_error` 作为兼容别名保留。
- 来源标记改为 `[svc N]` / `[host]`，去掉统一的 `handler:` 前缀。
- 请求 handler 出错时带 traceback：调用方能收到错误的（session > 0）记为 WARN，否则记为 ERROR。
- `service.root` 的失败输出和 scheduler 的错误输出都改为走 logger，`off` 时完全没有输出。
- 测试：`tests/c/log_test.c`（多线程整行、级别、journal、截断，同时在 TSAN 下运行）和 `tests/lua/log_spec.lua`（环境变量、`log_config`、journal 自动检测）。

## 8. 性能评估：高频行情（tick）日志

需求背景：每秒几千到几万条 tick 日志。

### 8.1 实测

环境：16 核 Linux。日志内容是 `service.log.info("tick", "rb2501", 3521.5, 3522.0, i)`，每行约 120 字节。

| 场景 | 吞吐 |
| --- | --- |
| 单 service，`service.log.info`，写 `/dev/null` | 约 69 万条/秒 |
| 单 service，`string.format` 后调用 `_log`，写 `/dev/null` | 约 153 万条/秒 |
| 单 service，写本地文件 | 约 52 万条/秒（30 万行、36MB，无丢失、无交错） |
| 单 service，写 pipe（下游是 `cat`） | 约 16 万条/秒，瓶颈在消费端 |
| 4 个 service 并发写文件 | 合计约 116 万条/秒 |
| 8 个 service 并发写文件 | 合计约 88 万条/秒，80 万行全部完整 |
| `debug` 级别被过滤时 | 每次调用约 16 ns |

单条成本约 1.5 到 2 µs，主要花在 Lua 侧：`tostring`、`table.concat`、`debug.getinfo`。每秒 1 万条大约占用单核 2%。**吞吐量不是问题**，换成 spdlog 之类的 C++ 库也不会明显更快，因为瓶颈在 Lua 侧。

### 8.2 真正的风险

1. **同步写会阻塞业务线程**。每条记录都是一次 `write(2)`。磁盘抖动、pipe 消费端变慢、journald 处理不过来，都会让行情 service 线程卡住几十到几百毫秒。
2. **journald 会限流**。默认 `RateLimitIntervalSec=30s`、`RateLimitBurst=10000`，超出的日志直接丢弃。每秒几千条，几秒钟内就会触发。journald 本身也不适合承接每秒数万行。
3. **两类数据混在一起**。tick 本质上是数据落盘，和运行日志（错误、告警、状态变化）的用途、保留期、查询方式都不同。混在一起时，`journalctl -p err` 会被淹没，轮转策略也无法分别设置。

### 8.3 建议

运行日志和 tick 落盘分开：

- **运行日志**：继续使用 `service.log`，同步写，接入 journal。量小，崩溃时不丢。
- **tick 落盘**：不经过 logger，单独走带缓冲的写入路径。按改动量从小到大：
  1. 在行情 service 内直接写文件：`io.open(path, "a")`，再 `setvbuf("full", 1 << 20)`，用 timer 每 100 到 500 ms `flush` 一次，退出时也 `flush`。几乎不会阻塞，吞吐可达每秒百万条以上。崩溃时最多丢失一个 flush 周期的数据。
  2. 独立的 writer service：行情 service 把 tick 批量（例如每 100 条）`send` 过去。遇到 `MAILBOX_FULL` 时由行情侧决定是否丢弃并计数。磁盘抖动不会影响行情处理。
  3. C 层异步队列加专用写线程，队列有上限，满了丢弃并计数，即第 5 节第 2 点。确有需要时再做。

如果 tick 一定要走 `service.log`，至少把 stderr 重定向到文件（`StandardError=file:...` 或 `2>>tick.log`），不要进 journal。也可以调大 journald 的限流参数，但不推荐。

## 9. 多个来源同时写 stderr

- **本 logger 的每条记录不会被拆开**。每条记录只调用一次 `write(2)`：
  - 写 pipe 或 socket（journald）时，不超过 PIPE_BUF（4096）的写入是原子的；
  - 写普通文件时，同一进程内所有线程共享同一个打开文件描述，Linux 3.14 起 `write` 对文件偏移的更新是原子的，不会互相覆盖。
- **别人的行可能被拆开**。如果第三方代码把一行分成多次写出（多次 `fprintf`，或者 `io.stderr:write(a, b, c)` 内部的多次 `fwrite`），我们的记录可能插在它的两段之间。我们自己的行仍然完整，但它的那一行会断开。
- **格式混杂**。第三方的行没有我们的时间戳、级别和 `[svc N]` 标记。在 journal 模式下，不带 `<N>` 前缀的行按默认优先级（info）记录。日志分析工具必须能容忍格式不同的行。
- **stdout 和 stderr 是两个流**。`print` 写 stdout，重定向到文件或 pipe 时是全缓冲的，和 stderr 的先后顺序不保证。
- **共享同一个出口**。任何一个来源刷屏，都会占满同一个 pipe 或 journald 的限流额度，连带我们的日志一起阻塞或被丢弃。
- **fd 2 被别人改动**。第三方 SDK 如果 `dup2`/`freopen` 了 stderr，我们的日志会跟着去它指定的地方；如果关闭了 fd 2，之后新打开的文件可能拿到 fd 2，我们的日志就会写进那个文件。
- **对策**：
  - 第三方 SDK 尽量通过它自己的配置把日志写到独立的文件；
  - 本 logger 可以提供输出回调（`log_set_sink`），宿主可以把日志接入自己的系统；
  - 如有需要，在初始化时 `dup` 一份 fd 2 自用，避免受到后续 `dup2`/`close` 的影响。
