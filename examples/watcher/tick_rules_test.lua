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
    t.eq(rules.exchange_ts_us("15:00:00", 0, 1793624400000000), 1793602800000000, "old snapshot keeps its time")
    -- 2026-11-03 12:10 restarts and receives last night's 20:59 auction snapshot: 2026-11-02, not tonight
    t.eq(rules.exchange_ts_us("20:59:00", 0, 1793679000000000), 1793624340000000, "old night snapshot is yesterday")
    -- 20:55 receives an 18:43 snapshot: same day, 2 h old
    t.eq(rules.exchange_ts_us("18:43:16", 45, 1793710500000000), 1793702596045000, "old snapshot earlier today")
    -- 08:50 receives the 02:30 SHFE close: same day
    t.eq(rules.exchange_ts_us("02:30:00", 0, 1793667000000000), 1793644200000000, "night close after midnight")
    -- local clock 5 min slow: still today; one second more is yesterday
    t.eq(rules.exchange_ts_us("09:05:00", 0, 1793667600000000), 1793667900000000, "clock slow by CLOCK_SKEW")
    t.eq(rules.exchange_ts_us("09:05:01", 0, 1793667600000000), 1793581501000000, "beyond CLOCK_SKEW is yesterday")
    -- 2026-11-03 23:58 (clock 5 min slow) receives 00:03: the day after
    t.eq(rules.exchange_ts_us("00:03:00", 0, 1793721480000000), 1793721780000000, "slow clock across midnight")

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

-- daily columns: every column maps a CTP field to a known kind
do
    local seen = {}
    for _, c in ipairs(rules.DAILY) do
        t.eq(rules[c[3]] ~= nil, true, "daily kind " .. c[1])
        t.eq(seen[c[1]], nil, "daily column unique " .. c[1])
        seen[c[1]] = true
    end
end

t.done()
