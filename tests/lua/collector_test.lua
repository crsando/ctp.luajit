-- Offline tests of lua/ctp/templates/collector.lua: service is a stub, the
-- collector's start/stop/subscribe/recv are replaced, and events are fed
-- through service.on_idle as libctpc would queue them. Run from the
-- repository root: make test-lua.
package.path = "lua/?.lua;lua/?/init.lua;tests/lua/?.lua;" .. package.path

local t = require "check"

local timers = {} -- timers made by service.set_timeout, in order
local noop = function () end

package.loaded["service"] = {
    config = { server = { front_addr = "tcp://127.0.0.1:1", broker = "9999", user = "000001" } },
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
        -- fire as libuv would: only while active, then closed
        function timer:fire() if self.active then self.active = false; self.closed = true; self.cb() end end
        timers[#timers + 1] = timer
        return timer
    end,
}

local service = require "service"
local S = require "ctp.templates.collector"
local collector = S._collector

-- the collector, minus libctpc's network side
local inbox = {}
local calls = {}
local start_result = { collector }
collector.start = function (self) calls[#calls + 1] = "start"; return unpack(start_result) end
collector.stop = function (self) calls[#calls + 1] = "stop"; inbox = {} ; return self end
collector.subscribe = function (self, list) calls[#calls + 1] = "subscribe " .. table.concat(list, ","); return 0 end
collector.unsubscribe = function (self, list) calls[#calls + 1] = "unsubscribe " .. table.concat(list, ","); return 0 end
collector.recv = function () return table.remove(inbox, 1) end

local function event(func_name, error_id, field)
    inbox[#inbox + 1] = {
        func_name = func_name,
        field = field,
        rsp_info = error_id and { ErrorID = error_id, ErrorMsg = "msg" } or nil,
    }
end

local function feed(...)
    for _, e in ipairs({ ... }) do event(unpack(e)) end
    service.on_idle()
end

local function take_calls()
    local c = table.concat(calls, "; ")
    calls = {}
    return c
end

-- Start S.start(...) as a session; returns it and a function giving its results.
local function spawn(...)
    local results
    local co = coroutine.create(function (...) results = { S.start(...) } end)
    assert(coroutine.resume(co, ...))
    return co, function () return unpack(results or {}) end
end

-- 1. subscriptions made before start go out once logged in
do
    t.eq(S.subscribe { "rb2601", "sc2701" }, true, "subscribe before start")
    t.eq(take_calls(), "", "nothing sent before login")

    local co, results = spawn()
    t.eq(coroutine.status(co), "suspended", "start waits for login")
    t.eq(S.status().state, "starting", "state while starting")
    t.eq(timers[#timers].ms, 10000, "default start timeout")

    -- a second start while the first is waiting
    local co2, results2 = spawn()
    t.eq(select(2, results2()), "already starting", "concurrent start")

    feed({ "OnFrontConnected" }, { "OnRspUserLogin", 0, {} })
    t.eq(coroutine.status(co), "dead", "start returns after login")
    t.eq(results(), true, "start succeeds")
    t.eq(take_calls(), "start; subscribe rb2601,sc2701", "subscribed after login")
    t.eq(timers[#timers].active, false, "start timeout cancelled")
    t.eq(S.status().state, "ready", "state ready")

    local _, again = spawn()
    t.eq(again(), true, "start while running")
    t.eq(take_calls(), "", "start while running does nothing")
end

-- 2. ticks reach on_tick; a failing on_tick is counted, not fatal
do
    local seen = {}
    S.on_tick = function (tick)
        if tick.InstrumentID == "bad" then error("boom") end
        seen[#seen + 1] = tick.InstrumentID
    end
    feed({ "OnRtnDepthMarketData", nil, { InstrumentID = "bad", LastPrice = 1 } },
         { "OnRtnDepthMarketData", nil, { InstrumentID = "rb2601", LastPrice = 3500 } })
    t.eq(table.concat(seen, ","), "rb2601", "tick after a failing on_tick")
    t.eq(S.get_quotes().rb2601, 3500, "quote updated")
    t.eq(S.status().tick_errors, 1, "on_tick failure counted")
end

-- 3. after a disconnect, logging in again resubscribes the whole set,
--    including symbols added while disconnected
do
    feed({ "OnFrontDisconnected", 0x1001 })
    t.eq(S.status().state, "disconnected", "state after disconnect")
    t.eq(S.subscribe("ag2612"), true, "subscribe while disconnected")
    t.eq(S.unsubscribe("sc2701"), true, "unsubscribe while disconnected")
    t.eq(take_calls(), "", "nothing sent while disconnected")

    feed({ "OnFrontConnected" }, { "OnRspUserLogin", 0, {} })
    t.eq(take_calls(), "subscribe ag2612,rb2601", "resubscribed after reconnect")
    local st = S.status()
    t.eq(st.state, "ready", "ready after reconnect")
    t.eq(st.reconnects, 1, "reconnect counted")
    t.eq(st.subscriptions, 2, "subscription count")

    t.eq(S.subscribe { "rb2601", "i2601" }, true, "subscribe while ready")
    t.eq(take_calls(), "subscribe i2601", "only new symbols sent")
    S.stop()
    t.eq(take_calls(), "stop", "stop")
    t.eq(S.status().state, "stopped", "stopped")
end

-- 4. a rejected login fails start and stops the API
do
    local co, results = spawn()
    feed({ "OnFrontConnected" }, { "OnRspUserLogin", 3, {} })
    local ok, err = results()
    t.eq(ok, nil, "rejected login fails start")
    t.eq(type(err) == "string" and err:find("login failed: 3", 1, true) ~= nil, true, "login error")
    t.eq(take_calls(), "start; stop", "stopped after rejected login")
    t.eq(S.status().state, "stopped", "state after rejected login")
    t.eq(S.status().last_error, "start failed: " .. err, "last_error")
end

-- 5. no login before the timeout: start fails and stops; the late login
--    event is gone with the drained queue
do
    local co, results = spawn { timeout = 500 }
    t.eq(timers[#timers].ms, 500, "custom start timeout")
    feed({ "OnFrontDisconnected", 0x1001 }) -- connection attempts during start are not failures
    t.eq(coroutine.status(co), "suspended", "still waiting after a disconnect")
    timers[#timers]:fire()
    t.eq(select(2, results()), "timedout", "start timed out")
    t.eq(take_calls(), "start; stop", "stopped after timeout")
    feed({ "OnRspUserLogin", 0, {} }) -- must not resume anything
    t.eq(S.status().state, "stopped", "a stray login after stop is ignored")
    t.eq(take_calls(), "", "nothing sent for a stray login")
end

-- 6. stop while starting ends the start
do
    local co, results = spawn()
    S.stop()
    t.eq(select(2, results()), "stopped", "start ended by stop")
    t.eq(take_calls(), "start; stop", "stop while starting")
    timers[#timers]:fire() -- cancelled: must not resume anything
end

-- 7. the API cannot be created
do
    start_result = { nil, "ctp_md_start failed" }
    local _, results = spawn()
    t.eq(select(2, results()), "ctp_md_start failed", "start failure")
    t.eq(take_calls(), "start; stop", "stopped after start failure")
    t.eq(S.status().state, "stopped", "state after start failure")
    start_result = { collector }
end

t.done()
