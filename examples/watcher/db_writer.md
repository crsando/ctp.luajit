# db_writer 设计

`db_writer` 是 watcher 里唯一和 QuestDB 打交道的 service：接收 collector 转发的
tick，按行写入表 `ctp_md_buffer`，按条数或时间批量提交。

本次重写的目标：

1. 换到新表 `ctp_md_buffer`，保存完整的行情快照，而不是只有价格和成交量；
2. 保留原始时间字段和本机接收时间，让时间戳问题可以事后追查；
3. 去掉逐字段的类型校验，代码只表达“哪个字段写到哪一列”。

## 为什么换表

旧表 `ctp_tmp` 只有 `symbol / price / volume / timestamp` 四列。2026-11-02 的数据里
有 312 条行情时间晚于入库时间（北京时间 18:43、19:02 的行情在 15:00 就已写入），
但表里没有原始的 `ActionDay`、`UpdateTime`，也没有接收时间，无法判断是柜台给的
快照时间有问题，还是写入逻辑有问题。

新表的原则：**交易所给什么就存什么，另外记下我们什么时候收到**。清洗、去重、
合成 K 线都放到下游做，`ctp_md_buffer` 就是原始行情的缓冲层，这也是名字里
`buffer` 的含义。旧表保持原样，不迁移。

## 表结构

建表语句在 [`ctp_md_buffer.sql`](ctp_md_buffer.sql)，要在第一次写入前执行。不依赖
ILP 自动建表：自动建表推断不出 `TIMESTAMP_NS`、`SYMBOL` 容量和 `INT` 这类类型。

| 列 | 类型 | CTP 字段 | 说明 |
| --- | --- | --- | --- |
| `ts` | TIMESTAMP_NS | `ActionDay` + `UpdateTime` + `UpdateMillisec` | 指定时间戳，按 `+08:00` 解析 |
| `received_at` | TIMESTAMP_NS | — | db_writer 处理这条 tick 时的本机时间 |
| `symbol` | SYMBOL | `InstrumentID` | |
| `exchange_id` | SYMBOL | `ExchangeID` | 行情前置常常不填，为空时写 NULL |
| `trading_day` | SYMBOL | `TradingDay` | 原样保存，`YYYYMMDD` |
| `action_day` | SYMBOL | `ActionDay` | 原样保存，`YYYYMMDD` |
| `update_time` | VARCHAR | `UpdateTime` | 原样保存，`HH:MM:SS` |
| `update_ms` | INT | `UpdateMillisec` | |
| `last_price` | DOUBLE | `LastPrice` | |
| `volume` | LONG | `Volume` | 当日累计成交量，不是增量 |
| `turnover` | DOUBLE | `Turnover` | 当日累计成交额 |
| `open_interest` | DOUBLE | `OpenInterest` | CTP 里是 double |
| `average_price` | DOUBLE | `AveragePrice` | 交易所口径，部分交易所含合约乘数 |
| `open_price` / `highest_price` / `lowest_price` | DOUBLE | `OpenPrice` / `HighestPrice` / `LowestPrice` | |
| `close_price` / `settlement_price` | DOUBLE | `ClosePrice` / `SettlementPrice` | 盘中通常无效，写 NULL |
| `pre_settlement_price` / `pre_close_price` / `pre_open_interest` | DOUBLE | `PreSettlementPrice` / `PreClosePrice` / `PreOpenInterest` | |
| `upper_limit_price` / `lower_limit_price` | DOUBLE | `UpperLimitPrice` / `LowerLimitPrice` | |
| `bid_price1..5` / `ask_price1..5` | DOUBLE | `BidPrice1..5` / `AskPrice1..5` | 只有一档行情时 2–5 档为 NULL |
| `bid_volume1..5` / `ask_volume1..5` | LONG | `BidVolume1..5` / `AskVolume1..5` | |

不保存的字段：`reserve1/2`、`ExchangeInstID`（期货与 `InstrumentID` 相同）、
`PreDelta/CurrDelta`（期货无意义）、`BandingUpperPrice/BandingLowerPrice`。
要加列时，在代码的列映射表里加一行，再 `ALTER TABLE ctp_md_buffer ADD COLUMN`。

### 无效值

CTP 用 `DBL_MAX`（约 1.8e308）表示“没有这个值”，例如盘中的 `ClosePrice`、
空档位的 `BidPrice2`。这类值统一写成 `NaN`，QuestDB 存为 NULL。这样
`max(close_price)` 之类的聚合不会被一个天文数字污染。

### 两个时间

- `ts`：交易所时间，作为指定时间戳，按天分区、按它查询。计算方式和旧表一致，日期用
  `ActionDay` 而不是 `TradingDay`，因为夜盘的 `TradingDay` 是下一个交易日。
- `received_at`：`qdb.time.now_ns()`，db_writer 处理这条 tick 时的本机时间。它比
  collector 真正收到行情晚一点（中间隔着一次 service 消息），但足以发现
  `ts` 偏离几小时、几天这种错误：

  ```sql
  SELECT symbol, ts, received_at, trading_day, action_day, update_time
  FROM ctp_md_buffer
  WHERE abs(datediff('s', ts, received_at)) > 60;
  ```

已知的 CTP 怪癖：大商所夜盘的 `ActionDay` 填的是下一个交易日，郑商所的
`TradingDay` 填的是自然日。db_writer **不做修正**，原样保存；有了原始字段和
`received_at`，下游可以按交易所规则修正，也可以直接用 `received_at` 的日期。

### 不做去重

旧表里有完全相同的重复行（同一合约同一时刻最多 8 条），通常是重新订阅时柜台
重发快照。没有开启 QuestDB 的 `DEDUP`：同一毫秒内同一合约可能确实有多笔快照
（累计成交量不同），用 `(ts, symbol)` 做键会误删。需要时可以在下游按
`(symbol, ts, volume)` 去重，或者确认数据后再
`ALTER TABLE ctp_md_buffer DEDUP ENABLE UPSERT KEYS(ts, symbol, volume)`。

## 代码结构

```text
db_writer.lua
  配置          questdb_conf / table / batch_size / flush_interval_ms
  列映射        DOUBLE_COLUMNS、LONG_COLUMNS：{ 列名, CTP 字段名 }，五档在加载时生成
  exchange_time(tick)   ActionDay + UpdateTime + UpdateMillisec -> ns 时间戳
  write_row(tick, ts, received_at)   把一条 tick 写进 buffer
  flush()       提交 buffer；失败时记录日志并丢弃这一批
  S.on_tick     入口：算时间戳、写一行，攒够 batch_size 就 flush
  S.quit        停定时器、最后一次 flush、关闭连接
```

写一行就是按映射表循环，没有逐字段的 `if`：

```lua
for _, c in ipairs(DOUBLE_COLUMNS) do
    assert(buffer:double(c[1], ctp_double(tick[c[2]])))
end
```

### 不再做的检查

旧版在写入前逐个检查 `InstrumentID` 是不是非空字符串、`LastPrice` 是不是有限数、
`ActionDay` 是哪种日期格式、毫秒是不是 0–999 的整数，还兼容 `Milliseconds`
这个并不存在的字段名。这些都去掉了，理由是：

- tick 来自 `ctp` 模块的 `totable`，字段名和类型由 CTP 结构体决定，不会是别的；
- 真出现坏数据时，`parse_rfc3339` 或 questdb 的写入接口本身就会报错，错误信息
  已经足够定位，不需要在前面再包一层同样含义的检查；
- 检查越多，“这个模块到底在写什么”越难看出来。

同理去掉了 `S.tick` 这个别名（只有 `entry.lua` 调用，用的是 `on_tick`），以及对
定时器创建结果的断言。

### 保留的错误处理

只在两个地方处理错误，都是因为不处理会导致更大的损失：

1. **单条 tick 写入失败**：`on_tick` 用 `pcall` 包住 `write_row`。问题在于
   questdb 的 buffer 不支持撤销半行，一行写到一半出错后，后面每一行都会失败。
   所以出错时记录日志并 `buffer:clear()`，丢掉当前这一批（不超过
   `batch_size` 条或 1 秒的数据），让后续写入恢复正常。时间戳在开始写行之前单独
   算好，最常见的坏数据（日期、时间格式不对）只会跳过这一条，不会清空 buffer。
   日志第 1 次和每 1000 次打印一次，避免坏数据持续涌入时刷屏，做法与 collector 一致。
2. **flush 失败**：HTTP 传输在客户端内部已经按 `retry_timeout`（默认 10 秒）重试过，
   仍然失败时记录日志并清空 buffer。不在内存里无限攒数据：数据库长时间不可用时，
   内存占用保持有界，代价是丢掉这段时间的行情。

启动阶段连接 QuestDB、创建 buffer 失败时直接 `assert` 报错退出，不做重试。

## 配置

都通过 `service.spawn` 的 `config` 传入，全部可选：

| 键 | 默认值 | 说明 |
| --- | --- | --- |
| `questdb_conf` | `http::addr=192.168.5.13:9000;` | questdb 连接字符串 |
| `table` | `ctp_md_buffer` | 目标表 |
| `batch_size` | `1000` | buffer 达到多少行立即 flush |
| `flush_interval_ms` | `1000` | 定时 flush 间隔；buffer 为空时不发请求 |

## 上线步骤

1. 在 QuestDB 执行 `ctp_md_buffer.sql` 建表；
2. 重启 watcher，`entry.lua` 不用改；
3. 第一批数据进来后，用上面的 SQL 检查 `ts` 与 `received_at` 的偏差。

## 后续可以做的

- 把 `received_at` 挪到 collector 的 `OnRtnDepthMarketData` 里打，去掉 service 消息带来的延迟；
- 根据收到的数据，决定是否在下游统一修正大商所夜盘日期；
- 数据稳定后考虑给 `ctp_md_buffer` 设置 TTL，长期数据转存到按分钟聚合的表。
