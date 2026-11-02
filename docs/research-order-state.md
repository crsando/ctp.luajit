# 国内 CTP 框架的订单状态机与回报处理调研

> 2026-11-02 调研。目的：为 ctp.luajit 第二轮"交易正确性"（DESIGN.md §3 #8–#13）重写订单状态机提供依据。
> 全部结论来自直接阅读源码（master/main 分支，2026-11-02 拉取）和社区文档；标 **未验证** 的条目没有找到一手资料或没有实测。

## 0. 结论速览

1. **订单身份要两把钥匙。** 下单时用 `FrontID+SessionID+OrderRef`；交易所接受后，再补一个以 `ExchangeID+OrderSysID` 为键的索引。`OnRtnTrade` 不带 FrontID 和 SessionID，只能用后一把钥匙关联到订单。
   被调研的项目里，vn.py、ctpbee、WonderTrader 的索引键都**没带 ExchangeID**。
2. **成交必须去重。** 去重键是 `ExchangeID+TradeID+Direction`。
   - 用 `THOST_TERT_RESTART` 订阅时，每次登录都会回放当天全部委托和成交。
   - vn.py、ctpbee 网关层都不去重；WonderTrader 不去重，而且会重复累加持仓；Kungfu 也不按 TradeID 去重。
   - **ctp.luajit 现在用的就是 RESTART，也没有去重。**
3. **找不到订单的成交要先缓存，不能丢，也不能崩。**
   - ctpbee、vn.py 会抛 `KeyError`。
   - Kungfu 只打日志就丢掉。
   - WonderTrader 会把成交记到 `localid=0` 上，在途量从此对不上。
4. **订单终态只能结束一次，不能回退。** 终态有三种：全部成交、已撤单、拒单。
   - `OnRtnOrder(AllTraded)` 通常比对应的 `OnRtnTrade` **先到**。
   - vn.py 的 OMS 曾出现 SUBMITTING 覆盖 REJECTED 的问题（vnpy_ctp#104），修复办法是加锁保证入队顺序。但 OMS 本身至今仍没有"终态不可回退"的保护。
5. **拒单有三条通道，要分清。**
   - `OnRspOrderInsert`：只发给下单的那个会话。
   - `OnErrRtnOrderInsert`：发给该账户的所有会话。
   - `OnRtnOrder` 里 `OrderSubmitStatus=InsertRejected` 且 `OrderStatus=Canceled`：交易所拒单，原因写在 `StatusMsg`。
   - 只有 vn.py 把第三种识别成拒单，其他项目都当成普通撤单。**被调研的项目没有一个完整实现 `OnErrRtn*` 两个回调。**
6. **撤单失败不能改变订单状态**，只通知"这次撤单失败了"。订单最终的状态仍以 `OnRtnOrder` 和 `OnRtnTrade` 为准。
7. **OrderRef 从登录返回的 `MaxOrderRef` 开始，在本进程里原子递增。** 发单前就分配好，不要等发单后再读共享变量。WonderTrader 和 Kungfu 是这样做的。
8. **平今平昨、市价单按交易所区分。**
   - 上期所和上期能源（INE）：`'1'`（Close）只平昨仓，平今仓必须用 `'3'`（CloseToday）；这两个交易所也不支持市价单。
   - 其他交易所的市价单规则各不相同（见 §5.5）。

---

## 1. 调研对象

| 项目 | 语言 | 读了哪些源码 | 备注 |
|---|---|---|---|
| vn.py / vnpy_ctp | Python + pybind C++ | `vnpy_ctp/gateway/ctp_gateway.py`；`vnpy/trader/{engine,object,constant,converter}.py` | 国内用户最多。最近一次相关提交是 `e956be01`（2026-10-05） |
| WonderTrader | C++ | `src/TraderCTP/TraderCTP.cpp/.h`、`src/WtCore/TraderAdapter.cpp`、`ActionPolicyMgr.cpp`、`WtKVCache.hpp` | 风控和开平策略做得最完整 |
| ctpbee | Python | `ctpbee/interface/ctp/td_api.py`、`lib.py` | 结构和 vn.py 很像，但少了好几处修复 |
| Kungfu（功夫） | C++ | 官方提交 `e4fd6b3`（2019）中的 `extensions/ctp/src/td_gateway.cpp`、`order_mapper.h`、`type_convert_ctp.h`；第三方 2.1.2 镜像中的 `trader_ctp.cpp` | 官方 v4 主干里找不到 CTP 源码 |
| paulran/kungfu-cpp | C++ | `brokers/ctp/src/trader_ctp.cpp` | 第三方 fork，有几处值得参考 |
| 社区文档 | — | 知乎 p/663816962、p/133428468、p/668722082、p/1548276305；CSDN wowotuo；CTP `error.xml`；`ThostFtdcTraderApi.h` | 回调语义与交易所规则 |

openctp 的 FAQ 没有找到可以阅读的原文；tqsdk 的开源部分不含 CTP SPI 代码，因此这两个项目都没有纳入。

---

## 2. CTP 回报语义（各框架共同面对的问题）

### 2.1 一笔正常报单的回调顺序

1. `ReqOrderInsert` 通过柜台校验后，**所有在线会话**都会收到第一条 `OnRtnOrder`，内容为：
   - `OrderStatus = Unknown('a')`
   - `OrderSubmitStatus = InsertSubmitted('0')`
   - `OrderSysID` 为空
2. 交易所接受后，收到 `OnRtnOrder(NoTradeQueueing '3')`，此时带上了 `OrderSysID`。
   如果报单一进交易所就成交，这一步会被省略，直接收到 `PartTradedQueueing('1')` 或 `AllTraded('0')`。
3. 每一笔成交对应一条 `OnRtnTrade`。

**OnRtnOrder 和 OnRtnTrade 谁先到**
- 上期所等交易所：同一笔成交，会先收到一条 OnRtnOrder（状态还没更新）、再收到一条 OnRtnOrder（状态已更新），然后才是 OnRtnTrade。
- 大商所：只推一次成交通知，客户端只收到一条 OnRtnOrder。
- CTP 手册给出的顺序是：`OnRtnOrder(未成交) → OnRtnOrder(全部成交) → OnRtnTrade`。

由此得到两个推论：
- **`OnRtnOrder(AllTraded)` 正常情况下会先于最后一笔 `OnRtnTrade` 到达。** 所以订单进入 AllTraded 时，`VolumeTraded` 可能比已经收到的成交笔数多。
- 官方建议成交量和持仓**以 `OnRtnTrade` 累计为准**，因为 CTP 后台本身就是按成交回报更新持仓的。

（来源：https://zhuanlan.zhihu.com/p/663816962 、https://zhuanlan.zhihu.com/p/133428468 、https://blog.csdn.net/wowotuo/article/details/43083527 ）

**成交先于报单到达的情况**
- 同一条私有流里会不会出现成交先于报单的情况：**未验证**。
- 但在下面几种情况下，确实会出现"收到成交时，还找不到对应的 OrderSysID"：
  - 用 QUICK 订阅，期间断线重连；
  - 跨会话（别的终端下的单）；
  - 网关自己做了异步缓存（比如 ctpbee 要等合约查询完成才处理回报）。

### 2.2 拒单的三条通道

| 场景 | 收到的回调 | 特征 |
|---|---|---|
| 柜台校验失败（资金不足、持仓不足、字段错误、OrderRef 重复等） | 下单的会话收到 `OnRspOrderInsert`（带 ErrorID）；该账户所有会话收到 `OnErrRtnOrderInsert` | 没有 OrderSysID，也没有 OrderLocalID |
| 交易所拒单（比如价格超出涨跌停） | 所有会话收到 `OnRtnOrder`，其中 `OrderSubmitStatus=InsertRejected('4')`、`OrderStatus=Canceled('5')` | **没有 ErrorID**，原因只在 `StatusMsg` 里 |
| 非交易时段报单 | 先返回成功，随后收到 `OnRtnOrder(Canceled)` | 是在 CTP 层还是交易所层撤掉的：**未验证** |

另外两点：
- `OnRsp*` 只发给发起请求的会话，通讯故障时可能丢失。
- `OnRtn*` 和 `OnErrRtn*` 走私有流，发给该账户的所有会话，可以重传。

**所以，只靠 `OnRspOrderInsert` 判断拒单是不可靠的。**

### 2.3 撤单失败

| 场景 | 收到的回调 |
|---|---|
| 柜台校验失败 | 本会话收到 `OnRspOrderAction`；所有会话收到 `OnErrRtnOrderAction` |
| 交易所拒绝撤单 | **只收到** `OnErrRtnOrderAction` |
| 撤单成功 | `OnRtnOrder`，其中 `OrderSubmitStatus=Accepted`、`OrderStatus=Canceled` |

常见 ErrorID（来自 `error.xml`）：

| ErrorID | 含义 |
|---|---|
| 24 | 撤单已报送，不允许重复撤单 |
| 25 | 撤单找不到相应报单 |
| 26 | 报单已全成交或已撤销，不能再撤 |

撤单还在途中时，订单可能已经全部成交。这时会同时收到两类回报：撤单失败（错误 26 或 `OnErrRtnOrderAction`），以及 AllTraded 的 OnRtnOrder 和 OnRtnTrade。**订单最终状态以 OnRtnOrder 和 OnRtnTrade 为准。** 这些回报之间的具体先后顺序：**未验证**。

### 2.4 订单标识

- **FrontID + SessionID**：在登录应答里分配，**重连之后会变**。
  - 撤销重连前下的单，必须用那笔订单当时的 FrontID 和 SessionID。
  - 也可以改用 `ExchangeID+OrderSysID` 撤单，这组标识在重连后不变。
- **OrderRef**：字段类型是字符串，但内容必须是正整数，并且**在同一会话内递增**。违反时报 ErrorID 22"不允许重复报单"。
- **两组唯一标识**：
  - `FrontID+SessionID+OrderRef` 和 `ExchangeID+OrderSysID` 都能唯一确定一笔报单，也都能用来撤单。
  - `ExchangeID+TraderID+OrderLocalID` 也唯一，但不能用来撤单。
- **OrderSysID**：第一条 OnRtnOrder 里为空，被拒的废单始终为空；一旦赋值就不会再变。
- **成交的唯一键**：`ExchangeID+TradeID+Direction`。除郑商所外，成交的买卖双方拿到的 TradeID 相同，所以必须带上 Direction。
- **`MaxOrderRef` 的语义**：它表示"已经用过的最大值"还是"下一个可用值"，**未验证**。
  - 安全的做法是从 `MaxOrderRef + 1` 开始编号。

（来源：https://zhuanlan.zhihu.com/p/668722082 ）

### 2.5 私有流的重传方式（`ThostFtdcTraderApi.h`）

| 模式 | 行为 | 采用的项目 | 代价 |
|---|---|---|---|
| `RESTART` (0) | 回放本交易日的全部回报 | vn.py、ctpbee、**ctp.luajit** | 必须做幂等去重 |
| `RESUME` (1) | 从上次收到的位置续传，依赖 flow 目录里的本地流文件 | WonderTrader（默认） | flow 目录必须持久化；流文件丢失后的行为**未验证** |
| `QUICK` (2) | 只推登录之后的新回报 | Kungfu，WonderTrader 的 `quick` 选项 | 断线期间的回报要靠 `ReqQryOrder`/`ReqQryTrade` 补齐 |

订阅调用必须放在 `Init()` 之前。

---

## 3. 各项目实现对照

### 3.1 订单身份与 OrderRef

| 项目 | 订单 ID | OrderRef 初值 | 递增方式 | 问题 |
|---|---|---|---|---|
| vn.py | `f"{frontid}_{sessionid}_{order_ref}"` | 0，不读 MaxOrderRef | 普通的 `+= 1`，不在锁里 | 多线程同时 `send_order` 时有竞态（推断） |
| ctpbee | 同 vn.py | 0 | `+= 1`；`onRtnOrder` 里遇到更大的值就用 `int(order_ref)+1` 追上 | 会多跳一号；其他会话回放的订单也会把它推高 |
| WonderTrader | `"%06d#%010d#%06d"`（front#session#ref） | `atoi(MaxOrderRef)` | `std::atomic::fetch_add` | 不带 usertag 的下单路径用的是 `fetch_add(0)`，不递增，可能重复 |
| Kungfu | 内部 order_id，映射关系存 SQLite | `atoi(MaxOrderRef)` | 后置 `++` | 第一笔直接用 MaxOrderRef 本身，可能撞号（**未验证**） |
| **ctp.luajit** | key 由 Lua 侧拼出 | `strcpy(lst_order_ref, MaxOrderRef)` | C 侧 `atoi(lst_order_ref)+1`；**SPI 线程在 OnRtnOrder 里也会改写 `lst_order_ref`** | Lua 在发单之后才读 `lst_order_ref`，和 SPI 线程竞态（#11） |

**WonderTrader 的 usertag 做法**
- 策略侧的标签（`otp.<通道>.<localid>`）**不写进 CTP 字段**。
- 改为用两个 mmap 持久化的 KV 缓存维护映射：`EntrustID → usertag` 和 `OrderSysID → usertag`。
- 两个缓存按交易日自动清空，所以进程重启后仍能识别自己下过的单。

### 3.2 成交如何关联到订单

| 项目 | 关联键 | 成交先于订单到达时 | 成交去重 |
|---|---|---|---|
| vn.py | `sysid_orderid_map[OrderSysID]`（不带 ExchangeID） | 合约初始化完成后会抛 `KeyError`，这笔成交丢失 | 网关和 OMS 都不去重；`vnpy_ctastrategy` 在策略层按 `vt_tradeid` 去重 |
| ctpbee | 同 vn.py；而且空串 `""` 键会被反复覆盖 | `KeyError` | 无 |
| WonderTrader | `m_oidCache[OrderSysID]`（不带 ExchangeID） | 得到 `localid=0`，**在途量永远不扣减**，策略收到 `on_trade(0,…)` | 无；`checkSelfMatch` 检测到重复推送时只写了一行注释"不用管了"，但持仓在这之前已经加上了 |
| Kungfu | `ExchangeID+OrderSysID` | 只打 ERROR 日志，成交丢失 | 不按交易所 TradeID 去重 |
| paulran fork | 先按 OrderRef，再按 `hash(sysid\|exch\|OrderSysID)`，最后按 `hash(trade\|exch\|TradeID)` | 有兜底 | 按 `hash(exchange\|TradeID)` 去重，**但没带 Direction** |
| **ctp.luajit** | OnRtnTrade 时用 `ExchangeID+OrderSysID` 查（`trader.lua:733`） | 查不到就忽略 | 无，**而且用的是 RESTART** |

**合约未就绪时的缓冲（vn.py、ctpbee）**
- 登录阶段，合约查询完成之前收到的 OnRtnOrder 和 OnRtnTrade 会先缓存在 `order_data` / `trade_data` 里。
- 查询完成后**先回放全部订单、再回放全部成交**，保证了关联顺序。
- 这个思路值得参考：把它从"等合约就绪"推广到"成交等它的订单"。

### 3.3 状态映射

CTP 的 `OrderStatus`（OST）取值：

| 值 | 含义 |
|---|---|
| `'0'` | 全部成交 |
| `'1'` | 部分成交、还在队列中 |
| `'2'` | 部分成交、不在队列中 |
| `'3'` | 未成交、还在队列中 |
| `'4'` | 未成交、不在队列中 |
| `'5'` | 撤单 |
| `'a'` | 未知 |
| `'b'` | 尚未触发 |
| `'c'` | 已触发 |

`OrderSubmitStatus`（OSS）取值：

| 值 | 含义 |
|---|---|
| `'0'` | 已提交 |
| `'1'` | 撤单已提交 |
| `'2'` | 修改已提交 |
| `'3'` | 已接受 |
| `'4'` | 报单已被拒绝 |
| `'5'` | 撤单已被拒绝 |
| `'6'` | 改单已被拒绝 |

| 项目 | 映射方式 | 坑 |
|---|---|---|
| vn.py | `'3'`→NOTTRADED，`'1'`→PARTTRADED，`'0'`→ALLTRADED，`'5'`→CANCELLED，`'a'`→SUBMITTING；`'5'`+OSS`'4'`→**REJECTED**（2026-03 才加上） | `'2'` 和 `'4'` 不在映射表里，这类回报直接被**丢弃**；订单类型不在映射表里的回报也会被丢弃 |
| ctpbee | 把 OAS 常量（`'a'`/`'b'`/`'c'`）和 OST 常量混在同一张表里 | `'a'`(Unknown) 被当成 SUBMITTING 尚可，但 `'c'`(Touched) 会被当成 **REJECTED**；遇到 `'2'`/`'4'` 抛 KeyError；交易所拒单被当成撤单 |
| WonderTrader | 大体是直接强转；`'2'`→Canceled（2023-09 加）；`'a'`→Submitting；`OSS >= '4'` 一律标记为 error | `'4'` 不算终态；`'b'`/`'c'` 强转后会错位成 `WOS_Cancelling`/`WOS_Nottouched`；**`>= '4'` 会把撤单被拒（`'5'`）的单误判为已死**，进而从订单表里移除（推断） |
| Kungfu | 按 OSS 细分 Unknown；`'2'`→PartialFilledNotActive | 交易所拒单（`'5'`+`'4'`）被当成撤单；`'4'` 没有对应分支，状态不赋值 |

**结论**
- 判断时 OST 和 OSS 要**同时看**，不能把两者的常量混在一张表里。
- `'2'` 和 `'4'` 都按终态处理。
- 交易所拒单的判定条件是：OST=`'5'` 且 OSS=`'4'`。
- OSS=`'5'`（撤单被拒）**不改变**订单状态。

### 3.4 拒单与撤单失败的处理

| 项目 | OnRspOrderInsert | OnErrRtnOrderInsert | OnRspOrderAction | OnErrRtnOrderAction |
|---|---|---|---|---|
| vn.py | 推送一条 REJECTED 订单，同时记一条错误 | **未实现** | 只记日志，不通知订单 | **未实现** |
| ctpbee | 推送一条 REJECTED 订单，同时发一条错误事件 | **未实现** | 只记日志 | **未实现** |
| WonderTrader | `onRspEntrust(err)`，回退在途量 | 已实现，和 OnRspOrderInsert 走同一条路径 | `onTraderError`（错误分支和成功分支曾经写反，2023-08 修复） | **未实现** |
| Kungfu 2.1.2 | 生成一条 Error 状态的订单 | **未实现** | 按 `nRequestID` 找到对应撤单，写回 `OrderActionError` | **未实现** |
| paulran fork | — | — | — | 已实现 |
| **ctp.luajit** | `R.OnRspOrderInsert` 以 `invalid: (ErrorID)` 结束订单 | **SPI 没有转发** | `order:update`，但回显的 FrontID 和 SessionID 都是 0，拼出来的 key 是错的（#9） | **SPI 没有转发** |

WonderTrader 的注释里写着："实盘中发现错误单有时候会推送两次"（`onRspEntrust`）。原因很可能就是 `OnRspOrderInsert` 和 `OnErrRtnOrderInsert` 都触发了。它的防护办法是：如果该合约的在途量已经是 0，就直接 return。这只是启发式处理：同一合约还有别的在途单时，重复的错误通知仍然会被多扣一次。

**结论**
- 订单的"结束"必须幂等：同一笔订单无论收到几条拒单或撤单通知，都只结束一次。
- 去重以订单 key 为单位，不能靠在途量来猜。

### 3.5 撤单使用的标识

| 项目 | 撤单时带的字段 |
|---|---|
| vn.py、ctpbee、Kungfu | 只带 `FrontID+SessionID+OrderRef` |
| WonderTrader | 两组同时带：`FrontID+SessionID+OrderRef`（从 EntrustID 解析出来）和 `ExchangeID+OrderSysID` |
| **ctp.luajit** | `order:cancel` 走 `req("OrderAction")`。超时撤单用的 OrderSysID 可能还是空的（#10），而且定时器没有取消 |

### 3.6 在途量、冻结、平今平昨（WonderTrader TraderAdapter）

**在途量 `_undone_qty`（按合约记录带符号的手数）**
- 下单时加上整笔数量。
- 以下情况减少：
  - 收到自己订单的成交；
  - 撤单，减去 `vol - traded`；
  - 下单出错。
- 收到订单查询回报时，先清空，再用所有存活订单的剩余量重新累加。

**平仓冻结（本地维护）**
- 某个 OrderSysID **第一次**出现，并且是平仓单时冻结持仓：
  - 平今单只冻结今仓；
  - 普通平仓单先冻结昨仓，昨仓不够再冻结今仓。
- 撤单时把冻结量加回去。
- 从持仓查询结果推算可平量时：多头仓位减 `ShortFrozen`，空头仓位减 `LongFrozen`。这个方向 2021-11 修正过。

**开平顺序（`actpolicy.yaml`）**
- 按品种分组配置规则序列，可用的动作有 `open`、`close`、`closetoday`、`closeyestoday`。
- 每条规则可以带：
  - `limit`：当日开仓限额；
  - `pure`：只有持仓是纯今仓或纯昨仓时才执行这一步。
- 例：股指配置为"平昨 → 开仓 → 平今"，目的是规避平今手续费。

**单笔数量上限**
- 超过 `getMaxLmtVol` / `getMaxMktVol` 时自动拆单。

**vn.py 的 OffsetConverter（另一种思路）**
- 上期所和上期能源的平仓单按今仓、昨仓拆开：今仓够时整单 CLOSETODAY；今仓不够时先用 CLOSETODAY 平掉可用今仓，剩余部分用 CLOSEYESTERDAY。
- 可平量不够（`pos - pos_frozen`）时直接拒绝下单。
- 另有锁仓模式和净仓模式。
- 冻结量根据所有活动订单的 `volume - traded` 实时计算。

### 3.7 风控与流控

| 项目 | 下单/撤单频率 | 自成交 | 其他 |
|---|---|---|---|
| WonderTrader | `riskmon.policy` 支持总量限制和滑动窗口限制。超限后把合约加入 `_exclude_codes`，**永久禁用，不会自动恢复** | 只能**事后**检测（同一个 TradeID 关联到两个不同的 OrderSysID），检测到后禁止该合约继续交易 | issue #157："100 秒限 20 次，实际能撤 30 次"，仍是 open 状态。原因是计数检查发生在写入之前，存在 off-by-one；批量撤单也不计数 |
| vn.py | `ReqOrderInsert` 返回 -2/-3 时只记日志，返回 `""`，不重试 | 无 | 社区有一个流控队列版本：按 1/6 秒节拍发单，遇到 -2/-3 就把请求重新插回队头 |
| 查询流控 | WonderTrader：用一个线程串行执行查询，两次间隔 ≥1s；paulran 间隔 1.1s；vn.py 每 2 个定时器周期轮询一次 | | WonderTrader 的问题：`ReqQry*` 返回非 0 或一直不回包时，`m_bInQuery` 会永远卡在 true，后续查询全部停摆 |

**`ReqXxx` 的返回值**

| 返回值 | 含义 |
|---|---|
| 0 | 成功 |
| -1 | 网络失败 |
| -2 | 未处理请求超过许可数 |
| -3 | 每秒请求数超过许可数 |

另外，ErrorID 90 表示"查询未就绪"。

**监管变化**
- 2024-10-25 起，五家期货交易所（不含中金所）统计自成交和频繁报撤单时，不再豁免 FAK/FOK 限价指令。
- 中金所的修订规则自 2026-06-01 起执行，同样不再豁免 FAK/FOK。
- 具体阈值各交易所、各品种不同，**未验证**。

---

## 4. 这些项目踩过的坑（按类别整理）

| # | 坑 | 出处 | 对 ctp.luajit 的启示 |
|---|---|---|---|
| P1 | 本地 SUBMITTING 晚于柜台的 REJECTED 入队，导致状态倒退 | vnpy_ctp#104，`e956be01` 加 `order_lock` 修复 | 订单先登记、再发单；状态机拒绝回退 |
| P2 | OMS 没有"终态不可回退"保护 | vn.py OmsEngine | 订单进入终态后只接受补充信息（比如晚到的成交），不改变状态 |
| P3 | 成交先于订单映射到达，导致 KeyError 或成交丢失 | vn.py、ctpbee、Kungfu、WonderTrader | 增加孤儿成交缓存，等对应订单到达后再归并 |
| P4 | RESTART 回放导致重复成交、持仓被重复累加 | 所有项目 | 按 `ExchangeID+TradeID+Direction` 去重 |
| P5 | 索引键缺少 ExchangeID | vn.py、ctpbee、WonderTrader | 索引键统一带上 ExchangeID |
| P6 | 空的 OrderSysID 被当成键使用 | ctpbee | OrderSysID 非空时才建立索引 |
| P7 | OST 和 OSS 常量混在一张表里，`Touched` 被误判为 REJECTED | ctpbee | 两个字段分开判断 |
| P8 | `'2'`/`'4'` 状态没有映射，回报被丢弃或导致崩溃 | vn.py、ctpbee、Kungfu | 状态覆盖要完整，`'2'`/`'4'` 视为终态 |
| P9 | 交易所拒单被当成撤单 | ctpbee、Kungfu（vn.py 2026-03 才修） | `'5'`+OSS `'4'` 视为拒单，保留 StatusMsg |
| P10 | `OSS >= '4'` 把撤单被拒的单误判为已死 | WonderTrader | 只有 OSS==`'4'` 才算拒单 |
| P11 | 没有实现 `OnErrRtnOrderInsert` / `OnErrRtnOrderAction` | 几乎所有项目 | C 侧转发这两个回调，Lua 侧处理 |
| P12 | 撤单失败只记日志，调用方不知道 | vn.py、ctpbee | 撤单结果要返回给调用方，但不改变订单状态 |
| P13 | 同一笔错误单推送两次（OnRsp 和 OnErrRtn 各一次） | WonderTrader 的注释 | 结束操作按订单 key 做幂等 |
| P14 | OrderRef 不递增，或者初值撞号 | WonderTrader 的无 usertag 路径、Kungfu | 从 `MaxOrderRef+1` 开始，在单一线程内分配 |
| P15 | OrderRef 自增不在锁里 | vn.py | ctp.luajit 每个 trader 只在一个 service 里运行，在 Lua 内分配就没有竞态 |
| P16 | `OnRspOrderAction` 的错误分支和成功分支写反 | WonderTrader `21832263` | 撤单回报要专门写测试 |
| P17 | 撤单回报不带足够的定位信息 | WonderTrader `e111ec04`、`d805b4fd` | 撤单失败要能对应回原订单；ctp.luajit 现在回显的 FrontID/SessionID=0（#9） |
| P18 | 流控计数存在 off-by-one，批量撤单不计数 | WonderTrader#157 | 风控先计数再判断，所有撤单入口都要计数 |
| P19 | 查询卡死后永不恢复 | WonderTrader `m_bInQuery` | ctp.luajit 第一轮已经做了超时出队 ✅ |
| P20 | 释放 API 时调用 `RegisterSpi(NULL)` 导致崩溃 | WonderTrader `1956eace` | C 侧释放顺序要注意（对应第三轮的 `ctp_trader_free`） |
| P21 | GBK 字符被截断成半个 | vnpy_ctp#84/#30 | ctp.luajit 今天已经处理 ✅（`ctp.gbk` 会丢掉结尾的半个字符） |
| P22 | 上期所/上期能源用 `'1'` 平今仓失败 | 社区普遍反映 | 平仓单按今仓、昨仓拆开 |
| P23 | 上期所/上期能源不支持市价单 | vn.py 论坛、无限易文档 | 市价单改为用对手价或涨跌停价的限价单，再加 FAK |

---

## 5. 对 ctp.luajit 的设计建议

### 5.1 现状（2026-11-02 核对）

- **订阅方式**：`src/ctpc.cpp:273-274` 用 `THOST_TERT_RESTART` 订阅公有流和私有流。
- **OrderRef**
  - `CustomTradeSpi.cpp:104-105` 在登录时把 `MaxOrderRef` 复制进 `lst_order_ref`。
  - `CustomTradeSpi.cpp:214-215` 在 SPI 线程里，看到更大的 OrderRef 就改写 `lst_order_ref`。
  - `ctpc.cpp:313-317` 下单时在 service 线程里计算 `atoi(lst_order_ref)+1`，再写回 `lst_order_ref`。
  - 也就是说，**两个线程无锁读写同一个字符串缓冲区**。
- **回调转发**：`CUSTOM_ON` 列表里只有 `OnRspOrderInsert` 和 `OnRspOrderAction`，**`OnErrRtnOrderInsert` 和 `OnErrRtnOrderAction` 根本没有转发到 Lua**。
- **订单结束条件**：只有两种情况会结束订单：
  - 收到 `OnRtnTrade` 且订单状态为 AllTraded（`trader.lua:758`）；
  - 状态为 Canceled。
  - 交易所拒单（`'5'`+`'4'`）走的是 Canceled 分支，结果被当成普通撤单。
- **成交去重**：没有。

### 5.2 订单表的结构

```
orders[key]          key = FrontID .. ":" .. SessionID .. ":" .. OrderRef   -- 主键，下单前就生成
by_sys[exch .. ":" .. sysid] -> key                                          -- OrderSysID 非空时才建立
trades_seen[exch .. ":" .. tradeid .. ":" .. direction] = true               -- 成交去重
orphan_trades[exch .. ":" .. sysid] = { trade, ... }                         -- 找不到订单的成交，等订单到了再归并
```

- 每个 trader 只在一个 service（单线程 Lua 状态）里运行，所以这些表都不需要加锁。
- 跨交易日时清空，可以复用登录时拿到的 TradingDay。

### 5.3 状态机

```
            ┌──────────── OnRspOrderInsert / OnErrRtnOrderInsert ──────────┐
            │                                                               ▼
 pending ──(ReqOrderInsert 返回 0)──► submitted ──OnRtnOrder(OST 3/1)──► working ──┐
   │                                     │  ▲                              │         │
   │ 返回 <0                             │  └── 部分成交（OST 1）─────────────┘         │
   ▼                                     ▼                                          ▼
 failed                    OnRtnOrder OST 5 + OSS 4 ──► rejected        filled / canceled
                                                                         (OST 0 / 5 / 2 / 4)
```

规则：

1. **先登记、后发单。** Lua 分配 OrderRef，`orders[key]` 设为 `pending`，然后再调用 `req("OrderInsert")`。返回值小于 0 时，订单直接进入 `failed`（对应 P1、P14、#11）。
2. **终态**：`filled`、`canceled`、`rejected`、`failed` 四种。只能进入一次；进入后只接受补充信息（晚到的成交、StatusMsg），不改变状态，也不再次唤醒等待中的协程（对应 P2、P13）。
3. **判定 filled** 有两种情况，满足其一即可：
   - `OnRtnOrder` 的 OST 为 `'0'`；
   - 去重后累计的成交量 ≥ 报单数量。
   
   如果先收到 OST `'0'`、成交还没收齐，**可以先结束订单**，返回的结果里同时带上 `VolumeTraded` 和已经收到的成交明细。晚到的成交照常记账，不再唤醒协程（对应 #8）。
4. **判定 rejected**：OST 为 `'5'` 且 OSS 为 `'4'`，原因取自 `StatusMsg`（现在已经是 UTF-8）。或者收到 `OnRspOrderInsert` / `OnErrRtnOrderInsert`，原因取 `ErrorID` 加 `ErrorMsg`（对应 P9、P11）。
5. **OST `'2'` / `'4'`**：表示订单已不在队列里，按 canceled 处理（FAK/FOK 剩余部分被撤）。如果有部分成交，保留成交量（对应 P8）。
6. **OSS `'5'`（撤单被拒）**：不改变订单状态（对应 P10）。
7. **撤单**：用 `ExchangeID+OrderSysID` 撤；还没有 OrderSysID 时，用订单自己的 Front/Session/Ref（**不是当前会话的值**）。
   - 撤单结果单独通知调用方（`cancel` 返回 ok 或 err）。
   - 收到 `OnRspOrderAction` / `OnErrRtnOrderAction` 时，用回报里的 `OrderRef + ExchangeID + OrderSysID` 关联回原订单，**不要用回显的 FrontID/SessionID**（对应 #9、P12、P17）。
   - 撤单失败、错误码为 26 时，说明订单已经成交，等成交回报到来即可。
8. **超时撤单**：订单结束时取消定时器。超时触发时如果订单还没有 OrderSysID，就用 Front/Session/Ref 撤单（对应 #10）。
9. **其他会话、回放的订单**：用回报里自带的 Front/Session/Ref 建立条目，状态以柜台推送的为准；它们不唤醒任何协程。

### 5.4 订阅方式的选择

- 当前用的是 RESTART。好处是登录后能自动重建当天的订单和成交，不用额外查询。代价是**必须**做去重（5.2 里的 `trades_seen`），而且回放期间不能把旧订单当成新事件推给策略。
- 我推荐**继续用 RESTART，同时加上去重**。理由有三个：
  - 改动最小；
  - 和 vn.py 的行为一致；
  - 不依赖 flow 目录的持久化。ctp.luajit 在 Linux 上把 flow 放在 `/dev/shm`，重启后就没了，所以 RESUME 不可靠。
- 只有遇到回放量太大、登录太慢的情况，才考虑 QUICK 加上登录后查询。

### 5.5 报单语义按交易所区分

| 交易所 | 平仓 | 市价 |
|---|---|---|
| SHFE / INE | `'1'` 只平昨仓；平今仓用 `'3'`；拆单顺序可配置（默认先平今仓，因为今仓手续费通常更低。**以期货公司费率为准，不同品种不同**） | **不支持**。用对手价限价单（或涨跌停价）+ FAK（`TC_IOC`+`VC_AV`） |
| DCE / GFEX | `'1'`，按先开先平 | 支持市价 FAK、市价 FOK、市价剩余转限价；**期权不支持** |
| CZCE | `'1'` | 支持市价 FAK，不支持 FOK |
| CFFEX | `'1'` | 支持"最优一档"；期权和远月季月合约不支持；对应 `OPT_BestPrice` 还是 `AnyPrice`，**未验证** |

**建议**
- **不要使用 AnyPrice。** 所有"市价单"都改写成对手价（或涨跌停价）加 FAK。这样各交易所行为一致，也避开了 SHFE/INE 的拒单（对应 #12）。
- `nuke` 平仓时，SHFE/INE 按 `TodayPosition` 和 `YdPosition` 分别下 `'3'` 和 `'4'`；其他交易所下 `'1'`（对应 #13）。

### 5.6 风控闸门（第四步）

参考 WonderTrader，并避开它的问题：

**检查项**
- 单笔数量上限，超过时拒绝或拆单；
- 合约白名单；
- 价格偏离（相对最新价或涨跌停）；
- 最大持仓，计算时把在途量算进去；
- 每秒报单数、每日撤单数、每日报单数。

**实现要点**
- 计数器在**发出请求之前**加一，然后判断（避免 P18 的 off-by-one）。
- 所有撤单入口都要经过计数器。
- 超限只暂停对应合约，并且可以手动恢复，不要永久禁用。
- 自成交防护：下单前检查本方在同一合约上有没有价格可能成交的反向挂单（WonderTrader 只做事后检测）。
- `query_only` 也并入这个闸门。

### 5.7 需要补的测试（基于 `tests/lua/trader_order_test.lua`）

1. `OnRtnOrder(AllTraded)` 先于 `OnRtnTrade` 到达，订单只结束一次（#8）。
2. 成交先于含 OrderSysID 的 OnRtnOrder 到达，进入孤儿缓存，之后被归并（P3）。
3. 同一笔成交推送两次（模拟 RESTART 回放），只记一次（P4）。
4. 交易所拒单（`'5'`+OSS `'4'`）结束为 rejected，并带上 StatusMsg（P9）。
5. 先收到 `OnRspOrderInsert`，再收到 `OnErrRtnOrderInsert`，订单只结束一次（P13）。
6. `OnRspOrderAction` 回显的 FrontID/SessionID 为 0 时，仍能找到原订单（#9）。
7. 撤单失败（错误 26），之后订单收到成交回报（P12）。
8. 超时撤单：订单还没有 OrderSysID 时，用 Front/Session/Ref 撤单；订单结束后定时器被取消（#10）。
9. OST `'2'` / `'4'` 结束订单，保留部分成交量（P8）。
10. 状态不回退：收到 rejected 之后再收到 `'a'`，状态不变（P2）。
11. 两个交易所的 OrderSysID 相同但 ExchangeID 不同，不会串单（P5）。
12. SHFE 的 `nuke`：今仓和昨仓分别用 `'3'` 和 `'4'` 平（#13）。

### 5.8 C 侧需要做的改动

- 在 `CUSTOM_ON` 列表里加上 `OnErrRtnOrderInsert(CThostFtdcInputOrderField)` 和 `OnErrRtnOrderAction(CThostFtdcOrderActionField)`。这两个回调**没有** `nRequestID` 和 `bIsLast` 参数，宏需要另写一个变体。
- 删掉 SPI 线程对 `lst_order_ref` 的改写（`CustomTradeSpi.cpp:214-215`），OrderRef 改由 Lua 侧分配。`max_order_ref` 只在登录时写一次，供 Lua 读取初值。
- 下单改走生成的 `req("OrderInsert")`，`ctp_trader_order_insert` 留作兼容，或者废弃。

---

## 6. 来源

**源码**
- vnpy_ctp：https://github.com/vnpy/vnpy_ctp/blob/master/vnpy_ctp/gateway/ctp_gateway.py
- vn.py：https://github.com/vnpy/vnpy/tree/master/vnpy/trader（`engine.py`、`object.py`、`constant.py`、`converter.py`）
- vnpy_ctastrategy 的成交去重：https://github.com/vnpy/vnpy_ctastrategy/blob/main/vnpy_ctastrategy/engine.py
- WonderTrader：https://github.com/wondertrader/wondertrader/blob/master/src/TraderCTP/TraderCTP.cpp 、https://github.com/wondertrader/wondertrader/blob/master/src/WtCore/TraderAdapter.cpp 、https://github.com/wondertrader/wondertrader/blob/master/src/WtCore/ActionPolicyMgr.cpp
- ctpbee：https://github.com/ctpbee/ctpbee/blob/master/ctpbee/interface/ctp/td_api.py
- Kungfu（2019 年提交）：https://github.com/kungfu-origin/kungfu/tree/e4fd6b3fb7dddacbc45bb449e21d87b109e61f71/extensions/ctp/src
- Kungfu 2.1.2 镜像（第三方）：https://github.com/lyf-bj/kunfu-2.1.2/blob/main/core/extensions/ctp/src/trader_ctp.cpp
- paulran/kungfu-cpp：https://github.com/paulran/kungfu-cpp/blob/main/brokers/ctp/src/trader_ctp.cpp

**Issue 与提交**
- vnpy_ctp#104（状态倒退）、#102（流控）、#70（reference 字段）、#76、#84、#100：https://github.com/vnpy/vnpy_ctp/issues
- WonderTrader#157（撤单计数）：https://github.com/wondertrader/wondertrader/issues/157
- WonderTrader 的提交 `06e49979`、`eb190e2a`、`6a346abd`、`1956eace`、`21832263`、`e1859f15`、`e111ec04`、`d805b4fd`：https://github.com/wondertrader/wondertrader/commits/master/src/TraderCTP/TraderCTP.cpp

**文档与文章**
- CTP 回调与拒单、撤单语义：https://zhuanlan.zhihu.com/p/663816962
- 成交回报顺序与关联键：https://zhuanlan.zhihu.com/p/133428468
- 订单标识：https://zhuanlan.zhihu.com/p/668722082
- 交易所的平今与市价规则（无限易文档）：https://zhuanlan.zhihu.com/p/1548276305 、https://zhuanlan.zhihu.com/p/704527526
- CTP 回报机制：https://blog.csdn.net/wowotuo/article/details/43083527
- vn.py 论坛（上期所市价单）：https://www.vnpy.com/forum/topic/3050-shang-qi-suo-de-pin-chong-du-bu-neng-fa-shi-jie-dan-ma
- vn.py 论坛（流控 gateway）：https://www.vnpy.com/forum/topic/29510-fen-xiang-yi-ge-fu-he-ctpliu-kong-de-ctp-gateway
- 中金所异常交易规则修订：https://finance.sina.com.cn/wm/2026-05-29/doc-inhzqccn7946797.shtml
- `error.xml`（ErrorID 22/24/25/26/30/50/51/90/91）：Kungfu 仓库中自带的 CTP API 目录
- `ThostFtdcTraderApi.h` / `ThostFtdcUserApiDataType.h`：本仓库 `lib/ctp-6.7.13-macos/`
