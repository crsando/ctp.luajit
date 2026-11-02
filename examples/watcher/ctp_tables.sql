-- db_writer 的目标表，列说明见 db_writer.md。第一次写入前执行。

-- tick 表：每个有变化的 tick 一行，只有一档。
CREATE TABLE IF NOT EXISTS ctp_tick (
    ts TIMESTAMP,                    -- 交易所时间：UpdateTime + 毫秒，日期取本机北京日期
    symbol SYMBOL CAPACITY 4096,
    trading_day SYMBOL,              -- 行情登录返回的交易日 YYYYMMDD
    last_price DOUBLE,
    volume LONG,                     -- 当日累计
    turnover DOUBLE,                 -- 当日累计
    open_interest LONG,
    bid_price1 DOUBLE, bid_volume1 LONG,
    ask_price1 DOUBLE, ask_volume1 LONG,
    received_at TIMESTAMP            -- collector 收到的本机时间
) TIMESTAMP(ts) PARTITION BY DAY WAL;

-- 日表：每个合约每个交易日一行，重复写入按 (ts, symbol) 覆盖为最新。
CREATE TABLE IF NOT EXISTS ctp_daily (
    ts TIMESTAMP,                    -- 交易日的北京时间零点
    symbol SYMBOL CAPACITY 4096,
    exchange_id SYMBOL,
    pre_settlement_price DOUBLE,
    pre_close_price DOUBLE,
    pre_open_interest LONG,
    upper_limit_price DOUBLE,
    lower_limit_price DOUBLE,
    open_price DOUBLE,
    highest_price DOUBLE,
    lowest_price DOUBLE,
    close_price DOUBLE,
    settlement_price DOUBLE,
    volume LONG,
    turnover DOUBLE,
    open_interest LONG,
    updated_at TIMESTAMP             -- 这一行取自哪一笔 tick（交易所时间）
) TIMESTAMP(ts) PARTITION BY YEAR WAL
DEDUP UPSERT KEYS(ts, symbol);
