-- 把 collector 转发的 tick 写入 QuestDB，设计说明见 db_writer.md。
-- 建表语句在 ctp_md_buffer.sql，需在第一次写入前执行。
local qdb = require "questdb"
local service = require "service"

local config = service.config or {}
local QUESTDB_CONF = config.questdb_conf or "http::addr=192.168.5.13:9000;"
local TABLE = config.table or "ctp_md_buffer"
local BATCH_SIZE = config.batch_size or 1000
local FLUSH_INTERVAL_MS = config.flush_interval_ms or 1000

-- { 列名, CTP 字段名 }
local DOUBLE_COLUMNS = {
    { "last_price", "LastPrice" },
    { "turnover", "Turnover" },
    { "open_interest", "OpenInterest" },
    { "average_price", "AveragePrice" },
    { "open_price", "OpenPrice" },
    { "highest_price", "HighestPrice" },
    { "lowest_price", "LowestPrice" },
    { "close_price", "ClosePrice" },
    { "settlement_price", "SettlementPrice" },
    { "pre_settlement_price", "PreSettlementPrice" },
    { "pre_close_price", "PreClosePrice" },
    { "pre_open_interest", "PreOpenInterest" },
    { "upper_limit_price", "UpperLimitPrice" },
    { "lower_limit_price", "LowerLimitPrice" },
}

local LONG_COLUMNS = {
    { "volume", "Volume" },
    { "update_ms", "UpdateMillisec" },
}

for i = 1, 5 do
    table.insert(DOUBLE_COLUMNS, { "bid_price" .. i, "BidPrice" .. i })
    table.insert(DOUBLE_COLUMNS, { "ask_price" .. i, "AskPrice" .. i })
    table.insert(LONG_COLUMNS, { "bid_volume" .. i, "BidVolume" .. i })
    table.insert(LONG_COLUMNS, { "ask_volume" .. i, "AskVolume" .. i })
end

local SYMBOL_COLUMNS = {
    { "symbol", "InstrumentID" },
    { "exchange_id", "ExchangeID" },
    { "trading_day", "TradingDay" },
    { "action_day", "ActionDay" },
}

local sender = assert(qdb.sender { conf = QUESTDB_CONF })
local buffer = assert(sender:buffer())
local write_errors = 0

-- CTP 用 DBL_MAX 表示没有值，写成 NaN，QuestDB 存为 NULL。
local function ctp_double(value)
    if value >= 1e300 then
        return 0 / 0
    end
    return value
end

-- 交易所时间：ActionDay 是自然日，CTP 时间是北京时间。
local function exchange_time(tick)
    local day = tick.ActionDay
    return qdb.time.parse_rfc3339(string.format("%s-%s-%sT%s.%03d+08:00",
        day:sub(1, 4), day:sub(5, 6), day:sub(7, 8), tick.UpdateTime, tick.UpdateMillisec))
end

local function write_row(tick, ts, received_at)
    assert(buffer:table(TABLE))
    for _, c in ipairs(SYMBOL_COLUMNS) do
        local value = tick[c[2]]
        if value ~= "" then
            assert(buffer:symbol(c[1], value))
        end
    end
    assert(buffer:string("update_time", tick.UpdateTime))
    for _, c in ipairs(DOUBLE_COLUMNS) do
        assert(buffer:double(c[1], ctp_double(tick[c[2]])))
    end
    for _, c in ipairs(LONG_COLUMNS) do
        assert(buffer:int64(c[1], tick[c[2]]))
    end
    assert(buffer:timestamp("received_at", received_at))
    assert(buffer:at(ts))
end

-- HTTP 传输在客户端内部已经重试过，仍然失败就丢掉这一批，内存不无限增长。
local function flush()
    local rows = buffer:row_count()
    if rows == 0 then
        return
    end
    local ok, err = buffer:flush()
    if not ok then
        service.log.error("db_writer | flush failed, %d rows dropped: %s", rows, tostring(err))
        buffer:clear()
    end
end

local flush_timer = service.uv.new_timer()
flush_timer:start(FLUSH_INTERVAL_MS, FLUSH_INTERVAL_MS, flush)

local function log_write_error(tick, err)
    write_errors = write_errors + 1
    if write_errors == 1 or write_errors % 1000 == 0 then
        service.log.error("db_writer | write %s failed (%d times): %s",
            tostring(tick.InstrumentID), write_errors, tostring(err))
    end
end

local S = {}

function S.on_tick(tick)
    local received_at = qdb.time.now_ns()
    local ok, ts = pcall(exchange_time, tick)
    if not ok then
        log_write_error(tick, ts) -- 还没开始写这一行，跳过即可
        return
    end
    local ok, err = pcall(write_row, tick, ts, received_at)
    if not ok then
        -- buffer 无法撤销写了一半的行，只能清空这一批，否则后面每一行都会失败。
        log_write_error(tick, err)
        buffer:clear()
        return
    end
    if buffer:row_count() >= BATCH_SIZE then
        flush()
    end
end

function S.quit()
    flush_timer:stop()
    flush_timer:close()
    flush()
    sender:close()
    service.quit()
end

return service.dispatch(S)
