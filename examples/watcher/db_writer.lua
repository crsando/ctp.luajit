-- 把 collector 转发的 tick 写入 QuestDB：tick 表 ctp_tick、日表 ctp_daily。
-- on_tick 把每个 tick 整理成一行放进待发队列；flush 时把整批写进 buffer、提交，
-- 同一批的 insert_at 都是这次 flush 的时间。不做过滤，清洗放到下游。
-- 设计说明见 db_writer.md；建表语句在 ctp_tables.sql，需在第一次写入前执行。
local qdb = require "questdb"
local service = require "service"
local rules = require "tick_rules"

local config = service.config or {}
local QUESTDB_CONF = config.questdb_conf or "http::addr=192.168.5.13:9000;"
local TICK_TABLE = config.tick_table or "ctp_tick"
local DAILY_TABLE = config.daily_table or "ctp_daily"
local BATCH_SIZE = config.batch_size or 1000
local FLUSH_INTERVAL_MS = config.flush_interval_ms or 1000
local DAILY_INTERVAL_MS = config.daily_interval_ms or 300000

local price, amount, int = rules.price, rules.amount, rules.int
local us = qdb.time.us

local sender = assert(qdb.sender { conf = QUESTDB_CONF })
local buffer = assert(sender:buffer())
local errors = 0

local rows = {}         -- 待发的 tick 行，见 to_row
local daily_rows = {}   -- 待发的日表行，见 to_daily
local trading_day = nil -- 行情登录返回的交易日，entry.lua 的 start_all 设置
local exchanges = {}    -- symbol -> ExchangeID，行情前置不填，由 entry.lua 给
local latest = {}       -- symbol -> { tick, ts }：本交易日最后一笔，写日表用
local dirty = {}        -- 上次写日表后收到过 tick 的合约

local gettimeofday = service.uv.gettimeofday
local function now_us()
    local sec, usec = gettimeofday()
    return sec * 1000000 + usec
end

local function log_error(label, err)
    errors = errors + 1
    if errors == 1 or errors % 1000 == 0 then
        service.log.error("db_writer | %s (%d times): %s", label, errors, tostring(err))
    end
end

--
-- 整理：tick -> 行。无效值在这里处理，写 buffer 时不再判断
--

local function to_row(tick, ts, day)
    return {
        ts = ts,
        symbol = tick.InstrumentID,
        trading_day = day,
        last_price = price(tick.LastPrice),
        volume = int(tick.Volume),
        turnover = amount(tick.Turnover),
        open_interest = int(tick.OpenInterest),
        bid_price1 = price(tick.BidPrice1),
        bid_volume1 = int(tick.BidVolume1),
        ask_price1 = price(tick.AskPrice1),
        ask_volume1 = int(tick.AskVolume1),
    }
end

local function to_daily(symbol, e)
    local d = { ts = e.day_ts, symbol = symbol, exchange_id = exchanges[symbol], updated_at = e.ts }
    for _, c in ipairs(rules.DAILY) do
        local kind, v = c[3], e.tick[c[2]]
        d[c[1]] = (kind == "price" and price or kind == "amount" and amount or int)(v)
    end
    return d
end

--
-- 写 buffer：整数列为 nil 时不写，QuestDB 存为 NULL
--

local function int_column(name, v)
    if v then assert(buffer:int64(name, v)) end
end

local function write_tick(r, insert_at)
    assert(buffer:table(TICK_TABLE))
    assert(buffer:symbol("symbol", r.symbol))
    if r.trading_day then assert(buffer:symbol("trading_day", r.trading_day)) end
    assert(buffer:double("last_price", r.last_price))
    int_column("volume", r.volume)
    assert(buffer:double("turnover", r.turnover))
    int_column("open_interest", r.open_interest)
    assert(buffer:double("bid_price1", r.bid_price1))
    int_column("bid_volume1", r.bid_volume1)
    assert(buffer:double("ask_price1", r.ask_price1))
    int_column("ask_volume1", r.ask_volume1)
    assert(buffer:timestamp_us("insert_at", insert_at))
    assert(buffer:at(us(r.ts)))
end

local function write_daily(d)
    assert(buffer:table(DAILY_TABLE))
    assert(buffer:symbol("symbol", d.symbol))
    if d.exchange_id and d.exchange_id ~= "" then assert(buffer:symbol("exchange_id", d.exchange_id)) end
    for _, c in ipairs(rules.DAILY) do
        if c[3] == "int" then
            int_column(c[1], d[c[1]])
        else
            assert(buffer:double(c[1], d[c[1]]))
        end
    end
    assert(buffer:timestamp_us("updated_at", us(d.updated_at)))
    assert(buffer:at(us(d.ts)))
end

-- 把待发的行写进 buffer 并提交。一行写到一半出错时 buffer 无法撤销半行，
-- 整批丢掉；HTTP 在客户端内部已经重试过，提交仍然失败也丢掉这一批，内存不无限增长。
local function flush()
    local n, nd = #rows, #daily_rows
    if n == 0 and nd == 0 then return end
    local batch, daily = rows, daily_rows
    rows, daily_rows = {}, {}

    local insert_at = us(now_us())
    local ok, err = pcall(function ()
        for i = 1, n do write_tick(batch[i], insert_at) end
        for i = 1, nd do write_daily(daily[i]) end
    end)
    if not ok then
        buffer:clear()
        return log_error(string.format("write failed, %d rows dropped", n + nd), err)
    end
    ok, err = buffer:flush()
    if not ok then
        buffer:clear()
        service.log.error("db_writer | flush failed, %d rows dropped: %s", n + nd, tostring(err))
    end
end

-- 收到过 tick 的合约，把最后一笔排进日表行，按 (ts, symbol) upsert
local function flush_daily()
    for symbol in pairs(dirty) do
        local e = latest[symbol]
        if e and e.day_ts then
            daily_rows[#daily_rows + 1] = to_daily(symbol, e)
        end
        dirty[symbol] = nil
    end
    flush()
end

local flush_timer = service.uv.new_timer()
flush_timer:start(FLUSH_INTERVAL_MS, FLUSH_INTERVAL_MS, flush)

local daily_timer = service.uv.new_timer()
daily_timer:start(DAILY_INTERVAL_MS, DAILY_INTERVAL_MS, flush_daily)

local S = {}

-- collector 每收到一个 tick 发来一次，原样的 CThostFtdcDepthMarketDataField
function S.on_tick(tick)
    -- 本机时间只用来定 ts 的日期，不入库
    local ts = rules.exchange_ts_us(tick.UpdateTime, tick.UpdateMillisec, now_us())
    if not ts then
        -- 算不出时间戳就没法写这一行（指定时间戳必填）
        return log_error("skip " .. tostring(tick.InstrumentID),
            "bad time " .. tostring(tick.UpdateTime) .. "." .. tostring(tick.UpdateMillisec))
    end
    local day = trading_day or (tick.TradingDay ~= "" and tick.TradingDay or nil)
    rows[#rows + 1] = to_row(tick, ts, day)

    latest[tick.InstrumentID] = { tick = tick, ts = ts, day_ts = rules.day_ts_us(day) }
    dirty[tick.InstrumentID] = true

    if #rows >= BATCH_SIZE then
        flush()
    end
end

-- 交易日：夜盘登录返回的是下一个交易日；郑商所 tick 里的 TradingDay 夜盘填自然日。
-- 换了交易日就先把上一个交易日的日表写完。
function S.set_trading_day(day)
    if day and day ~= trading_day then
        flush_daily()
        latest = {}
        trading_day = day
    end
    return true
end

-- 合约的交易所，写日表用：{ [symbol] = ExchangeID }
function S.set_exchanges(map)
    exchanges = map or {}
    return true
end

-- 把日表和待发的行都写出去（entry.lua 的 stop_all 调用）
function S.flush()
    flush_daily()
    return true
end

function S.quit()
    flush_timer:stop()
    flush_timer:close()
    daily_timer:stop()
    daily_timer:close()
    flush_daily()
    sender:close()
    service.quit()
end

return service.dispatch(S)
