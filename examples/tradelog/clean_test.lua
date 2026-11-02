-- luajit examples/tradelog/clean_test.lua
package.path = "tests/lua/?.lua;" .. package.path
local check = require "check"
local here = arg[0]:match("^(.*/)") or "./"
local clean = dofile(here .. "clean.lua")

-- 夜盘日期：2026-10-30 周五，2026-11-02 周一，2026-11-03 周二
check.eq(clean.calendar_date("20261102", "09:01:00"), "2026-11-02", "day session")
check.eq(clean.calendar_date("20261102", "14:59:59"), "2026-11-02", "afternoon")
check.eq(clean.calendar_date("20261102", "21:00:00"), "2026-10-30", "monday night is friday")
check.eq(clean.calendar_date("20261102", "01:30:00"), "2026-10-31", "monday past midnight is saturday")
check.eq(clean.calendar_date("20261103", "23:59:59"), "2026-11-02", "tuesday night")
check.eq(clean.calendar_date("20261103", "00:00:00"), "2026-11-03", "tuesday midnight")
check.eq(clean.calendar_date("20260302", "21:00:00"), "2026-02-27", "across month")
check.eq(clean.calendar_date("20260105", "02:00:00"), "2026-01-03", "across year")
check.raises(function () clean.calendar_date("2026-11-02", "09:00:00") end, "bad date", "bad date")
check.raises(function () clean.calendar_date("20261102", "9:00") end, "bad time", "bad time")

local function trade(fields)
    local t = {
        TradingDay = "20261102", InvestorID = "123456", InstrumentID = "rb2601",
        ExchangeID = "SHFE", TradeID = "      12345", Direction = 48,
        TradeTime = "21:05:13", Volume = 2, Price = 3456.2,
    }
    for k, v in pairs(fields or {}) do t[k] = v end
    return t
end

local r = clean.record(trade())
check.eq(r.trade_id, "20261102.SHFE.12345.buy", "trade_id")
check.eq(r.trading_day, "2026-11-02", "trading_day")
check.eq(r.traded_at, "2026-10-30T21:05:13+08:00", "traded_at")
check.eq(r.direction, "buy", "direction buy")
check.eq(clean.record(trade { Direction = 49 }).direction, "sell", "direction sell")
check.raises(function () clean.record(trade { Direction = 50 }) end, "unknown Direction", "bad direction")

check.eq(clean.encode(r, clean.FIELDS),
    '{"trade_id":"20261102.SHFE.12345.buy","investor_id":"123456","trading_day":"2026-11-02",'
    .. '"traded_at":"2026-10-30T21:05:13+08:00","instrument_id":"rb2601","direction":"buy",'
    .. '"volume":2,"price":3456.2,"commission":null}', "encode record")
check.eq(clean.encode(clean.summary("123456", "20261102", 0), clean.SUMMARY_FIELDS),
    '{"summary":true,"investor_id":"123456","trading_day":"2026-11-02","count":0}', "encode summary")
check.eq(clean.encode({ s = 'a"b\\c\n\1' }, { "s" }), '{"s":"a\\"b\\\\c\\n\\u0001"}', "escape")
check.raises(function () clean.encode({ x = 0 / 0 }, { "x" }) end, "non-finite", "nan")

-- 夜盘排在日盘前面，同一时刻按 trade_id
local rs = clean.records {
    trade { TradeID = "3", TradeTime = "09:30:00" },
    trade { TradeID = "2", TradeTime = "21:00:00" },
    trade { TradeID = "1", TradeTime = "21:00:00", Direction = 49 },
}
check.eq(rs[1].trade_id, "20261102.SHFE.1.sell", "sort 1")
check.eq(rs[2].trade_id, "20261102.SHFE.2.buy", "sort 2")
check.eq(rs[3].trade_id, "20261102.SHFE.3.buy", "sort 3")

check.done()
