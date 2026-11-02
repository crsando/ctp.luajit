-- Offline tests of the order path in lua/ctp/templates/trader.lua (trade, place,
-- nuke, config.query_only), with service and service.scheduler replaced by
-- stubs and trader:order_insert / order_cancel recorded instead of sent.
-- Run from the repository root: make test-lua.
package.path = "lua/?.lua;lua/?/init.lua;tests/lua/?.lua;" .. package.path

local t = require "check"
local uv = require "luv"
local ctp = require "ctp"

local noop = function () end
local timers = {} -- callbacks given to service.set_timeout, in order
local timer_ms = {} -- and their delays
local calls = {}  -- service.call(self, ...) made by the template

package.loaded["service.scheduler"] = { at = noop }
local service = {
    uv = uv,
    log = { debug = noop, info = noop, warn = noop, error = noop },
    get_id = function () return 3 end,
    get_async = function () return nil end,
    get_session = function () return coroutine.running() end,
    -- resuming a finished session raises, so a second wake-up fails the test
    resume_session = function (co, ...) assert(coroutine.resume(co, ...)) end,
    yield_session = coroutine.yield,
    set_timeout = function (ms, cb)
        timers[#timers + 1] = cb
        timer_ms[#timers] = ms
        return { stop = noop, close = noop }
    end,
}
package.loaded["service"] = service

-- Load a fresh copy of the template with the given extra config; the
-- template reads config once at load time.
local function load_trader(extra)
    local config = { server = { front_addr = "tcp://127.0.0.1:1", broker = "9999", user = "000001", pass = "p" } }
    for k, v in pairs(extra or {}) do config[k] = v end
    service.config = config
    package.loaded["ctp.templates.trader"] = nil
    local S = require "ctp.templates.trader"
    local trader = S._trader

    -- rec.fail: the error the next inserts fail with, as trader:order_insert
    -- does when the request cannot be sent
    local rec = { inserts = {}, cancels = {}, inbox = {} }
    local ref = 0
    trader.order_insert = function (self, symbol, price, volume, flag)
        rec.inserts[#rec.inserts + 1] = { symbol = symbol, price = price, volume = volume, flag = flag }
        if rec.fail then return nil, rec.fail end
        ref = ref + 1
        return { BrokerID = "9999", InvestorID = "000001", FrontID = 1, SessionID = 2,
                 OrderRef = string.format("%012d", ref) }
    end
    trader.order_cancel = function (self, o) rec.cancels[#rec.cancels + 1] = o end
    trader.session_info = function () return { BrokerID = "9999", InvestorID = "000001", FrontID = 1, SessionID = 2 } end
    trader.recv = function () return table.remove(rec.inbox, 1) end
    return S, rec
end

-- Run f(...) as a session; returns a function giving its results once done.
local function spawn(f, ...)
    local results
    local co = coroutine.create(function (...) results = { f(...) } end)
    assert(coroutine.resume(co, ...))
    return function ()
        t.eq(coroutine.status(co), "dead", "session finished")
        return unpack(results or {})
    end, co
end

-- order fields as CTP reports them for the n-th order of a fresh template
local function order_field(n, extra)
    local f = { BrokerID = "9999", InvestorID = "000001", FrontID = 1, SessionID = 2,
                OrderRef = string.format("%012d", n), ExchangeID = "SHFE", OrderSysID = "  " .. n }
    for k, v in pairs(extra or {}) do f[k] = v end
    return f
end

-- 1. query_only: trade and nuke refuse without sending or querying anything
do
    local S, rec = load_trader { query_only = true }
    calls = {}
    service.call = function (id, ...) calls[#calls + 1] = { ... } end

    -- run as sessions: without the guard trade would suspend instead of failing
    local msg, entry = spawn(S.trade, "rb2601", 3500, 1, ctp.THOST_FTDC_OFEN_Open)()
    t.eq(msg, "query only", "query_only: trade refused")
    t.eq(entry, nil, "query_only: trade no entry")
    msg = spawn(S.trade, { symbol = "rb2601", price = 0, volume = -1 })()
    t.eq(msg, "query only", "query_only: trade(table) refused")

    local ok, err = spawn(S.nuke)()
    t.eq(ok, nil, "query_only: nuke refused")
    t.eq(err, "query only", "query_only: nuke error")

    t.eq(#rec.inserts, 0, "query_only: no order inserted")
    t.eq(#rec.cancels, 0, "query_only: no order cancelled")
    t.eq(#calls, 0, "query_only: nuke made no service calls")
end

-- 2. query_only must be exactly true; a truthy string does not switch it on
do
    local S, rec = load_trader { query_only = "yes" }
    spawn(S.trade, "rb2601", 3500, 1, ctp.THOST_FTDC_OFEN_Open)
    t.eq(#rec.inserts, 1, "query_only='yes' still trades")
end

-- 3. default: a limit order is inserted, then completes on OnRtnTrade
do
    local S, rec = load_trader()
    local wait, co = spawn(S.trade, "rb2601", 3500, 2, ctp.THOST_FTDC_OFEN_Open)
    t.eq(#rec.inserts, 1, "default: order inserted")
    t.eq(rec.inserts[1].symbol, "rb2601", "insert symbol")
    t.eq(rec.inserts[1].price, 3500, "insert price")
    t.eq(rec.inserts[1].volume, 2, "insert volume")
    t.eq(coroutine.status(co), "suspended", "trade waits for the fill")

    rec.inbox[#rec.inbox + 1] = { func_name = "OnRtnOrder",
        field = order_field(1, { OrderStatus = ctp.THOST_FTDC_OST_AllTraded }) }
    service.on_idle()
    t.eq(coroutine.status(co), "suspended", "OnRtnOrder alone does not finish")

    rec.inbox[#rec.inbox + 1] = { func_name = "OnRtnTrade", field = { ExchangeID = "SHFE", OrderSysID = "  1" } }
    service.on_idle()
    local msg, entry = wait()
    t.eq(msg, "complete", "trade complete")
    t.eq(entry and entry._symbol, "rb2601", "entry carries the order")
end

-- 4. defaults: price 0 (market) and open flag
do
    local S, rec = load_trader()
    spawn(S.trade, { symbol = "rb2601", volume = -1 })
    t.eq(rec.inserts[1].price, 0, "default price is 0 (market)")
    t.eq(rec.inserts[1].flag, ctp.THOST_FTDC_OFEN_Open, "default flag is open")
end

-- 5. a rejected insert finishes with the CTP error id
do
    local S, rec = load_trader()
    local wait = spawn(S.trade, "rb2601", 3500, 1, ctp.THOST_FTDC_OFEN_Open)
    rec.inbox[#rec.inbox + 1] = { func_name = "OnRspOrderInsert",
        field = { OrderRef = string.format("%012d", 1) }, rsp_info = { ErrorID = 31, ErrorMsg = "" } }
    service.on_idle()
    t.eq(wait(), "invalid: (31)", "insert rejected")
end

-- 6. timeout: cancel is sent, the order finishes as canceled
do
    local S, rec = load_trader()
    timers = {}
    local wait, co = spawn(S.trade, { symbol = "rb2601", price = 3500, volume = 1, timeout = 500 })
    t.eq(#timers, 1, "timeout armed")
    timers[1]()
    t.eq(#rec.cancels, 1, "cancel sent on timeout")
    t.eq(coroutine.status(co), "suspended", "waits for the cancel to be confirmed")

    rec.inbox[#rec.inbox + 1] = { func_name = "OnRtnOrder",
        field = order_field(1, { OrderStatus = ctp.THOST_FTDC_OST_Canceled }) }
    service.on_idle()
    t.eq(wait(), "canceled", "trade canceled after timeout")
end

-- 6b. timeout: only the table form takes one; the positional form arms none
do
    local S = load_trader()
    timers = {}
    spawn(S.trade, "rb2601", 3500, 1, ctp.THOST_FTDC_OFEN_Open)
    t.eq(#timers, 0, "positional trade: no timeout")
    spawn(S.trade, { symbol = "rb2601", price = 3500, volume = 1, timeout = "250" })
    t.eq(#timers, 1, "timeout given as a string")
    t.eq(timer_ms[1], 250, "timeout converted to a number")
end

-- 6c. an insert that cannot be sent fails at once and leaves nothing behind
do
    local S, rec = load_trader()
    rec.fail = "too many requests per second"
    local msg, entry = spawn(S.trade, "rb2601", 3500, 1, ctp.THOST_FTDC_OFEN_Open)()
    t.eq(msg, "order insertion failed: too many requests per second", "send failure returned")
    t.eq(entry, nil, "send failure: no entry")
    t.eq(next(S._order.cache), nil, "send failure: nothing cached")
    local o, err = S._order:insert("rb2601", 3500, 1, ctp.THOST_FTDC_OFEN_Open)
    t.eq(o, nil, "insert: nil on failure")
    t.eq(err, "too many requests per second", "insert: error on failure")

    rec.fail = nil
    local wait = spawn(S.trade, "rb2601", 3500, 1, ctp.THOST_FTDC_OFEN_Open)
    rec.inbox[#rec.inbox + 1] = { func_name = "OnRtnOrder",
        field = order_field(1, { OrderStatus = ctp.THOST_FTDC_OST_Canceled }) }
    service.on_idle()
    t.eq(wait(), "canceled", "next order after a failure works")
end

-- place / nuke: queries replaced, order:trade recorded and answered by
-- fills; each leg { symbol, price, volume, flag, timeout }
local DBL_MAX = 1.7976931348623157e308
local function stub_market(S, positions, opts)
    opts = opts or {}
    local rec = { legs = {}, queries = 0 }
    local inst = {
        IF2611 = { InstrumentID = "IF2611", ExchangeID = "CFFEX", PriceTick = 0.2 },
        cu2612 = { InstrumentID = "cu2612", ExchangeID = "SHFE", PriceTick = 10 },
    }
    S.query_instrument = function (symbol)
        rec.queries = rec.queries + 1
        return inst[symbol] or {}
    end
    S.query_position = function () return positions end
    S.query_depth_market_data = function (symbol)
        if opts.no_md then return nil, "no market data" end
        return { BidPrice1 = 3965.8, AskPrice1 = 3966.2, LastPrice = 3966,
                 UpperLimitPrice = DBL_MAX, LowerLimitPrice = DBL_MAX }
    end
    local results = opts.results or {}
    S._order.trade = function (self, args)
        rec.legs[#rec.legs + 1] = args
        return results[#rec.legs] or "complete", { OrderSysID = tostring(#rec.legs) }
    end
    return rec
end

local L, Sh = ctp.THOST_FTDC_PD_Long, ctp.THOST_FTDC_PD_Short
local TD, YD = ctp.THOST_FTDC_PSD_Today, ctp.THOST_FTDC_PSD_History

-- 7. place: flat -> open at the aggressive price
do
    local S = load_trader()
    local rec = stub_market(S, {})
    local p = S.place("sell", "IF2611", 1)
    t.eq(p.ok, true, "place ok")
    t.eq(#rec.legs, 1, "place: one leg")
    t.eq(rec.legs[1].flag, ctp.THOST_FTDC_OF_Open, "place: flat opens")
    t.eq(rec.legs[1].volume, -1, "place: sell is negative")
    t.eq(rec.legs[1].price, 3965.4, "place: bid - 2 ticks")
    t.eq(rec.legs[1].timeout, 5000, "place: default timeout")
    t.eq(p.legs[1].msg, "complete", "place: leg result kept")
    t.eq(p.exchange, "CFFEX", "place: exchange")

    S.place("buy", "IF2611", 1, { slip_ticks = 0, timeout = 800 })
    t.eq(rec.legs[2].price, 3966.2, "place: slip_ticks option")
    t.eq(rec.legs[2].timeout, 800, "place: timeout option")
    t.eq(rec.queries, 1, "place: instrument cached")
end

-- 8. place: net position, SHFE split, stop on a failed leg
do
    local S = load_trader()
    local rec = stub_market(S, {
        { InstrumentID = "cu2612", PosiDirection = L, PositionDate = YD, Position = 2, ShortFrozen = 0 },
        { InstrumentID = "cu2612", PosiDirection = L, PositionDate = TD, Position = 1, ShortFrozen = 0 },
    })
    local p = S.place("sell", "cu2612", 4)
    t.eq(#rec.legs, 3, "net: three legs")
    t.eq(rec.legs[1].flag, ctp.THOST_FTDC_OF_CloseYesterday, "net: close yesterday first")
    t.eq(rec.legs[1].volume, -2, "net: yesterday 2")
    t.eq(rec.legs[2].flag, ctp.THOST_FTDC_OF_CloseToday, "net: then today")
    t.eq(rec.legs[3].flag, ctp.THOST_FTDC_OF_Open, "net: open the rest")
    t.eq(rec.legs[3].volume, -1, "net: open 1")
    t.eq(p.ok, true, "net: ok")

    rec = stub_market(S, {
        { InstrumentID = "cu2612", PosiDirection = L, PositionDate = YD, Position = 2, ShortFrozen = 0 },
    }, { results = { "canceled" } })
    p = S.place("sell", "cu2612", 3)
    t.eq(#rec.legs, 1, "failed leg: stops")
    t.eq(p.ok, false, "failed leg: not ok")
    t.eq(p.error, "leg 1 (close_yesterday 2): canceled", "failed leg: error")
end

-- 9. place: dry run, bad input, query_only
do
    local S = load_trader()
    local rec = stub_market(S, {})
    local p = S.place("buy", "IF2611", 1, { dry_run = true })
    t.eq(#rec.legs, 0, "dry run: nothing sent")
    t.eq(p.legs[1].offset, ctp.THOST_FTDC_OF_Open, "dry run: plan")
    t.eq(p.ok, nil, "dry run: not executed")

    t.eq(select(2, S.place("hold", "IF2611", 1)), "side must be buy or sell", "bad side")
    t.eq(select(2, S.place("buy", "IF2611", 0)), "volume must be a positive integer", "bad volume")
    t.eq(select(2, S.place("buy", "xx9999", 1)), "unknown instrument xx9999", "unknown instrument")
    stub_market(S, {}, { no_md = true })
    t.eq(select(2, S.place("buy", "IF2611", 1)), "query_depth_market_data: no market data", "no market data")

    S = load_trader { query_only = true }
    rec = stub_market(S, {})
    t.eq(select(2, S.place("buy", "IF2611", 1)), "query only", "query_only: place refused")
    t.eq(S.place("buy", "IF2611", 1, { dry_run = true }).legs[1].volume, 1, "query_only: dry run allowed")
    t.eq(#rec.legs, 0, "query_only: nothing sent")
end

-- 10. nuke: every position closed by exchange rules, nothing opened
do
    local S = load_trader()
    local rec = stub_market(S, {
        { InstrumentID = "cu2612", PosiDirection = L, PositionDate = YD, Position = 1, ShortFrozen = 0 },
        { InstrumentID = "cu2612", PosiDirection = L, PositionDate = TD, Position = 2, ShortFrozen = 0 },
        { InstrumentID = "IF2611", PosiDirection = Sh, PositionDate = YD, Position = 3, LongFrozen = 1 },
        { InstrumentID = "IF2611", PosiDirection = L, PositionDate = YD, Position = 0, ShortFrozen = 0 },
    })
    local r = S.nuke()
    t.eq(#r, 2, "nuke: one result per symbol and direction")
    t.eq(#rec.legs, 3, "nuke: three legs")
    t.eq(rec.legs[1].flag, ctp.THOST_FTDC_OF_CloseYesterday, "nuke: shfe yesterday")
    t.eq(rec.legs[1].volume, -1, "nuke: sells the long")
    t.eq(rec.legs[2].flag, ctp.THOST_FTDC_OF_CloseToday, "nuke: shfe today with '3'")
    t.eq(rec.legs[2].volume, -2, "nuke: today 2")
    t.eq(rec.legs[3].flag, ctp.THOST_FTDC_OF_Close, "nuke: cffex close")
    t.eq(rec.legs[3].volume, 2, "nuke: buys back what is not already closing")
    t.eq(r[1].ok and r[2].ok, true, "nuke: ok")

    stub_market(S, {
        { InstrumentID = "IF2611", PosiDirection = Sh, PositionDate = YD, Position = 1, LongFrozen = 1 },
    })
    r = S.nuke()
    t.eq(r[1].error, "all closing", "nuke: fully frozen skipped")

    S.query_position = function () return nil end
    t.eq(select(2, S.nuke()), "query_position failed", "nuke: query failure")
end

t.done()
