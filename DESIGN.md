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

### 2.4 行情侧：状态事件化与启动 ✅

- 连接状态是显式的枚举 `ctp_md_t.state`（`CTPC_MD_DISCONNECTED / CONNECTED / LOGGED_IN`），
  每次变化同时作为消息入队：`OnFrontConnected`、`OnRspUserLogin`（失败时带错误码；
  `ReqUserLogin` 发不出时 libctpc 自己补一条负错误码的失败）、`OnFrontDisconnected`
  （原因码在 `rsp_info.ErrorID`）、订阅回报、`OnRspError`。
- tick 也是 `ctp_rsp_t`，和事件走同一个队列（`msgq`），保证 Lua 看到的顺序与回调一致。
  事件永不丢；tick 超过 `CTPC_MD_TICK_LIMIT` 才丢并计数。只轮询状态值做不到这一点：
  几十毫秒内断开又重连，Lua 根本看不到，也就不会重订阅。
- `S.start{ timeout }` 只有三种结局：登录成功；明确失败（登录被拒、请求发不出、本地初始化
  失败）；超时。后两种自动 stop，失败即干净。启动成功之后的断线由 CTP 重连、libctpc 重新
  登录，模板在登录事件里按订阅集合重订阅。
- 订阅集合由 Lua 维护（C 侧不再保存），启动前、断线期间的 `subscribe` 都只记入集合，登录后统一发送。
- 前置地址没有 `protocol://` 时 SDK 的 `RegisterFront` 会段错误，Lua 和 C 两层都在调用前拒绝。

### 2.5 交易侧：登录链路事件化与启动 ✅

- 与 2.4 同一模式：`ctp_trader_t.state` 为枚举（`DISCONNECTED / CONNECTED / AUTHENTICATED /
  LOGGED_IN / READY`），登录链路每一步作为消息入队，失败带错误码；链路中的请求发不出时补发
  负错误码的失败消息。删除阻塞的 `ctp_trader_wait_for_settle`。
- 交易侧改用 `msgq`，交易回报不设上限、永不丢弃。
- `S.start{ timeout }`：结算确认完成即成功；任一步失败或超时自动 stop。超时时附上启动期间
  最后一个错误（`OnRspError`、断线原因），例如 SDK 与前置不匹配的握手失败 4040。
- 启动和重连时私有流重放的委托/成交照常交给订单簿（不再在启动期间丢弃）。
- 断线时正在执行的查询立即失败；未启动时查询立即失败。
- `OnRtnOrder` 只接受本会话（FrontID+SessionID 匹配）且更大的 OrderRef，避免重放的旧订单
  把 `lst_order_ref` 拉回去造成重复引用（#11 的一部分）。

### 2.6 CTP SDK 输出改道

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
| 11 | OrderRef | `OnRtnOrder`（含 RESTART 重放）覆盖 `lst_order_ref`；Lua 在调用后读取，与 SPI 线程竞态 | 重放覆盖 ✅（2.5）；竞态留到第二轮：OrderRef 移到 Lua，报单走 `req("OrderInsert")` |
| 12 | 市价单 | 价格为 0 时用 `LastPrice` + IOC，上期所/能源中心等会拒单 | 第二轮：报单语义移到 Lua，按交易所处理 |
| 13 | `nuke` | 用 `OF_Close` 平仓，上期所/能源中心平今失败；查询失败时 `ipairs(nil)` | 第二轮 |
| 14 | 改密 | 请求发出即改缓存密码，失败后重连用错密码 | 第二轮：收到成功回报后再改 |
| 15 | 改密回报 | 不推给 Lua，用 `std::cout` 输出 | 第二轮 |
| 16 | req_id | 跨线程非原子递增 | ✅ 第一轮：`__atomic_add_fetch` |
| 17 | 登录 | `start(true)` 无超时；认证/登录/结算失败不推消息，service 线程永久阻塞 | ✅ 行情侧（2.4）、交易侧（2.5） |
| — | 只读 | `config.read_only or true` 永远为 true 且从未检查 | 第二轮 |
| — | `query_order` | 只返回第一条委托 | 第二轮 |

### C 层健壮性（第三轮）

- ✅ 队列满时静默丢消息并泄漏：两侧都改用 `msgq`；交易回报不设上限，行情 tick 有上限、事件不丢。
- ✅ 行情断线重连后不重新订阅。
- ✅ 行情心跳警告把状态置为断开。
- ✅ 订阅回报中的合约指针可能为 NULL。
- ✅ `ctp_md_stop` 不清空队列。没有 `ctp_md_free` / `ctp_trader_free`；`ctp_trader_release` 是死代码。
- `malloc` 返回值未检查（`trader.c`；`md.c`、`CustomMdSpi.cpp` ✅）。
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

- `test-c`：`ctp_rsp_t` 布局与释放、行情队列 `msgq`（均以 ASan/UBSan/LSan 编译）、
  CTP 输出改道（假 SDK + 真实 SDK）。
- `test-gen`：头文件中的 `ReqXxx` 数量与 libctpc.so 导出的包装数量一致（独立于生成器统计）。
- `test-lua`：绑定层（常量、struct 填充/转换、长度检查、默认字段、未启动时的错误码），
  trader 模板的查询队列（发送失败立即返回、超时不堵队列、迟到的超时和回报不误唤醒），
  collector 模板的启动与事件（成功、登录被拒、超时、stop、断线重连后按集合重订阅、tick 出错），
  trader 模板的启动（完整登录链路、各步失败、超时并保留原因、stop、重连后的新会话、断线时查询立即失败）。
- 真实前置：`examples/collector_smoke.lua [profile]`，启动、订阅、收 tick，再验证不可达前置的超时失败；
  `examples/trader_smoke.lua [profile]`，启动、查询资金和持仓（不下单），同样验证超时失败。
