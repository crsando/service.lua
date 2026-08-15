# Serializer 与 Buffer Registry

> 状态：可选的后续安全增强。当前阶段信任现有 `lua-seri`、消息和
> payload 指针约定，不实施本文方案。

## 范围

serializer 在同一进程的独立 Lua VM 间复制 Lua value。它不是持久化格式，也不支持跨进程、跨机器或跨运行时版本通信。

## 支持类型

| 类型 | 支持 | 说明 |
| --- | --- | --- |
| nil | 是 | 顶层和 table value 均可 |
| boolean | 是 | false/true 独立 tag |
| number | 是 | LuaJIT number，以 binary64 编码 |
| string | 是 | 保存长度和全部二进制字节 |
| table | 是 | 支持循环和任意共享引用 |
| lightuserdata | 是 | 可信 service、同一进程生命周期 |
| 无 upvalue C function | 是 | 同一运行时二进制 |
| full userdata | 否 | 不复制资源所有权 |
| Lua closure | 否 | 不复制 bytecode/upvalue/environment |
| thread/coroutine | 否 | VM 私有执行状态 |
| 带 upvalue C closure | 否 | upvalue 不可安全复制 |

不支持类型在生成对外 buffer 前失败，不能返回部分结果。

## Buffer Header

所有 buffer 以固定 12 字节头开始：

```text
byte 0..3   4 bytes  magic = "LSR3"
byte 4      1 byte   version = 1
byte 5      1 byte   flags = 0
byte 6..7   2 bytes  reserved = 0
byte 8..11  4 bytes  payload_len, little-endian uint32
byte 12..   N bytes  payload
```

总 registry size 必须精确等于 `12 + payload_len`。decoder 在读取第一个 tag 前验证 magic、version、flags、reserved、长度上限和整数溢出。

## Value Encoding v1

payload 是零个或多个连续 value，直到 `payload_len` 精确耗尽。空 payload 表示 `pack()` 无参数。

| tag | 名称 | 内容 |
| --- | --- | --- |
| `0x00` | NIL | 无 |
| `0x01` | FALSE | 无 |
| `0x02` | TRUE | 无 |
| `0x03` | NUMBER_F64 | 8 字节 IEEE-754 binary64 little-endian |
| `0x04` | STRING | uint32 byte length，随后原始字节 |
| `0x05` | TABLE_DEF | 见下文 |
| `0x06` | TABLE_REF | uint32 object ID |
| `0x07` | LIGHTUSERDATA | uint64 地址值 |
| `0x08` | CFUNCTION | uint8 width + width 个不透明字节 |

未知 tag 必须报 `SERIALIZE_ERROR`。

### Number

- LuaJIT 2.1 使用 double number，统一保存全部 64 位对象表示。
- little-endian 转换不能依赖未对齐指针强转，使用显式字节读写或 `memcpy`。
- NaN/Infinity 作为 value 原样往返；它们不能成为非法 Lua table key。

### String

长度是 uint32，但同时受 16 MiB payload 总上限约束。decoder 在执行 `lua_pushlstring` 前验证剩余长度。

### Table

首次出现：

```text
0x05
uint32 object_id
uint32 array_len
uint32 hash_len
array_len 个 value
hash_len 组 key,value
```

再次出现：

```text
0x06
uint32 object_id
```

规则：

- object ID 从 1 单调递增，0 非法。
- encoder 第一次看到 table 时，在编码内容前登记 ID。
- decoder 读取 TABLE_DEF 后立即创建并登记 table，再解码 array/hash，因此 self-reference 可用。
- TABLE_REF 只能引用已登记 table；forward reference 非法。
- `array_len` 来自 raw array boundary，`1..array_len` 逐项编码；hash 部分排除该范围内整数 key。
- 不保存 metatable、weak mode 或迭代顺序。
- 默认不调用 `__pairs`，不在编码时执行用户代码。
- decoder 拒绝 nil/NaN key、重复 object ID、长度乘加溢出和元素上限超出。

### Lightuserdata

通过 `uintptr_t -> uint64_t` 保存地址。平台必须满足 `sizeof(uintptr_t) <= 8`；decoder 验证数值能无损转回 `uintptr_t`。该值不进入 buffer registry，不验证其指向对象生命周期。

### C function

直接把 function pointer 转为 `void *` 不满足严格 ISO C。实现应：

1. 把 `lua_CFunction` 保存到一个函数指针对象。
2. 编码 `sizeof(lua_CFunction)`。
3. 用 `memcpy` 复制该对象的字节表示，不做 function/object pointer 强转。
4. decoder 要求 width 与本进程 `sizeof(lua_CFunction)` 一致，再 `memcpy` 恢复函数指针对象。

该表示只在同一进程和相同 runtime binary 中有效。luv/其他动态库在仍有已解码 C function 时不能 `dlclose`。

## 编码限制

默认硬限制：

| 资源 | 限制 |
| --- | --- |
| 总 buffer | 16 MiB |
| table 嵌套深度 | 128 |
| table object 数 | 100000 |
| array + hash 元素数 | 1000000 |
| 单个 string | 受总 buffer 限制 |

所有计数和长度累加先检查溢出。配置只能降低默认限制；若允许提高，仍需编译期硬上限。

## Encoder 异常安全

Lua C API 可能 longjmp，不能依赖普通函数返回执行 cleanup。

可接受方案：

- 外层 binding 创建带 `__gc` 的临时 full userdata，持有 block list；成功后显式 disarm。
- 或外层用受保护的内部 C function 执行所有可能抛错的 Lua 操作，`lua_pcall` 返回后统一释放临时内存。
- allocator 失败必须转换为 Lua OOM，同时释放已经分配的 block/ref table。

编码在完整成功前不向 buffer registry 注册结果。

## Decoder 异常安全

- cursor 使用 `(base, total_size, offset)`，每次读取检查 `need <= total-offset`。
- 不信任 buffer 内部长度、object ID、count 或 tag。
- 解码临时 table 只在 Lua stack/registry 上，由 Lua error unwind 回收。
- `unpack` 获取只读 buffer pin，成功或失败都释放 pin，不释放 buffer。
- `unpack_remove` 先把 buffer 标记为 CONSUMING，受保护解码，随后无条件注销并 free，最后在需要时重新抛出解码错误。

## Buffer Registry

registry 是进程级、线程安全结构：

```text
ptr -> {
    allocation_size,
    payload_size,
    generation,
    owner_kind,
    owner_service,
    borrow_count,
    state
}
```

建议 owner/state：

```text
PACKED_LUA -> MESSAGE -> RECEIVER -> CONSUMING -> FREED
```

允许的操作：

- `pack`：分配完成后注册 PACKED_LUA。
- `unpack`：验证 owner/state/size，增加只读 borrow，结束后减少。
- `_send_message`：原子把 PACKED_LUA 转为 MESSAGE。
- receive：把 MESSAGE 转为 RECEIVER。
- `unpack_remove/remove`：转 CONSUMING，等待/拒绝 active borrow，注销并 free。
- service teardown：报告仍归该 service 且未转移的 buffer；测试模式视为失败。

未知 ptr、NULL、size 不一致、非法 owner 转移和 double free 都返回 `INVALID_BUFFER`，不能直接读取或 free。

## Fuzz 和回归

必须覆盖：

- 所有基本类型和二进制 string。
- 空表、数组、hash、混合表、holes。
- self cycle、间接 cycle、兄弟共享引用。
- 1、31、32、33、1000 个共享 object。
- 错误 magic/version/flags/reserved/length。
- 截断 number/string/table/ref/function。
- 重复/0/未来 object ID。
- depth/object/element/payload 边界。
- decode error 下 `unpack_remove` 正好 free 一次。
- 随机 bytes 在 ASan/UBSan 下不崩溃、不越界、不无限循环。
