# 行情入库设计

watcher 把行情写进 QuestDB 的两张表：

- `ctp_tick`：每个 tick 一行，只存一档，字段以 `examples/tick.lua` 的输出为准；
- `ctp_daily`：每个合约每个交易日一行，存当天不变或只关心最终值的字段。

建表语句在 [`ctp_tables.sql`](ctp_tables.sql)，第一次写入前执行。不依赖 ILP 自动建表：
自动建表推断不出 `SYMBOL` 容量和日表的 `DEDUP`。

```text
CTP 行情 ──► collector.lua ──────────────► db_writer.lua ─────────────────► QuestDB
             每个 tick 原样                 整理成行，攒批写进 buffer         ctp_tick
             send("on_tick", tick)          每 1000 行或 1 秒 flush 一次      ctp_daily
                                            日表每 5 分钟、stop_all、quit 时写
```

分工：

- **collector.lua** 只做转发：`ctp.templates.collector` 加一个 `on_tick`，每个 tick
  原样 `service.send` 给 db_writer。发送失败（db_writer 已经退出）只计数、打日志。
- **db_writer.lua** 负责整理和批量：算时间戳、处理无效值、写 buffer、攒批 flush、
  维护日表。
- **entry.lua**（根 service）在 `start_all` 时把行情登录的交易日和合约的交易所交给
  db_writer。

**不做过滤**：没有变化的快照、订阅时柜台补发的旧快照都原样入库，清洗放到下游分析时做
（下面有示例 SQL）。唯一跳过的是算不出时间戳的 tick（`UpdateTime` 格式不对），因为
指定时间戳是必填的。

纯函数（时间换算、无效值、日表列映射）放在 [`tick_rules.lua`](tick_rules.lua)，离线
测试 `tick_rules_test.lua` 包含在根目录的 `make test` 里。

## 为什么这样设计

上一版（表 `ctp_md_buffer`，47 列）在 2026-11-02 晚上 19:00–23:00 写了 794 个合约、
73,018 行。查数据发现：

| 发现 | 数据 | 处理 |
| --- | --- | --- |
| 大商所 `ts` 整体晚了一天 | 14,123 行（20%）比接收时间晚 23–24 小时，全是大商所合约 | 日期不再用 `ActionDay`，改用本机的北京日期 |
| 五档行情 | 只有上期所/能源中心有；大商所、郑商所空档存成了 0 | 只存一档；0 也当无效价 |
| `exchange_id` | 全部是 NULL，行情前置不填 | 挪到日表，由交易查询提供 |
| 昨结算、涨跌停等 | 每个合约只有 1 个值，却每个 tick 都存一遍 | 挪到日表 |

每行从约 330 字节降到约 88 字节。

## `ctp_tick`

| 列 | 类型 | 来源 | 说明 |
| --- | --- | --- | --- |
| `ts` | TIMESTAMP | `UpdateTime` + `UpdateMillisec`，日期见下 | 指定时间戳，按天分区 |
| `symbol` | SYMBOL | `InstrumentID` | |
| `trading_day` | SYMBOL | 行情登录返回的 `TradingDay` | 夜盘归到下一个交易日；没有时用 tick 里的 |
| `last_price` | DOUBLE | `LastPrice` | |
| `volume` | LONG | `Volume` | 当日累计，不是增量 |
| `turnover` | DOUBLE | `Turnover` | 当日累计；相邻两行相减除以成交量和合约乘数，就是这段时间的均价 |
| `open_interest` | LONG | `OpenInterest` | |
| `bid_price1` / `bid_volume1` | DOUBLE / LONG | `BidPrice1` / `BidVolume1` | |
| `ask_price1` / `ask_volume1` | DOUBLE / LONG | `AskPrice1` / `AskVolume1` | |
| `insert_at` | TIMESTAMP | 本机时间 | db_writer 执行 flush 的时间，同一批的行相同 |

### 时间

`ts` 只用 `UpdateTime` 和毫秒，日期取本机的北京日期。行情时间和本机时间相差超过
半天，说明跨了零点：00:00:01 收到 23:59:59 的行情算前一天，反过来算后一天。
不用 `ActionDay`，因为大商所夜盘填的是下一个交易日；也不用 `TradingDay`，
夜盘的交易日本来就是下一天。这要求本机时钟准确。

`insert_at` 是这一行被提交给 QuestDB 的时间：db_writer 攒够 1000 行或每 1 秒 flush 一次，
同一批的行 `insert_at` 相同。`insert_at - ts` 包括交易所到柜台、柜台到本机、在 mailbox 里
排队、等 flush 这几段，正常在 1 秒多以内；变大说明链路某处慢了，偏离几小时则是旧快照。

### 交易日

由 `entry.lua` 的 `start_all` 从 collector 取行情登录返回的 `TradingDay`，交给
db_writer。不用 tick 里的 `TradingDay`，因为郑商所夜盘填的是自然日。

### 无效值

CTP 用 `DBL_MAX` 表示“没有”，空档位和没成交过的合约还会给 0。价格列把 0、
负数和 `DBL_MAX` 都写成 NULL；成交额 0 是有效值；整数列遇到无效值就不写这一列，
QuestDB 同样存为 NULL。

### 下游清洗

不做过滤，表里会有这两类行：

- **重复快照**：重新订阅时柜台重发、或只有时间在变的快照，一档和成交量都和上一行一样；
- **旧快照**：订阅那一刻柜台推的上一节收盘快照，`ts` 比 `insert_at` 早几小时。

分析时按需排除，例如：

```sql
-- 旧快照
SELECT * FROM ctp_tick WHERE abs(datediff('s', ts, insert_at)) > 300;

-- 去掉和上一行完全一样的快照
SELECT * FROM (
  SELECT *, lag(volume) OVER (PARTITION BY symbol ORDER BY ts) prev_volume,
            lag(bid_price1) OVER (PARTITION BY symbol ORDER BY ts) prev_bid,
            lag(ask_price1) OVER (PARTITION BY symbol ORDER BY ts) prev_ask
  FROM ctp_tick WHERE symbol = 'IF2611'
) WHERE prev_volume IS NULL OR volume != prev_volume
     OR bid_price1 != prev_bid OR ask_price1 != prev_ask;
```

不开 QuestDB 的 `DEDUP`：同一毫秒内同一合约可能有多笔不同的快照，用 `(ts, symbol)`
做键会误删。

## `ctp_daily`

| 列 | 类型 | 来源 |
| --- | --- | --- |
| `ts` | TIMESTAMP | 交易日的北京时间零点 |
| `symbol` | SYMBOL | `InstrumentID` |
| `exchange_id` | SYMBOL | 交易查询的 `ExchangeID`，`start_all` 时交给 db_writer |
| `pre_settlement_price` / `pre_close_price` / `pre_open_interest` | DOUBLE / DOUBLE / LONG | `PreSettlementPrice` / `PreClosePrice` / `PreOpenInterest` |
| `upper_limit_price` / `lower_limit_price` | DOUBLE | `UpperLimitPrice` / `LowerLimitPrice` |
| `open_price` / `highest_price` / `lowest_price` | DOUBLE | `OpenPrice` / `HighestPrice` / `LowestPrice` |
| `close_price` / `settlement_price` | DOUBLE | `ClosePrice` / `SettlementPrice`，盘中为 NULL |
| `volume` / `turnover` / `open_interest` | LONG / DOUBLE / LONG | 当日累计 |
| `updated_at` | TIMESTAMP | 这一行取自哪一笔 tick（交易所时间） |

db_writer 记住每个合约最后一笔 tick，在这几个时候把有新 tick 的合约写一行：

- 每 `daily_interval_ms`（默认 5 分钟），进程意外退出时最多丢 5 分钟；
- `stop_all`（日盘 15:45、夜盘 04:00）时 `entry.lua` 调用 `db_writer.flush`；
- 交易日变化、`quit` 时。

表开了 `DEDUP UPSERT KEYS(ts, symbol)`，同一合约同一交易日只保留最新的一行，夜盘和
日盘写进同一行。注意：一个合约本节如果只收到订阅时的旧快照，日表里就是旧快照的值，
看 `updated_at` 能分辨出来。

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

要加 tick 表的列：在 `db_writer.lua` 的 `write_tick` 里写这一列，再
`ALTER TABLE ctp_tick ADD COLUMN`。日表只要在 `tick_rules.DAILY` 加一行。

## 错误处理

- **db_writer 处理不过来**：flush 是同步的 HTTP 调用，QuestDB 卡住时 db_writer 停在 flush 里，
  collector 照常发，tick 在 db_writer 的 mailbox 里排队。mailbox 满了会自动翻倍扩容，不丢
  消息，代价是内存上涨；每次扩容会打一条 `mailbox may overload, length = N` 警告。
  collector 的 `send` 只有在 db_writer 已经退出时才会失败，失败会计数、打日志。
- **时间格式不对**：跳过这个 tick，记日志。
- **一行写到一半失败**：questdb 的 buffer 不能撤销半行，出错时记录日志，这一批（不超过
  1000 行或 1 秒的数据）整批丢掉，后面的批照常写。无效值在整理成行时已经处理，正常不会出现。
- **flush 失败**：HTTP 传输在客户端内部已经重试过，仍然失败时记录日志并清空
  buffer，内存占用保持有界，代价是丢掉这段时间的行情。

## 配置

`collector`：`server`（行情账户，必填），`writer`（默认 `db_writer`）。

`db_writer`：

| 键 | 默认值 | 说明 |
| --- | --- | --- |
| `questdb_conf` | `http::addr=192.168.5.13:9000;` | questdb 连接字符串 |
| `tick_table` / `daily_table` | `ctp_tick` / `ctp_daily` | 目标表 |
| `batch_size` | `1000` | buffer 达到多少行立即 flush |
| `flush_interval_ms` | `1000` | 定时 flush 间隔；buffer 为空时不发请求 |
| `daily_interval_ms` | `300000` | 日表定时写入的间隔 |

## 上线

1. 在 QuestDB 执行 `ctp_tables.sql`（2026-11-02 已在 192.168.5.13 建好，空表）；
2. 部署新的 `ctp.luajit`（collector 模板新增了 `trading_day`），重启 watcher；
3. 第一批数据进来后检查时间：

   ```sql
   SELECT symbol, ts, insert_at FROM ctp_tick
   WHERE abs(datediff('s', ts, insert_at)) > 60;
   ```

`ctp_md_buffer` 已经停写，表还在库里，确认不再需要后手动 `DROP TABLE`。
