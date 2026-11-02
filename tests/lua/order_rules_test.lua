-- Offline tests of lua/ctp/order_rules.lua (pricing and close / open legs).
-- Run from the repository root: make test-lua.
package.path = "lua/?.lua;lua/?/init.lua;tests/lua/?.lua;" .. package.path

local t = require "check"
local ctp = require "ctp"
local rules = require "ctp.order_rules"

local L, S = ctp.THOST_FTDC_PD_Long, ctp.THOST_FTDC_PD_Short
local TD, YD = ctp.THOST_FTDC_PSD_Today, ctp.THOST_FTDC_PSD_History
local OPEN, CLOSE = ctp.THOST_FTDC_OF_Open, ctp.THOST_FTDC_OF_Close
local CTD, CYD = ctp.THOST_FTDC_OF_CloseToday, ctp.THOST_FTDC_OF_CloseYesterday
local DBL_MAX = 1.7976931348623157e308

-- legs as "offset-char x volume", e.g. "4x2 3x1 0x1"
local function legs(l)
    local o = {}
    for _, e in ipairs(l) do o[#o + 1] = string.char(e.offset) .. "x" .. e.volume end
    return table.concat(o, " ")
end

local function pos(symbol, dir, date, n, frozen)
    local p = { InstrumentID = symbol, PosiDirection = dir, PositionDate = date, Position = n }
    p[dir == L and "ShortFrozen" or "LongFrozen"] = frozen or 0
    return p
end

-- prices
do
    t.eq(rules.valid_price(DBL_MAX), false, "DBL_MAX is no price")
    t.eq(rules.valid_price(0), false, "0 is no price")
    t.eq(rules.valid_price(nil), false, "nil is no price")
    t.eq(rules.valid_price(3500), true, "a price")
    t.eq(rules.round_tick(3500.3, 0.2), 3500.4, "round to tick")

    local md = { BidPrice1 = 3965.8, AskPrice1 = 3966.2, LastPrice = 3966,
                 UpperLimitPrice = 4300, LowerLimitPrice = 3500 }
    t.eq(rules.aggressive_price(md, 0.2, "buy", 2), 3966.6, "buy: ask + 2 ticks")
    t.eq(rules.aggressive_price(md, 0.2, "sell", 2), 3965.4, "sell: bid - 2 ticks")
    t.eq(rules.aggressive_price(md, 0.2, "buy"), 3966.2, "no slip: the ask")

    local no_book = { BidPrice1 = DBL_MAX, AskPrice1 = DBL_MAX, LastPrice = 325.9,
                      UpperLimitPrice = DBL_MAX, LowerLimitPrice = DBL_MAX }
    t.eq(rules.aggressive_price(no_book, 0.1, "buy", 2), 326.1, "empty book: last price, no limits")

    local at_limit = { BidPrice1 = 3500, AskPrice1 = 4299, LastPrice = 4000,
                       UpperLimitPrice = 4300, LowerLimitPrice = 3500 }
    t.eq(rules.aggressive_price(at_limit, 1, "buy", 5), 4300, "buy capped at the upper limit")
    t.eq(rules.aggressive_price(at_limit, 1, "sell", 5), 3500, "sell capped at the lower limit")

    local p, err = rules.aggressive_price({ BidPrice1 = DBL_MAX, AskPrice1 = DBL_MAX, LastPrice = DBL_MAX }, 1, "buy", 2)
    t.eq(p, nil, "no price at all")
    t.eq(err, "no price", "no price message")
    t.eq(select(2, rules.aggressive_price(nil, 1, "buy")), "no market data", "no md")
    t.eq(select(2, rules.aggressive_price(md, 0, "buy")), "no price tick", "no tick")
    t.eq(select(2, rules.aggressive_price(md, 1, "hold")), "side must be buy or sell", "bad side")
end

-- close_plan: one lot, the trade.lua cases
do
    t.eq(legs(rules.close_plan({}, "IF2611", "sell", "CFFEX", 1)), "0x1", "flat: sell opens")
    t.eq(legs(rules.close_plan({}, "IF2611", "buy", "CFFEX", 1)), "0x1", "flat: buy opens")
    t.eq(legs(rules.close_plan({ pos("IF2611", L, YD, 1) }, "IF2611", "sell", "CFFEX", 1)), "1x1", "cffex: sell closes long")
    t.eq(legs(rules.close_plan({ pos("IF2611", L, YD, 1) }, "IF2611", "buy", "CFFEX", 1)), "0x1", "cffex: buy with long opens")
    t.eq(legs(rules.close_plan({ pos("IF2611", S, YD, 1) }, "IF2611", "buy", "CFFEX", 1)), "1x1", "cffex: buy closes short")

    local shfe = { pos("cu2612", L, YD, 2), pos("cu2612", L, TD, 1) }
    t.eq(legs(rules.close_plan(shfe, "cu2612", "sell", "SHFE", 1)), "4x1", "shfe: yesterday first")
    t.eq(legs(rules.close_plan(shfe, "cu2612", "sell", "SHFE", 1, { close_today_first = true })), "3x1",
        "shfe: close_today_first")
    t.eq(legs(rules.close_plan({ pos("cu2612", L, TD, 1) }, "cu2612", "sell", "SHFE", 1)), "3x1", "shfe: only today")
    t.eq(legs(rules.close_plan({ pos("sc2612", S, TD, 1) }, "sc2612", "buy", "INE", 1)), "3x1", "ine: close today")
    t.eq(legs(rules.close_plan({ pos("cu2612", L, YD, 1, 1), pos("cu2612", L, TD, 1) }, "cu2612", "sell", "SHFE", 1)),
        "3x1", "shfe: yesterday frozen by a pending close, today closed")
    -- other exchanges report today's lots under PSD_Today too; one '1' closes them
    t.eq(legs(rules.close_plan({ pos("m2701", L, TD, 1) }, "m2701", "sell", "DCE", 1)), "1x1", "dce: today closed with '1'")
end

-- close_plan: several lots, net position
do
    local shfe = { pos("cu2612", L, YD, 2), pos("cu2612", L, TD, 1) }
    t.eq(legs(rules.close_plan(shfe, "cu2612", "sell", "SHFE", 3)), "4x2 3x1", "shfe: split yesterday + today")
    t.eq(legs(rules.close_plan(shfe, "cu2612", "sell", "SHFE", 5)), "4x2 3x1 0x2", "shfe: close all, open the rest")
    t.eq(legs(rules.close_plan(shfe, "cu2612", "sell", "SHFE", 2, { close_today_first = true })), "3x1 4x1",
        "shfe: today first, then yesterday")
    t.eq(legs(rules.close_plan({ pos("IF2611", L, YD, 2) }, "IF2611", "sell", "CFFEX", 3)), "1x2 0x1",
        "sell 3 against 2 long: close 2, open 1")
    t.eq(legs(rules.close_plan({ pos("IF2611", L, YD, 2, 2) }, "IF2611", "sell", "CFFEX", 1)), "0x1",
        "everything already closing: open")

    local _, c = rules.close_plan({ pos("IF2611", L, YD, 3, 1), pos("IF2612", L, YD, 9), pos("IF2611", S, YD, 4) },
        "IF2611", "sell", "CFFEX", 1)
    t.eq(c.held, 3, "held: only this symbol and direction")
    t.eq(c.yd, 2, "closable: frozen taken out")

    t.raises(function () rules.close_plan({}, "IF2611", "sell", "CFFEX", 0) end, "positive integer", "volume 0")
    t.raises(function () rules.close_plan({}, "IF2611", "sell", "CFFEX", 1.5) end, "positive integer", "fractional volume")
    t.raises(function () rules.close_plan({}, "IF2611", "hold", "CFFEX", 1) end, "buy or sell", "bad side")
end

t.done()
