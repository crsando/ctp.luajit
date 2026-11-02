# 行情入库设计

watcher 把行情写进 QuestDB 的两张表：

- `ctp_tick`：每个有变化的 tick 一行，只存一档，字段以 `examples/tick.lua` 的输出为准；
- `ctp_daily`：每个合约每个交易日一行，存当天不变或只关心最终值的字段。

建表语句在 [`ctp_tables.sql`](ctp_tables.sql)，第一次写入前执行。不依赖 ILP 自动建表：
自动建表推断不出 `SYMBOL` 容量和日表的 `DEDUP`。

```text
CTP 行情 ──► collector.lua ───────────────────────► db_writer.lua ──► QuestDB
             过滤：没变化的、旧快照、时间格式不对的      每行写进 buffer      ctp_tick
             每 100ms 一批 on_ticks(trading_day, rows)  每 1000 行或 1 秒     ctp_daily
             日表行 on_daily(list)                      flush 一次
```

判断逻辑放在 [`tick_rules.lua`](tick_rules.lua)（纯函数，离线测试是
`tick_rules_test.lua`，包含在 `make test` 里）。

## 为什么这样设计

上一版（表 `ctp_md_buffer`，47 列，每个 tick 整张表转发）在 2026-11-02 晚上
19:00–23:00 写了 794 个合约、73,018 行。查数据发现：

| 发现 | 数据 | 处理 |
| --- | --- | --- |
| 大商所 `ts` 整体晚了一天 | 14,123 行（20%）比接收时间晚 23–24 小时，全是大商所合约 | 日期不再用 `ActionDay`，改用本机的北京日期 |
| 订阅时柜台补发的旧快照 | 每个合约一条，比接收时间早 3 小时或 19 小时 | 偏离本机超过 5 分钟的不进 tick 表 |
| 没有变化的快照 | 只看一档、成交量和持仓量，去重后只剩 48,538 种状态 | collector 里和上一笔比较，没变就丢掉 |
| 五档行情 | 只有上期所/能源中心有；大商所、郑商所空档存成了 0 | 不要五档，只存一档；0 也当无效价 |
| `exchange_id` | 全部是 NULL，行情前置不填 | 挪到日表，由交易查询提供 |
| 昨结算、涨跌停等 | 每个合约只有 1 个值，却每个 tick 都存一遍 | 挪到日表 |

结果：每行从约 330 字节降到约 88 字节，行数估计少两到三成；每个 tick 在 service
之间传的字段从约 45 个降到 11 个，而且是平铺数组，不再带键名；collector 到
db_writer 的消息从每 tick 一条变成每 100ms 最多一条。

## `ctp_tick`

| 列 | 类型 | 来源 | 说明 |
| --- | --- | --- | --- |
| `ts` | TIMESTAMP | `UpdateTime` + `UpdateMillisec`，日期见下 | 指定时间戳，按天分区 |
| `symbol` | SYMBOL | `InstrumentID` | |
| `trading_day` | SYMBOL | 行情登录返回的 `TradingDay` | 夜盘归到下一个交易日；登录没给时用 tick 里的 |
| `last_price` | DOUBLE | `LastPrice` | |
| `volume` | LONG | `Volume` | 当日累计，不是增量 |
| `turnover` | DOUBLE | `Turnover` | 当日累计；相邻两行相减除以成交量和合约乘数，就是这段时间的均价 |
| `open_interest` | LONG | `OpenInterest` | |
| `bid_price1` / `bid_volume1` | DOUBLE / LONG | `BidPrice1` / `BidVolume1` | |
| `ask_price1` / `ask_volume1` | DOUBLE / LONG | `AskPrice1` / `AskVolume1` | |
| `received_at` | TIMESTAMP | 本机时间 | collector 收到这笔 tick 的时间，微秒 |

### 时间

`ts` 只用 `UpdateTime` 和毫秒，日期取本机的北京日期。行情时间和本机时间相差超过
半天，说明跨了零点：00:00:01 收到 23:59:59 的行情算前一天，反过来算后一天。
不用 `ActionDay`，因为大商所夜盘填的是下一个交易日；也不用 `TradingDay`，
夜盘的交易日本来就是下一天。原始的 `ActionDay`、`UpdateTime` 不再单独存：
`ts` 的时分秒就是 `UpdateTime`。

这要求本机时钟准确（误差远小于 5 分钟）。时钟偏了，collector 会把大部分 tick
当成旧快照丢掉并打 warn 日志，提示检查时钟。

### 过滤

collector 在转发前丢掉三类 tick，计数在每次 stop 时打印一行 info 日志，也可以用
`service.call("collector", "stats")` 查看本节的计数：

1. **没有变化**：最新价、成交量、持仓量、一档价量和上一笔完全一样（`unchanged`）。
   重新订阅时柜台重发的快照、只有时间在变的快照都属于这类。
2. **旧快照**：行情时间和本机时间相差超过 `stale_ms`（默认 5 分钟，`stale`）。
   主要是订阅那一刻柜台推的上一节收盘快照。simnow-7x24 这类回放环境的行情时间
   和本机对不上，要把 `stale_ms` 设成 0 关掉这一条。
3. **时间格式不对**（`bad_time`）：`UpdateTime` 不是 `HH:MM:SS`，或毫秒不在 0–999。

不开 QuestDB 的 `DEDUP`：同一毫秒内同一合约可能有多笔不同的快照，第 1 条已经去掉
了真正的重复。

### 无效值

CTP 用 `DBL_MAX` 表示“没有”，空档位和没成交过的合约还会给 0。价格列把 0、
负数和 `DBL_MAX` 都写成 NULL；成交额 0 是有效值；整数列遇到无效值就不写这一列，
QuestDB 同样存为 NULL。

## `ctp_daily`

| 列 | 类型 | 来源 |
| --- | --- | --- |
| `ts` | TIMESTAMP | 交易日的北京时间零点 |
| `symbol` | SYMBOL | `InstrumentID` |
| `exchange_id` | SYMBOL | 交易查询的 `ExchangeID`，`start_all` 时交给 collector |
| `pre_settlement_price` / `pre_close_price` / `pre_open_interest` | DOUBLE / DOUBLE / LONG | `PreSettlementPrice` / `PreClosePrice` / `PreOpenInterest` |
| `upper_limit_price` / `lower_limit_price` | DOUBLE | `UpperLimitPrice` / `LowerLimitPrice` |
| `open_price` / `highest_price` / `lowest_price` | DOUBLE | `OpenPrice` / `HighestPrice` / `LowestPrice` |
| `close_price` / `settlement_price` | DOUBLE | `ClosePrice` / `SettlementPrice`，盘中为 NULL |
| `volume` / `turnover` / `open_interest` | LONG / DOUBLE / LONG | 当日累计 |
| `updated_at` | TIMESTAMP | 这一行取自哪一笔 tick（交易所时间） |

表开了 `DEDUP UPSERT KEYS(ts, symbol)`，同一合约同一交易日重复写入只保留最新的
一行。collector 在三个时机写：

- 每节第一笔有效 tick，随下一批发出（开盘后 100ms 内就有涨跌停和昨结算）；
- 每 `daily_ms`（默认 5 分钟）写一次这段时间有变化的合约，进程意外退出时最多丢 5 分钟；
- `stop` 时写最后一次。日盘 15:45、夜盘 04:00 的定时 `stop_all` 都会触发。

夜盘和日盘写进同一行（同一个交易日）。旧快照不会写进日表，所以不会出现上一个
交易日的数据被记到新交易日上。

查询时按交易日关联，例如找出触及涨停的 tick：

```sql
SELECT t.ts, t.symbol, t.last_price, d.upper_limit_price
FROM ctp_tick t
JOIN ctp_daily d ON t.symbol = d.symbol AND t.trading_day = to_str(dateadd('h', 8, d.ts), 'yyyyMMdd')
WHERE t.last_price >= d.upper_limit_price;
```

## 不再保存的字段

| 字段 | 原因 |
| --- | --- |
| 二到五档 | 只有上期所/能源中心有，却占 16 列；用不到 |
| `AveragePrice` | 由成交额 ÷ 成交量 ÷ 合约乘数得到，各交易所口径还不一致 |
| `ActionDay` / `UpdateTime` / `UpdateMillisec` | 已经编码在 `ts` 里，`ActionDay` 还不可靠 |
| `ExchangeID`（tick 里的） | 行情前置不填，日表从交易查询拿 |
| `ExchangeInstID`、`PreDelta/CurrDelta`、`BandingUpper/LowerPrice`、`reserve1/2` | 期货用不到 |

要加 tick 表的列：在 `tick_rules.ROW` 和 `append` 里加一个值，在 `db_writer.lua`
的 `write_tick` 里写这一列，再 `ALTER TABLE ctp_tick ADD COLUMN`。日表只要在
`tick_rules.DAILY` 加一行。

## 代码结构

```text
tick_rules.lua   纯函数
  ROW / STRIDE / append    tick 行的平铺格式
  changed(prev, tick)      tick 表关心的字段有没有变
  exchange_ts_us           UpdateTime + 毫秒 + 本机日期 -> 微秒时间戳
  day_ts_us                交易日 -> 北京时间零点
  price / amount / int     无效值处理
  DAILY / daily            日表的列映射和行

collector.lua    ctp.templates.collector 加上
  on_tick                  过滤、攒行
  批量定时器（100ms）      on_ticks；本节新出现合约的日表行
  日表定时器（5 分钟）     有变化合约的日表行
  set_exchanges / stats    交易所映射；本节计数
  stop                     先把攒着的都发出去，再停行情

db_writer.lua
  on_ticks / on_daily      逐行写进 buffer
  flush                    每 1000 行或 1 秒；失败记录日志并丢弃这一批
```

## 错误处理

- **一行写到一半失败**：questdb 的 buffer 不能撤销半行，出错时记录日志并清空
  buffer（丢掉不超过 1000 行或 1 秒的数据），后面的行照常写。日志第 1 次和每
  1000 次打印一次。
- **flush 失败**：HTTP 传输在客户端内部已经重试过，仍然失败时记录日志并清空
  buffer，内存占用保持有界，代价是丢掉这段时间的行情。
- **退出**：根 service 先 `call` collector 的 `stop`（它把攒着的数据发完才返回），
  再给 db_writer 发 `quit`，最后一次 flush 能带上这些数据。

## 配置

`collector`（`entry.lua` 里 spawn 时传入）：

| 键 | 默认值 | 说明 |
| --- | --- | --- |
| `server` | — | 行情账户，必填 |
| `writer` | `db_writer` | 接收数据的 service |
| `batch_ms` | `100` | 批量转发的间隔 |
| `max_batch_rows` | `2000` | 攒到这么多行立即发 |
| `daily_ms` | `300000` | 日表定时写入的间隔 |
| `stale_ms` | `300000` | 行情时间偏离本机超过多少毫秒算旧快照；0 表示不过滤 |

`db_writer`：

| 键 | 默认值 | 说明 |
| --- | --- | --- |
| `questdb_conf` | `http::addr=192.168.5.13:9000;` | questdb 连接字符串 |
| `tick_table` / `daily_table` | `ctp_tick` / `ctp_daily` | 目标表 |
| `batch_size` | `1000` | buffer 达到多少行立即 flush |
| `flush_interval_ms` | `1000` | 定时 flush 间隔；buffer 为空时不发请求 |

## 上线

1. 在 QuestDB 执行 `ctp_tables.sql`（2026-11-02 已在 192.168.5.13 建好，空表）；
2. 部署新的 `ctp.luajit`（collector 模板新增了 `trading_day`），重启 watcher；
3. 第一批数据进来后检查时间：

   ```sql
   SELECT symbol, ts, received_at FROM ctp_tick
   WHERE abs(datediff('s', ts, received_at)) > 60;
   ```

`ctp_md_buffer` 已经停写，表还在库里，确认不再需要后手动 `DROP TABLE`。
