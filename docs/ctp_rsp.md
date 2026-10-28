# ctp_rsp_t 的生命周期

`ctp_rsp_t` 是交易侧（trader）从 CTP 回调线程传给 Lua 的消息。行情侧（md）的 tick
走另一条更简单的路径，不在本文范围内。

## 一句话

**CTP 回调线程分配，经队列转交，在 Lua 线程释放；一条消息只有一块内存，只 `free`
一次。** 所有权在任一时刻只属于一方：回调线程 → 队列 → 取出它的人。

```text
 CTP 回调线程                         队列                      Lua（service 线程）
 ────────────                        ────                      ──────────────────
 OnRspXxx / OnRtnXxx
   └ send_rsp
       └ ctp_rsp_new   ── 分配 ──┐
   └ ctp_trader_send   ── 入队 ──┼──> [ ctp_rsp_t * ... ] ──> ctp_trader_recv  ── 出队
       └ uv_async_send ── 唤醒 ──┘                              └ cast_trader_rsp ── 复制成 Lua table
                                                               └ ctp_rsp_free    ── 释放
                                                               └ R[func_name] / query:update(table)
```

## 内存布局

`ctp_rsp_new`（`src/trader.c`）用一次 `calloc` 分配整块内存，回调参数紧跟在头部之后：

```text
┌──────────────────────┬─────┬──────────────────────┬─────┬──────────────────────┐
│ ctp_rsp_t（头部）    │ pad │ field（size 字节）   │ pad │ rsp_info             │
│ func_name/field_name │     │ 例如 CThostFtdc-     │     │ CThostFtdcRspInfo-   │
│ req_id/is_last/...   │     │ OrderField 的副本    │     │ Field 的副本         │
│ field ───────────────┼─────┼─>                    │     │                      │
│ rsp_info ────────────┼─────┼──────────────────────┼─────┼─>                    │
└──────────────────────┴─────┴──────────────────────┴─────┴──────────────────────┘
```

- `field`、`rsp_info` 仍是指针，只是指向同一块内存内部；对应参数为 NULL 时指针为 NULL，
  不占空间。两段都按 `max_align_t` 对齐，与 `malloc` 的返回值一致。
- `func_name`、`field_name`、`desc` 是定长 `char` 数组，用 `snprintf` 写入，过长截断。
- 因此 `ctp_rsp_free` 只是一次 `free(r)`。**不要单独释放 `r->field` 或 `r->rsp_info`。**

`ctp_rsp_t` 的结构体布局与 Lua 侧 `ffi.cdef` 加载的 `cdefs.lua`（由 `tools/gen.lua` 从 `ctpc.h` 生成）一致，Lua 通过
`rsp.field` / `rsp.rsp_info` 指针读取，不关心它们是否在同一块内存。

## 1. 创建：CTP 回调线程

CTP 的回调在 SDK 自己的线程里执行，回调参数只在回调期间有效，所以必须立刻复制一份。
`src/CustomTradeSpi.cpp` 里所有需要通知 Lua 的回调都经 `send_rsp` → `ctp_rsp_new`：

| 回调 | `req_id` | `field` | `rsp_info` |
| --- | --- | --- | --- |
| `OnRspQryTradingAccount` / `QryInvestorPosition` / `QryInstrument` / `QryInstrumentMarginRate` / `QryOrder` | 请求的 req_id | 对应结构体 | 有则复制 |
| `OnRspOrderInsert` / `OnRspOrderAction` | 请求的 req_id | 对应结构体 | 有则复制 |
| `OnRspSettlementInfoConfirm` / `OnRspUserLogout` | 请求的 req_id | 对应结构体 | 有则复制 |
| `OnRtnOrder` / `OnRtnTrade`（`ON_RSP_THEN_SEND_COMPACT`） | `-1`，`is_last = true` | 对应结构体 | 无 |
| `OnRspError` | 请求的 req_id | 无 | 有则复制 |
| `OnFrontDisconnected` | `-1`，`is_last = true` | 无 | 无 |

`OnFrontConnected`、`OnRspAuthenticate`、`OnRspUserLogin`、`OnRspUserPasswordUpdate`、
`OnHeartBeatWarning` 不产生消息，只更新 `connected` 或写日志。

分配失败时 `send_rsp` 记一条 `error` 日志并丢弃这条回调，不会崩溃。

## 2. 入队：`ctp_trader_send`

`ctp_trader_send`（`src/trader.c`）在 `cond` 的锁内把指针放进队列，通知可能阻塞在
`recv` 上的线程，然后在锁外调用 `uv_async_send` 唤醒该 service 的 libuv 循环。
入队成功后，所有权交给队列，回调线程不再碰这条消息。

> ⚠️ **当前缺陷（架构评估 #8，待修）**：队列容量固定 1024，满时 `queue_push_ptr` 返回
> 失败但没有人检查，这条消息既没进队列也没被释放——**被静默丢弃并泄漏**。

## 3. 出队与释放：Lua 线程

正常路径是 `ctp` 的 `trader:recv(false)`（`lua/ctp/init.lua`），由模板的
`service.on_idle` 循环调用，直到队列为空：

1. `ctp_trader_recv` 在锁内取出指针，所有权转给调用方；
2. `cast_trader_rsp` 把 `field` / `rsp_info` 按头文件元数据**逐字段复制**成 Lua table，
   字符串用 `ffi.string` 复制；
3. 立即 `ctp_rsp_free`。此后 Lua 拿到的只是普通 table，不再引用 C 内存；
4. 模板按 `func_name` 分发：`R.OnRtnOrder` 等进入订单簿，其余进入 `query:update`。

所以一条消息在 Lua 线程上从出队到释放只跨越 `recv` 这一个函数调用。

## 4. 其他出口

| 出口 | 位置 | 说明 |
| --- | --- | --- |
| 启动时丢弃 | `ctp_trader_wait_for_settle`（`trader:start(true)`） | 阻塞等到结算确认完成，期间收到的消息逐条取出并释放 |
| 停止时清空 | `ctp_trader_stop` → `ctp_trader_drain` | `Release()` 返回后不再有回调，队列里剩余的都属于刚结束的会话，全部释放 |
| 原始接口 | `trader:recv_raw()` | 直接返回 `ctp_rsp_t *`，**由调用方负责 `ctp_rsp_free`**；目前没有代码使用 |
| 队列满 | `ctp_trader_send` | 见上面的缺陷：丢弃并泄漏 |
| 进程退出 | — | 队列中尚未取出的消息不释放，由操作系统回收 |

## 测试

`tests/c/ctp_rsp_test.c`（`make test`，以 ASan + UBSan + LeakSanitizer 编译）覆盖布局与
内容、空 `field` / `rsp_info`、名字截断、`ctp_trader_drain`；任何越界或漏释放都会让测试
失败。
