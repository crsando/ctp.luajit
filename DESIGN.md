# ctp.luajit 设计与改进路线

> 本项目由 `ctpc2`（Lua 模块 `lctp2`）重组而来，不保留其 git 历史。
> 本文记录整体设计、已知问题和分轮改进计划。已完成的条目以 ✅ 标注。

## 1. 定位与分层

基于上期 CTP 接口、以 LuaJIT 为主力语言的个人期货交易基础设施：行情采集（collector）、
交易下单/查询（trader），并在 service.lua 的 actor 框架上构建应用。

```
应用（examples/、其他项目）            基于 service.lua 的 service
lua/ctp/templates/                     collector / trader：查询队列、订单簿、协程挂起/唤醒
lua/ctp/init.lua                       FFI 绑定：trader:req()、struct 填充与转换
build/<ver>/cdefs.lua                  生成：cdef、常量、struct 布局、请求名 → 结构体名
src/ + 生成的 ctpc_req.cpp             libctpc.so：Spi 回调 → 队列 → uv_async 唤醒；ReqXxx 包装
lib/<CTP_VER>/                         CTP SDK
```

### 数据流

1. CTP 回调线程中，`OnRtnXxx/OnRspXxx` 把参数复制进一条 `ctp_rsp_t`（一次分配），推入队列，
   再 `uv_async_send` 唤醒 Lua 侧 libuv loop。见 [docs/ctp_rsp.md](docs/ctp_rsp.md)。
2. Lua 服务在 `on_idle` 中非阻塞地取空队列，按 `cdefs.lua` 的 struct 布局转成 table。
3. 查询：入队 → 1 次/秒 流控 → `trader:req()` → 按 `req_id` 收集 → `is_last` 时恢复协程。
4. 下单：用 FrontID+SessionID+OrderRef 生成 key，`OnRtnOrder/OnRtnTrade` 更新状态，到终态时恢复协程。

## 2. 关键设计决定

### 2.1 请求：生成的底层 + Lua 上层 ✅

- C 层不为请求起名字，也不手写请求函数。`tools/gen.lua` 从 `ThostFtdcTraderApi.h` 为每个
  `ReqXxx` 生成强类型包装 `ctp_trader_ReqXxx(t, struct Field *)`，统一处理：请求号原子递增、
  检查 CTP 返回值（-1/-2/-3）、未启动时返回 `CTPC_E_NOT_STARTED`。
- 请求名保持 CTP 原名，与回报 `OnRspXxx` 一一对应，通用的请求管理器只需按
  `"OnRsp" .. name` 和 req_id 配对。
- Lua 的 `trader:req(name, fields)` 构造结构体、填默认字段（BrokerID/InvestorID）、检查长度；
  语义化的名字（`S.query_account`）和策略（市价/限价、开平）只在模板这一层。
- 选强类型函数而不是 `void *` + 名字分派：FFI 会检查结构体类型；SDK 版本差异在编译期确定。
- 生成器遇到不认识的请求签名、typedef 或字段直接失败，新 SDK 不会悄悄丢掉请求或字段。

### 2.2 cdef 在构建期生成，与库绑定 ✅

- 不再在运行时用正则解析安装目录下的头文件。`cdefs.lua` 与 `libctpc.so` 由同一次构建产生，
  装在同一个版本目录；`ctpc_build_info()`（SDK 版本 + cdef 文本哈希）与 `cdefs.lua` 不一致时，
  `require "ctp"` 直接报错，避免结构体布局静默错位。

### 2.3 私有安装目录 ✅

- `lib/ctp.luajit/<CTP_VER>/` 存放 libctpc.so 和对应 SDK 库，多个 SDK 版本可并存，不往
  `/usr/local/lib` 放任何 `libthost*.so`。Lua 按绝对路径 `ffi.load`，不依赖动态链接器搜索路径。

### 2.4 CTP SDK 输出改道

见 README 特别提示和 [docs/logging.md](docs/logging.md)。

## 3. 已知问题

编号沿用审阅时的编号，便于对照。

### 交易正确性

| # | 位置 | 问题 | 计划 |
|---|---|---|---|
| 4 | C 请求宏 | 不检查 `ReqXxx` 返回值，请求没发出也返回 req_id | ✅ 第一轮：生成的包装返回负数，查询立即失败 |
| 5 | 查询超时 | 超时回调不取消，可能唤醒同一协程之后在等的别的事 | ✅ 第一轮：每个请求只结束一次（`done`） |
| 6 | 查询超时 | 超时后条目不出队，后续查询全部阻塞 | ✅ 第一轮：结束时出队，已结束的条目跳过 |
| 7 | 查询发送 | `pcall` 失败时 req_id 被赋成错误字符串，队列阻塞 | ✅ 第一轮：参数错误时请求立即失败 |
| 8 | 订单终态 | 只在 `OnRtnTrade` 判断全成，`OnRtnOrder(AllTraded)` 晚到时订单永不结束 | 第二轮 |
| 9 | 撤单回报 | `OnRspOrderAction` 回显 FrontID/SessionID=0，生成垃圾 key，撤单失败不通知原订单 | 第二轮 |
| 10 | 超时撤单 | OrderSysID 可能为空；定时器不取消；`_status` 无后续处理 | 第二轮 |
| 11 | OrderRef | `OnRtnOrder`（含 RESTART 重放）覆盖 `lst_order_ref`；Lua 在调用后读取，与 SPI 线程竞态 | 第二轮：OrderRef 移到 Lua，报单走 `req("OrderInsert")` |
| 12 | 市价单 | 价格为 0 时用 `LastPrice` + IOC，上期所/能源中心等会拒单 | 第二轮：报单语义移到 Lua，按交易所处理 |
| 13 | `nuke` | 用 `OF_Close` 平仓，上期所/能源中心平今失败；查询失败时 `ipairs(nil)` | 第二轮 |
| 14 | 改密 | 请求发出即改缓存密码，失败后重连用错密码 | 第二轮：收到成功回报后再改 |
| 15 | 改密回报 | 不推给 Lua，用 `std::cout` 输出 | 第二轮 |
| 16 | req_id | 跨线程非原子递增 | ✅ 第一轮：`__atomic_add_fetch` |
| 17 | 登录 | `start(true)` 无超时；认证/登录/结算失败不推消息，service 线程永久阻塞 | 第二轮：状态迁移作为消息推给 Lua |
| — | 只读 | `config.read_only or true` 永远为 true 且从未检查 | 第二轮 |
| — | `query_order` | 只返回第一条委托 | 第二轮 |

### C 层健壮性（第三轮）

- 队列满（容量 1023）时静默丢消息并泄漏。交易侧改为无界、永不丢；行情侧有界，丢最旧并计数报警。
- 行情断线重连后不重新订阅（`subscribed` 集合已在维护）。
- 行情心跳警告把 `connected` 置 0。
- 订阅回报中的合约指针可能为 NULL。
- `ctp_md_stop` 不清空 tick 队列；没有 `ctp_md_free` / `ctp_trader_free`；`ctp_trader_release` 是死代码。
- `malloc` 返回值未检查（`md.c`、`trader.c`、`CustomMdSpi.cpp`）。
- C 侧 `strcpy` 无长度检查（Lua 入口已在第一轮检查，C 接口本身仍未防护）。
- `hook_write`：进程关闭 fd 1/2 后，socket 复用该编号时 SDK 的写会被吞进日志。
- 回报一侧（`CUSTOM_ON` 列表）也改为生成，覆盖全部 `OnRsp*` / `OnRtn*`。

### Lua 层与模板

- `trader` 模板 `on_idle` 中处理函数出错会中断整轮消息处理；`collector` 的 `pcall` 吞掉错误不记日志。
- 每个 tick 都 `totable` 全部字段；GBK 只在两处转换。
- 模板仍在 require 时产生副作用，不能注入 fake trader（目前测试靠替换实例方法）。

### 应用层

- 风控闸门：只读开关、单笔最大手数、最大持仓、价格偏离、合约白名单，所有下单入口都必须经过。
- 旧 demo 的 gateway 监听 `0.0.0.0` 且无鉴权，`debug` 命令可远程下单；未迁移到本仓库，
  以后的网络入口必须只听本机或带鉴权，并经过风控闸门。

## 4. 推进顺序

1. ✅ **第一轮：重组与代码生成**：新仓库与改名、私有安装目录、ABI 校验、请求生成器、
   `trader:req()`、查询改用 CTP 原名并在发送失败时立即返回、离线测试。
2. **第二轮：交易正确性**：查询管理器（请求与回报按名字配对、超时可取消）、订单状态机、
   报单语义和 OrderRef 移到 Lua、登录状态推送与 `start` 超时、改密回报。
3. **第三轮：C 层健壮性**：上面"C 层健壮性"一节。
4. 风控闸门，之后才考虑网络入口。

## 5. 测试

`make test`：

- `test-c`：`ctp_rsp_t` 布局与释放（ASan/UBSan/LSan）、CTP 输出改道（假 SDK + 真实 SDK）。
- `test-gen`：头文件中的 `ReqXxx` 数量与 libctpc.so 导出的包装数量一致（独立于生成器统计）。
- `test-lua`：绑定层（常量、struct 填充/转换、长度检查、默认字段、未启动时的错误码），
  以及 trader 模板的查询队列（发送失败立即返回、超时不堵队列、迟到的超时和回报不误唤醒）。
