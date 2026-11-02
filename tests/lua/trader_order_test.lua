-- Offline tests of the order path in lua/ctp/templates/trader.lua (trade,
-- nuke, config.query_only), with service and service.scheduler replaced by
-- stubs and trader:order_insert / order_cancel recorded instead of sent.
-- Run from the repository root: make test-lua.
package.path = "lua/?.lua;lua/?/init.lua;tests/lua/?.lua;" .. package.path

local t = require "check"
local uv = require "luv"
local ctp = require "ctp"

local noop = function () end
local timers = {} -- callbacks given to service.set_timeout, in order
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

    local rec = { inserts = {}, cancels = {}, inbox = {} }
    local ref = 0
    trader.order_insert = function (self, symbol, price, volume, flag)
        ref = ref + 1
        rec.inserts[#rec.inserts + 1] = { symbol = symbol, price = price, volume = volume, flag = flag }
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

-- 7. nuke: long positions are sold, short ones bought, both as close orders
do
    local S = load_trader()
    calls = {}
    service.call = function (id, fn, ...)
        calls[#calls + 1] = { fn, ... }
        if fn == "query_position" then
            return {
                { InstrumentID = "rb2601", PosiDirection = ctp.THOST_FTDC_PD_Long, Position = 2 },
                { InstrumentID = "ag2612", PosiDirection = ctp.THOST_FTDC_PD_Short, Position = 3 },
                { InstrumentID = "au2612", PosiDirection = ctp.THOST_FTDC_PD_Long, Position = 0 },
            }
        end
    end
    S.nuke()
    t.eq(#calls, 3, "nuke: one query and two trades")
    t.eq(calls[2][1], "trade", "nuke trades")
    t.eq(calls[2][2], "rb2601", "nuke long symbol")
    t.eq(calls[2][4], -2, "nuke sells the long position")
    t.eq(calls[2][5], ctp.THOST_FTDC_OF_Close, "nuke closes")
    t.eq(calls[3][2], "ag2612", "nuke short symbol")
    t.eq(calls[3][4], 3, "nuke buys back the short position")
end

t.done()
