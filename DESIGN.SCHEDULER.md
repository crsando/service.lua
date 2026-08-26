# lservice3 Scheduler 设计稿

文档状态：Draft（仅设计，不包含实现）

本文为 `lservice3.scheduler` 的第一版设计。它补充根目录
`README.md`、`DESIGN.md` 以及 `doc/` 中已有的 service、libuv 和生命周期约束；如果
实现阶段发现公开行为需要改变，应先同步这些公共文档和 contract test。

## 1. 目标和边界

调用方已经执行：

```lua
local service = require "lservice3"
service.scheduler = require "lservice3.scheduler"
```

之后可使用：

```lua
service.scheduler:at(timestamp, action)
service.scheduler:daily(time, action)
```

第一阶段的目标是：

- `at` 在一个绝对时间点执行一次函数。
- `daily` 按本地日历时间每天执行一次函数。
- 如果 deadline 因 loop 忙、线程调度或系统时钟跳变而错过，恢复运行后仍将补执行；对
  一个已注册的 `at` 任务保证最终执行一次，对 `daily` 当前 overdue 周期保证补执行一次。
- 每个 scheduler 实例只创建一个 `uv` timer，并以二叉最小堆保存待执行任务。
- 调度器只在线程所属的 Lua VM 和 libuv loop 中运行，不引入跨 service 共享状态。
- 输入错误和回调错误可见，且不因一个任务失败而泄漏 timer 或破坏后续任务。

第一阶段明确不做：

- `action` 为 table 的执行协议。table 作为未来命令/方法调度的保留扩展，当前直接拒绝。
- cron 表达式、时区参数、节假日规则和跨进程持久化。
- 强制取消正在运行的 Lua 回调。
- 多 timer、后台 scheduler 线程或一个进程级的全局 timer。

这里的“只创建唯一一个 timer”应理解为“每个 scheduler 实例最多创建一个属于其
loop 的 timer”，只约束 scheduler 模块自身。现有 `service.sleep`/`set_timeout` 等
API 仍可按各自契约创建 timer。项目的每个 service 拥有独立 Lua VM 和独立 loop，一个 timer 不能
安全地跨 service 共享；把它定义成进程级唯一会违反现有的线程归属规则。

## 2. 模块加载和对象归属

`lservice3` 不自动 `require` scheduler，因此原有程序不会因为升级而多出活跃的
timer 或改变 loop 生命周期。手动加载时，推荐使用上面的两行写法。Lua 语法
`local service.scheduler = ...` 是无效的，`service.scheduler = ...` 才是给字段赋值。
因此，仅执行 `local service = require "lservice3"` 时，`service.scheduler` 应保持
未启用（实现上可为 `nil`）；只有显式 require 并赋值后才提供调度功能。

模块返回当前 Lua VM 内的 singleton scheduler：

```lua
local scheduler = require "lservice3.scheduler"
service.scheduler = scheduler
```

同一 VM 内重复 `require` 返回同一个对象，也就共用同一个 heap 和 timer。不同
service 的 `require` 发生在不同 VM 中，模块缓存、heap、timer 和 action 引用天然隔离。
模块应通过 `require "lservice3"` 取得 service 表，但不应在加载时自动向该表写入
`scheduler`，以保持“显式启用”和可预测的副作用边界。

Lua 会把模块名中的点转换为目录分隔符；当前 Makefile 的
`LUA_PATH=./lua/?.lua;;` 因此直接支持标准模块路径：

```text
lua/lservice3/scheduler.lua
```

这样无需改变现有 `LUA_PATH` 即可解析 `require "lservice3.scheduler"`；实现阶段仍需
在 `make install` 中复制这个新文件。

在 service source 中，runtime 会自动运行该 service 的 loop，因此 scheduler callback
可以正常触发。standalone VM 没有 `service.start` 提供的后台 loop；宿主若在 standalone
中注册任务，必须自行调用与现有 luv 约定一致的 `service.uv.run()`（并负责结束 loop）。

## 3. API 契约

### 3.1 `scheduler:at(timestamp, action)`

`timestamp` 支持：

- number：Unix epoch **秒**，允许小数；不是毫秒。非有限数（包括 NaN）是错误。
- string：第一阶段支持以下 ISO 8601/RFC 3339 子集：
  `YYYY-MM-DD[T ]HH:MM:SS[.SSS](Z|+HH:MM|-HH:MM)`。
  小数部分最多三位并按毫秒解释；不带时区后缀的字符串按进程本地时区解释。
  为兼容常见配置，日期和时间之间允许空格；跨机器配置应始终带 `Z` 或显式偏移。

日期、时间、时区偏移和闰年必须严格校验，不能让 `os.time` 静默把 2 月 30 日
归一化成其他日期。第一阶段拒绝 leap second（`second == 60`）。

目标已在过去时仍然接受，并在下一个 event-loop tick 尽快执行一次；不会因为过期
而丢弃任务。相同 deadline 的任务按注册顺序执行。

“按时”不是执行保证的唯一入口：如果 timer 没有在 deadline 的瞬间获得 loop 调度，
下一次 callback 会把 `deadline_ms <= now_ms` 的任务识别为 overdue 并补执行。只要进程、
service loop 和 scheduler 仍然存活，每个 `at` 注册任务都不会因一次 timer 延迟而丢失，
且不会重复执行。进程已经退出、service 被停止或底层 loop 永久不再运行时，不承诺跨进程
恢复执行。

### 3.2 `scheduler:daily(time, action)`

`time` 支持：

- table：`{ hour = 8, minute = 5, second = 1 }`。`hour` 必填，`minute` 和
  `second` 缺省为 0；三个字段必须是整数，范围分别为 `0..23`、`0..59`、`0..59`。
- string：严格的 `HH:MM:SS`，小时、分钟、秒都必须是两位十进制数字，不带时区。

daily 使用运行该 service 的进程本地时区。注册时若当天的时间已经到达（包括
恰好相等），第一次执行安排在下一天；否则安排在今天。每次执行后依据执行完成时
的本地日历计算下一个日期，而不是简单加 `24 * 60 * 60` 秒。这样可以遵循夏令时
转换；遇到本地时区的重复或不存在时间时，行为遵循平台 `os.time` 的时区规则，
跨时区业务应使用 `at` 加显式偏移。

如果 scheduler 在多个日历周期内没有获得运行机会，恢复时只补执行当前 overdue 的
一次，然后从恢复时刻计算下一个未来日期，不对历史日期进行无界追赶。这样既满足
“错过后仍补一次”的要求，也避免 loop 恢复后执行数量失控；若业务需要逐日补账，
应在 action 中自行记录业务日期并另行处理。

第一阶段建议成功返回一个不透明的 task token，便于日志和未来增加取消接口；token
不承诺可直接访问内部字段。若实现暂不提供取消，至少应保持返回值稳定（推荐返回
token，而不是依赖 `nil` 表示成功）。重复注册相同时间和函数是合法的独立任务。

所有参数错误使用 Lua error（建议 `error(..., 2)`），错误文本至少区分 timestamp、
daily time 和 action。`action` 不是 function（包括 table）时应报明确错误，例如
`scheduler action table is not supported yet`。

## 4. 时间和时钟模型

绝对时间和等待时钟必须分开：

1. 任务 deadline 统一保存为 Unix epoch 毫秒。
2. 当前 wall clock 通过 `service.uv.gettimeofday()` 的 `(seconds, useconds)`
   计算，避免只用 `os.time()` 带来的整秒误差。
3. timer 的等待由 libuv 的单调时钟实现。每次 arm 时计算
   `delay = max(0, deadline - wall_now)`，并向上取整到毫秒，避免提前触发。
4. timer callback 再次读取 wall clock，并以读取结果判断是否 due；不能仅凭 timer
   callback 被唤醒就执行任务。

wall clock 可能被 NTP、管理员或夏令时修改。为此，timer 的一次等待应限制在一个
内部的最大重检间隔（建议 60 秒）以内：远期任务也会由同一个 timer 周期性重算，
从而能在时钟回拨后修正等待。时钟前跳时，任务会在下一次 callback 中作为 overdue
任务执行；调度器不尝试伪造历史上错过的多次 daily 回调。

`uv.gettimeofday` 不可用或返回非法值属于 scheduler 初始化/运行时错误，不应回退到
与本地时区含义不同的隐式时间源。目标 delay 超过底层 timer 可表达范围时，按最大
可等待区间分段重检，不能溢出为负数或立即忙循环。

## 5. 数据结构和唯一 timer

模块私有状态建议如下：

```text
heap:        array of task entries, 1-based binary min-heap
sequence:    monotonically increasing tie-breaker
timer:       lazily-created luv timer, at most one per module instance
timer_armed: whether timer is currently started
running:     reentrancy guard while draining due tasks
```

task entry 至少包含：

```text
deadline_ms   -- epoch milliseconds
sequence      -- 相同 deadline 时的注册顺序
kind          -- "at" 或 "daily"
action        -- Lua function
daily_spec    -- daily 的 hour/minute/second；at 任务为空
```

比较键为 `(deadline_ms, sequence)`。插入和弹出均为 `O(log n)`，查看最早任务为
`O(1)`；禁止每次注册都对整个任务表 `table.sort`。

timer 应在第一次成功注册任务时懒创建。heap 为空时只 `stop` timer，保留该 userdata
以便后续复用并保证不会创建第二个 timer；停止状态的 timer 不会作为活跃 handle 让
libuv loop 保持运行。service teardown 时，现有生命周期代码通过 luv 的统一 close
流程关闭这个 timer。若 timer 已进入 closing/closed，新的注册应报错而不是重新创建
第二个 timer；停止后的 scheduler 不保证可以继续使用。

arm 逻辑：

1. heap 为空：`timer:stop()`，清除 `timer_armed`。
2. heap 非空：取 root，读取当前 wall clock。
3. delay 取 root 剩余时间和最大重检间隔的较小值，调用同一 timer 的
   `start(delay, 0, on_timer)`；重复 start 前先 stop 或使用 luv 明确支持的重启语义。

调度 API 和 timer callback 都在同一 service 线程执行，因此 heap 不需要额外锁。不得
从其他线程直接调用 scheduler；这也符合 Lua VM 和普通 luv handle 的线程归属约束。

scheduler 的 singleton 绑定其首次使用时的 `service` 上下文和 `service.uv` loop。实际
service VM 只会在 source 初始化时调用一次 `service.input(...)`，因此不会发生切换。
standalone 宿主若反复调用 `service.input()` 或尝试把同一个 scheduler 用到不同 loop，
实现应检测到上下文变化并报错，不能让旧 heap 中的 action 跑到新 loop；需要新上下文
时应使用新的 Lua VM，或由后续 API 提供显式 constructor。

## 6. 触发和重入算法

推荐的 timer callback 逻辑如下（伪代码）：

```text
on_timer:
    timer_armed = false
    update uv cached time if needed
    now = wall_now_ms()
    processed = 0

    while heap.root exists and heap.root.deadline_ms <= now
          and processed < MAX_TASKS_PER_TICK:
        task = heap_pop()             -- 先摘除，保证 at 只执行一次
        invoke_protected(task.action)
        if task.kind == daily:
            now_after_action = wall_now_ms()
            task.deadline_ms = next_local_calendar_day(task.daily_spec,
                                                       now_after_action)
            heap_push(task)
        processed = processed + 1
        now = wall_now_ms()

    arm_timer()
```

`MAX_TASKS_PER_TICK` 建议采用与 dispatcher 相近的固定上限（例如 256）。大量过期
任务时达到上限后，以同一个 timer、delay 为 0 的下一轮继续处理，给 inbox、socket
和其他 luv callback 留出机会。每个 action 调用前从 heap 移除，因此 action 内调用
`scheduler:at`/`:daily` 是安全的；最终 `arm_timer` 以最新 heap 为准，能够发现刚
注册的更早任务。

daily 回调即使抛错也要重新计算并重新入堆，错误不会自动取消每日任务。若 action
注册了一个过去的 at 任务，当前 drain 循环可以继续处理它，但仍受每轮上限约束。

`running` 只用于防止实现中的显式递归调用或错误的重复 callback；Lua 本身不会在
同一个 VM 中并发执行两个 callback。回调过程中不应调用 `service.call`、`service.sleep`
或 `coroutine.yield`，因为 timer callback 不是 runtime 管理的 request coroutine；
需要异步工作时应由 action 投递消息或自行安排后续任务。

## 7. 回调错误、日志和停止

action 应通过 `xpcall(action, debug.traceback)` 保护执行：

- at action 出错：记录一次错误并丢弃该 task，不重试。
- daily action 出错：记录一次错误，仍保留下一次 daily 任务。
- 错误不得从 luv callback 未保护地抛出，避免破坏 dispatcher 或跳过 timer rearm。

service 上下文优先使用现有的 `_log_error`，并带 service id 和 scheduler 标识；
standalone 上下文没有 `service.self`，应使用明确的 stderr/宿主 logger 适配层，而不
伪造 native service pointer。第一阶段不把 action 的错误作为另一个 service 的 RPC
response，也不自动终止 service。未来可以增加 `scheduler.on_error`，但不应让业务
错误默认改变 service 生命周期。

调度器不新增 stop hook。service 的标准 stop 流程会关闭所有 luv handle，因此：

- stop 之后尚未触发的 at/daily action 不再执行；
- 不恢复、取消或伪造挂起的 scheduler coroutine（第一阶段本来不创建 coroutine）；
- action 不应在 `service.quit()` 之后假设还能重新注册任务。

## 8. 测试和验收标准

实现阶段至少应增加独立的 scheduler 测试，不把它隐含在已有 RPC 测试中：

### 解析和 API

- Unix epoch number、带毫秒的小数和过期时间。
- RFC3339 的 `Z`、正负偏移、空格/T 分隔符以及无时区本地形式。
- 非法日期、闰年边界、非法时分秒、非法偏移、NaN/Inf 和错误类型。
- daily table 默认值、范围检查，以及严格 `HH:MM:SS` 字符串。
- function action 成功；table、nil 和其他类型被明确拒绝。

### Heap 和 timer

- deadline 顺序、相同 deadline 的 FIFO、重复注册。
- 新注册的更早任务能重排同一个 timer。
- 过去任务、同一 callback 中新增任务和大量 overdue 任务。
- 对 `service.uv.new_timer` 做计数替身，证明一个 scheduler 实例整个生命周期最多
  创建一个 timer；heap 清空后重新注册也不能创建第二个。
- at 只执行一次；daily 跨天重排一次且不因 action 耗时产生追赶风暴。

### Loop、公平性和生命周期

- inbox 高负载时 timer 仍能获得运行机会，`MAX_TASKS_PER_TICK` 不会无限霸占 loop。
- action 抛错后后续 at/daily 仍执行，timer 未泄漏。
- service stop/join 时 scheduler timer 被统一关闭，`uv_loop_close` 不返回 `UV_EBUSY`。
- 每个 service 加载 scheduler 后，timer/heap/action 不会跨 VM 或跨 loop 互相影响。

## 9. 待实现前需要确认的选择

本稿的推荐选择是：

1. `at` 数字单位为 epoch 秒；字符串无时区时按本地时区，但文档建议生产配置带显式偏移。
2. `daily` 使用进程本地时区，按日历而不是固定 86400 秒重排。
3. action 错误隔离并记录，不重试 at、不取消 daily。
4. API 返回不透明 task token，为未来 `cancel` 留出兼容空间；第一阶段不承诺 token
   的具体字段或取消方法。
5. timer 懒创建、停止后复用、service teardown 统一关闭；“唯一”按 scheduler/VM
   解释，而非进程全局。

如果业务实际要求所有机器使用同一时区、需要毫秒以下精度、或希望回调能够 yield，
这些都将改变公开契约，应在实现前单独决策，而不是在 Lua 文件中隐式处理。
