-- db_writer 的目标表，列说明见 db_writer.md。
CREATE TABLE IF NOT EXISTS ctp_md_buffer (
    ts TIMESTAMP_NS,
    received_at TIMESTAMP_NS,
    symbol SYMBOL CAPACITY 4096,
    exchange_id SYMBOL,
    trading_day SYMBOL,
    action_day SYMBOL,
    update_time VARCHAR,
    update_ms INT,

    last_price DOUBLE,
    volume LONG,
    turnover DOUBLE,
    open_interest DOUBLE,
    average_price DOUBLE,

    open_price DOUBLE,
    highest_price DOUBLE,
    lowest_price DOUBLE,
    close_price DOUBLE,
    settlement_price DOUBLE,
    pre_settlement_price DOUBLE,
    pre_close_price DOUBLE,
    pre_open_interest DOUBLE,
    upper_limit_price DOUBLE,
    lower_limit_price DOUBLE,

    bid_price1 DOUBLE, bid_volume1 LONG, ask_price1 DOUBLE, ask_volume1 LONG,
    bid_price2 DOUBLE, bid_volume2 LONG, ask_price2 DOUBLE, ask_volume2 LONG,
    bid_price3 DOUBLE, bid_volume3 LONG, ask_price3 DOUBLE, ask_volume3 LONG,
    bid_price4 DOUBLE, bid_volume4 LONG, ask_price4 DOUBLE, ask_volume4 LONG,
    bid_price5 DOUBLE, bid_volume5 LONG, ask_price5 DOUBLE, ask_volume5 LONG
) TIMESTAMP(ts) PARTITION BY DAY WAL;
