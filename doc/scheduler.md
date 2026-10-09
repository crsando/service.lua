# 调度器 `service.scheduler`

一个可选模块，提供按绝对时间执行的一次性任务和每日定时任务。不使用时不会被加载。

```lua
local service = require "service"
service.scheduler = require "service.scheduler"   -- 挂到约定的位置，便于其他模块复用

service.scheduler:at(os.time() + 10, function()
    print("约 10 秒后执行")
end)

service.scheduler:at("2026-10-10T09:00:00+08:00", function() end)

service.scheduler:daily("08:05:01", function()
    service.send(service.get_id(), "daily_report")   -- 需要 call 时先转成消息
end)
```

完整示例见 `examples/scheduler.lua`。

## API

### `scheduler:at(timestamp, action) -> token`

`timestamp` 可以是以下几种形式：

| 形式 | 示例 | 时区 |
| --- | --- | --- |
| 数字：Unix epoch 秒，可以带小数 | `os.time() + 10` | 与时区无关 |
| 带 `Z` 或 `±HH:MM` 的日期时间 | `2026-10-10T01:00:00Z`、`2026-10-10 09:00:00.250+08:00` | 使用显式指定的时区 |
| 不带时区的日期时间 | `2026-10-10T09:00:00` | 进程本地时区。不存在的本地时间（例如夏令时跳过的时刻）会报错 |

日期和时间之间可以用 `T` 或空格分隔。秒的小数部分最多 3 位。

### `scheduler:daily(time, action) -> token`

`time` 可以是 `"HH:MM:SS"`，也可以是 `{ hour = 8, minute = 5, second = 1 }`（`minute` 和 `second` 缺省为 0）。按进程本地日历计算每天的触发时刻，执行完后自动安排下一次。

### 参数约束

- 必须用冒号调用：`scheduler:at(...)`。
- `action` 只能是函数。传入 table 会报错，这是为将来扩展预留的。
- 返回的 token 目前只用于标识任务，**还没有取消接口**。

## 语义

- **单例**：每个 VM 只有一个调度器，所有任务放在一个最小堆中，由同一个 luv timer 驱动。调度器第一次使用时会绑定到当前 service，不能跨 service 复用。
- **补执行**：loop 繁忙导致错过触发时间的任务，会在下次检查时补执行一次，不会重复补多次。每日任务补执行后，从当前时刻开始计算下一次触发时间。
- **检查间隔**：timer 单次等待最长 60 秒，因此系统时钟跳变后，最多 60 秒内会重新校准。
- **单轮上限**：一次 timer 回调最多执行 256 个到期任务，剩余任务留到下一轮。
- **错误隔离**：任务抛出的错误会带 traceback 写入日志，不影响其他任务，也不会停止 service。
- **执行上下文**：任务在 timer 回调中执行，不在请求 coroutine 中，因此**不能调用 `call` 或 `sleep`**。
- **不持久化**：service 停止或进程退出后，未执行的任务全部丢失。
