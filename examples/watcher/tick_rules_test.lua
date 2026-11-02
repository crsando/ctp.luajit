-- Offline tests of examples/watcher/tick_rules.lua. Run from the repository
-- root: make test-lua. Expected timestamps were computed with Python's datetime.
package.path = "examples/watcher/?.lua;tests/lua/?.lua;" .. package.path

local t = require "check"
local rules = require "tick_rules"

local DBL_MAX = 1.7976931348623157e308
local function isnan(v) return v ~= v end

-- exchange_ts_us: the date comes from the local clock, not ActionDay
do
    local now = 1793631900000000 -- 2026-11-02 23:05:00 +08:00
    t.eq(rules.exchange_ts_us("23:04:59", 500, now), 1793631899500000, "same day")
    t.eq(rules.exchange_ts_us("23:04:59", nil, now), 1793631899000000, "no millis")
    -- 2026-11-03 00:00:01 receives 23:59:59: the day before
    t.eq(rules.exchange_ts_us("23:59:59", 0, 1793635201000000), 1793635199000000, "across midnight, late tick")
    -- 2026-11-02 23:59:59 receives 00:00:00.500: the day after
    t.eq(rules.exchange_ts_us("00:00:00", 500, 1793635199000000), 1793635200500000, "across midnight, early clock")
    -- 21:00 receives the 15:00 close snapshot: same day, 6 h old
    local ts = rules.exchange_ts_us("15:00:00", 0, 1793624400000000)
    t.eq(ts, 1793602800000000, "old snapshot keeps its time")
    t.eq(math.abs(ts - 1793624400000000) > rules.STALE_US, true, "old snapshot is stale")
    t.eq(math.abs(rules.exchange_ts_us("23:04:59", 0, now) - now) > rules.STALE_US, false, "live tick is fresh")

    t.eq(rules.exchange_ts_us("9:00:00", 0, now), nil, "bad time format")
    t.eq(rules.exchange_ts_us("", 0, now), nil, "empty time")
    t.eq(rules.exchange_ts_us(nil, 0, now), nil, "no time")
    t.eq(rules.exchange_ts_us("09:00:00", 1000, now), nil, "millis out of range")
    t.eq(rules.exchange_ts_us("09:00:00", 1.5, now), nil, "fractional millis")
end

-- day_ts_us: Beijing midnight of the trading day
do
    t.eq(rules.day_ts_us("20261103"), 1793635200000000, "trading day")
    t.eq(rules.day_ts_us("20000301"), 951840000000000, "leap century")
    t.eq(rules.day_ts_us("2026-11-03"), nil, "bad trading day")
    t.eq(rules.day_ts_us(nil), nil, "no trading day")
end

-- invalid values
do
    t.eq(isnan(rules.price(DBL_MAX)), true, "price DBL_MAX")
    t.eq(isnan(rules.price(0)), true, "price 0 (empty level)")
    t.eq(isnan(rules.price(nil)), true, "price nil")
    t.eq(rules.price(3965.4), 3965.4, "price")
    t.eq(rules.amount(0), 0, "amount 0 is valid")
    t.eq(isnan(rules.amount(DBL_MAX)), true, "amount DBL_MAX")
    t.eq(rules.int(123456.0), 123456, "int from double")
    t.eq(rules.int(0), 0, "int 0")
    t.eq(rules.int(DBL_MAX), nil, "int DBL_MAX")
    t.eq(rules.int(1.5), nil, "int fractional")
    t.eq(rules.int(-1), nil, "int negative")
end

-- changed / append / daily
local function tick(o)
    local base = {
        InstrumentID = "IF2611", TradingDay = "20261103", UpdateTime = "23:04:59", UpdateMillisec = 500,
        LastPrice = 3965, Volume = 100, Turnover = 1.2e8, OpenInterest = 5000,
        BidPrice1 = 3964.8, BidVolume1 = 3, AskPrice1 = 3965.2, AskVolume1 = 4,
        PreSettlementPrice = 3950, PreClosePrice = 3951, PreOpenInterest = 4900,
        UpperLimitPrice = 4345, LowerLimitPrice = 3555, OpenPrice = 3955,
        HighestPrice = 3970, LowestPrice = 3940, ClosePrice = DBL_MAX, SettlementPrice = DBL_MAX,
        BidPrice2 = 3964.6, AveragePrice = 3960,
    }
    for k, v in pairs(o or {}) do base[k] = v end
    return base
end

do
    local a = tick()
    t.eq(rules.changed(a, tick()), false, "identical")
    t.eq(rules.changed(a, tick { UpdateTime = "23:05:00", Turnover = 9 }), false, "only time / turnover: unchanged")
    t.eq(rules.changed(a, tick { BidPrice2 = 1 }), false, "level 2 ignored")
    for _, k in ipairs { "LastPrice", "Volume", "OpenInterest", "BidPrice1", "BidVolume1", "AskPrice1", "AskVolume1" } do
        t.eq(rules.changed(a, tick { [k] = a[k] + 1 }), true, "changed " .. k)
    end

    local rows = {}
    local n = rules.append(rows, 0, a, 11, 22)
    n = rules.append(rows, n, tick { InstrumentID = "cu2612" }, 33, 44)
    t.eq(n, 2 * rules.STRIDE, "append: two rows")
    t.eq(rules.STRIDE, 11, "stride")
    t.eq(#rows, n, "append: flat")
    t.eq(rows[1], "IF2611", "row: symbol")
    t.eq(rows[2], 11, "row: ts")
    t.eq(rows[3], 22, "row: received_at")
    t.eq(rows[11], 4, "row: ask volume last")
    t.eq(rows[rules.STRIDE + 1], "cu2612", "row 2: symbol")
    -- ROW names the values in order
    local fields = { "InstrumentID", false, false, "LastPrice", "Volume", "Turnover", "OpenInterest",
        "BidPrice1", "BidVolume1", "AskPrice1", "AskVolume1" }
    for i, f in ipairs(fields) do
        if f then t.eq(rows[i], a[f], "row " .. rules.ROW[i]) end
    end

    local d = rules.daily(a, "CFFEX", "20261103", 99)
    t.eq(d.symbol, "IF2611", "daily: symbol")
    t.eq(d.exchange, "CFFEX", "daily: exchange")
    t.eq(d.trading_day, "20261103", "daily: trading day")
    t.eq(d.updated_at, 99, "daily: updated_at")
    t.eq(d.PreSettlementPrice, 3950, "daily: pre settlement")
    t.eq(d.UpperLimitPrice, 4345, "daily: upper limit")
    t.eq(d.BidPrice1, nil, "daily: no book")
    t.eq(d.AveragePrice, nil, "daily: no average price")
    local n2 = 0
    for _ in pairs(d) do n2 = n2 + 1 end
    t.eq(n2, 4 + #rules.DAILY, "daily: only the daily fields")
end

t.done()
