# tradelog：当日成交落库

查询账户当日成交，清洗成精简记录，写入本地 SQLite。只查询，不下单。

```text
tradelog.lua --JSONL--> import.py --> ~/.ctp.luajit/tradelog.sqlite
```

| 文件 | 作用 |
| --- | --- |
| [`tradelog.lua`](tradelog.lua) | 登录交易前置、查询当日成交，stdout 输出 JSONL，日志走 stderr |
| [`clean.lua`](clean.lua) | 清洗规则（主键、方向、成交时刻）和 JSON 编码，纯函数 |
| [`clean_test.lua`](clean_test.lua) | 清洗规则的测试，`make test-lua` 会跑 |
| [`import.py`](import.py) | uv 脚本，只用标准库：读 JSONL，幂等写入 SQLite |
| [`run.sh`](run.sh) | 两者用管道串起来，任一步失败退出码非 0 |

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

每笔成交一行，最后一行是汇总（没有汇总行说明查询没有完成，import.py 会整批拒收）：

```json
{"trade_id":"20261102.SHFE.12345.buy","investor_id":"123456","trading_day":"2026-11-02","traded_at":"2026-10-30T21:05:13+08:00","instrument_id":"rb2601","direction":"buy","volume":2,"price":3456.2,"commission":null}
{"summary":true,"investor_id":"123456","trading_day":"2026-11-02","count":1}
```

## 字段（`trades` 表）

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `trade_id` | TEXT 主键 | `交易日.交易所.成交编号.方向`。交易所成交编号只在同一交易所、同一交易日内唯一；自成交时买卖两边编号相同，所以带上方向 |
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

`runs` 表每次导入记一行：`run_at`、`investor_id`、`trading_day`、`count`（CTP 返回的笔数）、
`inserted`（本次新写入的笔数）。没有成交的交易日也会有记录。

## 定时执行

**CTP 只能查到当前交易日的成交，漏跑的那天就补不回来了。** 建议每个交易日收盘后跑一次
（覆盖前一晚夜盘和当天日盘），凌晨再补一次；重复执行是幂等的：

```cron
# crontab -e；cron 的 PATH 很短，luajit、uv 需要写全或在这里设置
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
35 15 * * 1-5  cd /path/to/ctp.luajit && examples/tradelog/run.sh <profile> >> ~/.ctp.luajit/tradelog.log 2>&1
10 3  * * 2-6  cd /path/to/ctp.luajit && examples/tradelog/run.sh <profile> >> ~/.ctp.luajit/tradelog.log 2>&1
```

## 常用查询

```sql
-- 某天按合约汇总
SELECT instrument_id, direction, SUM(volume) AS volume, SUM(price * volume) / SUM(volume) AS avg_price
FROM trades WHERE trading_day = '2026-11-02' GROUP BY instrument_id, direction;

-- 最近成功导入过的交易日，对照交易日历找漏跑
SELECT investor_id, trading_day, MAX(count) AS trades FROM runs GROUP BY investor_id, trading_day ORDER BY trading_day DESC;
```

补手续费时用 `UPDATE trades SET commission = ? WHERE trade_id = ?`，重复导入不会覆盖它。
