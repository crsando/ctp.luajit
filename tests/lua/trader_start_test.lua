-- Offline tests of the start logic in lua/ctp/templates/trader.lua: the login
-- chain (authenticate, log in, confirm settlement) is fed as libctpc would
-- queue it, with service stubbed and the start timeout fired by hand. Run
-- from the repository root: make test-lua.
package.path = "lua/?.lua;lua/?/init.lua;tests/lua/?.lua;" .. package.path

local t = require "check"
local uv = require "luv"

local timers = {} -- timers made by service.set_timeout, in order
local noop = function () end

package.loaded["service.scheduler"] = { at = noop }
package.loaded["service"] = {
    config = { server = { front_addr = "tcp://127.0.0.1:1", broker = "9999", user = "000001", pass = "p" } },
    uv = uv,
    log = { debug = noop, info = noop, warn = noop, error = noop },
    get_async = function () return nil end,
    get_session = function () return coroutine.running() end,
    -- resuming a finished session raises, so a second wake-up fails the test
    resume_session = function (co, ...) assert(coroutine.resume(co, ...)) end,
    yield_session = coroutine.yield,
    set_timeout = function (ms, cb)
        local timer = { ms = ms, cb = cb, active = true }
        function timer:stop() self.active = false end
        function timer:close() self.closed = true end
        function timer:fire() if self.active then self.active = false; self.closed = true; self.cb() end end
        timers[#timers + 1] = timer
        return timer
    end,
}

local service = require "service"
local S = require "ctp.templates.trader"
local trader = S._trader

-- the trader, minus libctpc's network side
local inbox = {}
local calls = {}
local start_result = { trader }
trader.start = function (self) calls[#calls + 1] = "start"; return unpack(start_result) end
trader.stop = function (self) calls[#calls + 1] = "stop"; inbox = {}; return self end
trader.recv = function () return table.remove(inbox, 1) end

local function feed(...)
    for _, e in ipairs({ ... }) do
        local func_name, error_id, field = unpack(e)
        inbox[#inbox + 1] = {
            func_name = func_name, req_id = -1, is_last = true, field = field,
            rsp_info = error_id and { ErrorID = error_id, ErrorMsg = "msg" } or nil,
        }
    end
    service.on_idle()
end

local function take_calls()
    local c = table.concat(calls, "; ")
    calls = {}
    return c
end

local function spawn(...)
    local results
    local co = coroutine.create(function (...) results = { S.start(...) } end)
    assert(coroutine.resume(co, ...))
    return co, function () return unpack(results or {}) end
end

local LOGIN = { FrontID = 1, SessionID = 1234, TradingDay = "20261028", MaxOrderRef = "12" }
local CHAIN = { { "OnFrontConnected" }, { "OnRspAuthenticate", 0, {} }, { "OnRspUserLogin", 0, LOGIN } }

-- 1. the whole chain: start returns once the settlement is confirmed
do
    local co, results = spawn()
    t.eq(S.status().state, "starting", "state while starting")
    t.eq(timers[#timers].ms, 10000, "default start timeout")
    local _, results2 = spawn()
    t.eq(select(2, results2()), "already starting", "concurrent start")

    feed(unpack(CHAIN))
    t.eq(coroutine.status(co), "suspended", "not ready before the settlement confirm")
    feed({ "OnRspSettlementInfoConfirm", 0, {} })
    t.eq(results(), true, "start succeeds")
    t.eq(timers[#timers].active, false, "start timeout cancelled")
    local st = S.status()
    t.eq(st.state, "ready", "state ready")
    t.eq(st.session_id, 1234, "session id")
    t.eq(st.trading_day, "20261028", "trading day")

    local _, again = spawn()
    t.eq(again(), true, "start while running")
    t.eq(take_calls(), "start", "one API start")
end

-- 2. reconnect: a new session, counted; a refused login on reconnect is
--    recorded and the template waits for the next reconnect
do
    feed({ "OnFrontDisconnected", 0x2001 })
    t.eq(S.status().state, "disconnected", "state after disconnect")
    feed(CHAIN[1], CHAIN[2], { "OnRspUserLogin", 0, { FrontID = 1, SessionID = 5678, TradingDay = "20261028" } },
        { "OnRspSettlementInfoConfirm", 0, {} })
    local st = S.status()
    t.eq(st.state, "ready", "ready after reconnect")
    t.eq(st.reconnects, 1, "reconnect counted")
    t.eq(st.session_id, 5678, "new session after reconnect")

    feed({ "OnFrontDisconnected", 0x1001 }, CHAIN[1], CHAIN[2], { "OnRspUserLogin", 3 })
    st = S.status()
    t.eq(st.state, "disconnected", "still disconnected after a refused login")
    t.eq(st.last_error ~= nil and st.last_error:find("login failed: 3", 1, true) ~= nil, true, "refused login recorded")
    t.eq(take_calls(), "", "no stop on a refused login after start")

    S.stop()
    t.eq(take_calls(), "stop", "stop")
    t.eq(S.status().state, "stopped", "stopped")
end

-- 3. each step of the chain can fail start; the API is stopped
for _, case in ipairs {
    { { CHAIN[1], { "OnRspAuthenticate", 63 } }, "authenticate failed: 63" },
    { { CHAIN[1], CHAIN[2], { "OnRspUserLogin", 3 } }, "login failed: 3" },
    { { CHAIN[1], CHAIN[2], CHAIN[3], { "OnRspSettlementInfoConfirm", 1 } }, "settlement confirm failed: 1" },
    { { CHAIN[1], { "OnRspAuthenticate", -1 } }, "authenticate failed: -1" }, -- request not sent
} do
    local events, want = case[1], case[2]
    local _, results = spawn()
    feed(unpack(events))
    local ok, err = results()
    t.eq(ok, nil, want .. ": start fails")
    t.eq(type(err) == "string" and err:find(want, 1, true) ~= nil, true, want .. ": error " .. tostring(err))
    t.eq(take_calls(), "start; stop", want .. ": stopped")
    t.eq(S.status().state, "stopped", want .. ": state")
end

-- 4. timeout: disconnects while starting are not failures; the timer is
do
    local co, results = spawn { timeout = 500 }
    t.eq(timers[#timers].ms, 500, "custom start timeout")
    feed({ "OnFrontDisconnected", 0x1001 }, CHAIN[1], { "OnRspError", 4040 })
    t.eq(coroutine.status(co), "suspended", "still waiting after a disconnect")
    timers[#timers]:fire()
    t.eq(select(2, results()), "timedout", "start timed out")
    t.eq(S.status().last_error, "start failed: timedout, last error: 4040 msg", "cause of the timeout kept")
    t.eq(take_calls(), "start; stop", "stopped after timeout")
    feed({ "OnRspSettlementInfoConfirm", 0, {} }, { "OnRspUserLogin", 3 }) -- stale: ignored
    t.eq(S.status().state, "stopped", "stale events after stop ignored")
end

-- 5. stop while starting; the API cannot be created
do
    local _, results = spawn()
    S.stop()
    t.eq(select(2, results()), "stopped", "start ended by stop")
    timers[#timers]:fire() -- cancelled: must not resume anything
    t.eq(take_calls(), "start; stop", "stop while starting")

    start_result = { nil, "ctp_trader_start failed" }
    local _, results2 = spawn()
    t.eq(select(2, results2()), "ctp_trader_start failed", "API start failure")
    t.eq(take_calls(), "start; stop", "stopped after API start failure")
    start_result = { trader }
end

t.done()
