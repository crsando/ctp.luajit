# tradelog：当日成交落库

查询账户当日成交，清洗成精简记录，写入本地 SQLite。只查询，不下单。

```text
tradelog.lua --JSONL--> import.py --> ~/.ctp.luajit/tradelog.sqlite
```

| 文件 | 作用 |
| --- | --- |
| [`tradelog.lua`](tradelog.lua) | 登录交易前置、查询当日成交，stdout 输出 JSONL，日志走 stderr |
| [`clean.lua`](clean.lua) | 清洗规则（主键、方向、成交时刻）和 JSON 编码，纯函数 |
| [`import.py`](import.py) | uv 脚本，只用标准库：读 JSONL，幂等写入 SQLite |
| [`run.sh`](run.sh) | 两者用管道串起来，任一步失败退出码非 0 |
| [`clean_test.lua`](clean_test.lua)、[`import_test.py`](import_test.py) | 离线测试，`make test-lua` 会跑 |

## 用法

```bash
# 未 make install 时，先让 luajit 找得到 ctp 模块
export CTPC_LIBDIR=$PWD/build/ctp-6.7.10
export LUA_PATH="$PWD/lua/?.lua;$PWD/lua/?/init.lua;;"

examples/tradelog/run.sh <profile>                 # 写入 ~/.ctp.luajit/tradelog.sqlite
examples/tradelog/run.sh <profile> rb2601          # 只看一个合约
examples/tradelog/run.sh <profile> --db ./t.sqlite # 指定数据库
luajit examples/tradelog/tradelog.lua <profile>    # 只看 JSONL，不落库
```

profile 是 `~/.ctp.luajit/accounts.lua` 里 `trader` 下的名字。

## 输出格式

每笔成交一行，最后一行是汇总：

```json
{"trade_id":"123456.20261102.SHFE.12345.buy","investor_id":"123456","trading_day":"2026-11-02","traded_at":"2026-10-30T21:05:13+08:00","instrument_id":"rb2601","direction":"buy","volume":2,"price":3456.2,"commission":null}
{"summary":true,"profile":"gtja-1","symbol":null,"investor_id":"123456","trading_day":"2026-11-02","count":1}
```

两种行的账户和交易日**来源不同**：

| 行 | 对应的表 | `investor_id` | `trading_day` |
| --- | --- | --- | --- |
| 成交记录 | `trades` | 成交回报的 `InvestorID` | 成交回报的 `TradingDay` |
| 汇总行 | `runs` | 登录 session 的 `UserID`（登录回报没有 `InvestorID`） | 登录 session 的 `TradingDay` |

这样没有成交的交易日也能记下账户和交易日。import.py 不要求两边一致。

## import.py 如何处理异常

| 情况 | 处理 | 退出码 |
| --- | --- | --- |
| 不以 `{` 开头的行（SDK 打到 stdout 的内容） | 跳过，stderr 提示 | 不影响 |
| 没有汇总行、笔数对不上、缺字段、汇总行的账户或交易日为空 | 整批拒收 | 非 0 |
| 记录不合法（`direction` 不对、必填字段为 null） | 整批回滚 | 非 0 |
| `trade_id` 已存在，内容相同 | 跳过，这就是重复导入 | 0 |
| `trade_id` 已存在，内容不同（不比较 `commission`） | 保留旧记录，其余照常写入，记入 `runs.conflicts` | 非 0 |
| 数据库是旧结构（`PRAGMA user_version` 不符） | 拒绝写入，避免新旧 `trade_id` 混在一起 | 非 0 |

`conflicts` 不为 0 说明 `trade_id` 的唯一性假设在这个环境不成立，有成交没有入库，需要人工检查。

## 字段（`trades` 表）

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `trade_id` | TEXT 主键 | `账号.交易日.交易所.成交编号.方向`。成交编号只在同一交易所、同一交易日内唯一；自成交时买卖两边编号相同，所以带上方向；模拟环境的编号规则可能不同，所以带上账号 |
| `investor_id` | TEXT | 投资者账号 |
| `trading_day` | TEXT | **结算所属交易日** `YYYY-MM-DD`。夜盘成交算下一个交易日：周五晚上的成交，`trading_day` 是下周一 |
| `traded_at` | TEXT | **成交实际发生的时刻**，ISO 8601，固定 `+08:00`，可直接按文本排序 |
| `instrument_id` | TEXT | 合约代码，如 `rb2601` |
| `direction` | TEXT | `buy` / `sell`。不区分开平 |
| `volume` | INTEGER | 成交手数 |
| `price` | REAL | 成交价 |
| `commission` | REAL | 手续费，**暂时都是 NULL**，以后补 |

按天统计用 `trading_day`，按时间先后用 `traded_at`。

`traded_at` 的日期不取 CTP 的 `TradeDate`（大商所、郑商所夜盘给的可能是交易日），
而是由交易日和成交时间推算：18:00 以后是前一个工作日，06:00 以前是前一个工作日的次日，
其余是交易日当天。节前最后一个交易日没有夜盘，所以不需要节假日日历。

## `runs` 表

每次成功导入记一行，失败的运行不记（看 `run.sh` 的退出码和日志）。

| 字段 | 含义 |
| --- | --- |
| `run_at` | 导入时刻，固定北京时间 |
| `profile` | `accounts.lua` 里的名字 |
| `symbol` | 只查一个合约时的合约代码，否则 NULL |
| `investor_id` | 登录 session 的 `UserID` |
| `trading_day` | 登录 session 的交易日，也就是这次查询的交易日 |
| `count` | CTP 返回的成交笔数 |
| `inserted` | 本次新写入的笔数 |
| `conflicts` | `trade_id` 已存在但内容不同的笔数 |
| `complete` | 1 表示这次导入覆盖了 `trading_day` 整个交易日 |

`complete = 1` 要同时满足：

1. 查的是全部合约（`symbol` 为 NULL）；
2. 登录 session 的交易日就是运行当天（北京时间）；
3. 在 15:15 之后运行（最晚的品种 15:15 收盘）。

夜间和凌晨运行时交易日已切到下一天，所以不算完整；没有成交的交易日照样可以是完整的。

## 定时执行

**CTP 只能查到当前交易日的成交，漏跑的那天就补不回来了。** 建议每个交易日收盘后跑一次，
覆盖前一晚夜盘和当天日盘；再重试一次，防止第一次失败。重复执行是幂等的：

```cron
# crontab -e；cron 的 PATH 很短，luajit、uv 需要写全或在这里设置
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
35 15 * * 1-5  cd /path/to/ctp.luajit && examples/tradelog/run.sh <profile> >> ~/.ctp.luajit/tradelog.log 2>&1
0  17 * * 1-5  cd /path/to/ctp.luajit && examples/tradelog/run.sh <profile> >> ~/.ctp.luajit/tradelog.log 2>&1
```

- **重试必须在交易日切换之前。** 切换之后查到的是下一个交易日，当天的日盘已经查不到了，
  所以半夜补跑救不回白天的成交。切换时间因柜台而异，上线前在 17:00 手工跑一次，
  确认 `trading_day` 还是当天。已切换时 `complete` 是 0，不会误判为完整。
- **机器时区要是北京时间**，cron 按系统时区触发。不是的话要换算上面的时间。
- **cron 在机器睡眠时不执行，错过了也不补。** 放在 Mac 上长期跑时要防止睡眠，或改用 launchd。
- 目前没有失败通知，失败只记在日志里。

## 常用查询

```sql
-- 某天按合约汇总
SELECT instrument_id, direction, SUM(volume) AS volume, SUM(price * volume) / SUM(volume) AS avg_price
FROM trades WHERE trading_day = '2026-11-02' GROUP BY instrument_id, direction;

-- 完整导入过的交易日，对照交易日历找漏跑；没出现的交易日就是没有完整导入
SELECT profile, trading_day, MAX(count) AS trades
FROM runs WHERE complete = 1 GROUP BY profile, trading_day ORDER BY trading_day DESC;

-- 出现过 trade_id 冲突的导入，应该没有结果
SELECT * FROM runs WHERE conflicts > 0;
```

补手续费时用 `UPDATE trades SET commission = ? WHERE trade_id = ?`，重复导入不会覆盖它。
