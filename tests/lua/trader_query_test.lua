-- Offline tests of the query queue in lua/ctp/templates/trader.lua, with
-- service and service.scheduler replaced by stubs and the 10 s timeouts fired
-- by hand. Run from the repository root: make test-lua.
package.path = "lua/?.lua;lua/?/init.lua;tests/lua/?.lua;" .. package.path

local t = require "check"
local uv = require "luv"

local timeouts = {} -- callbacks given to scheduler:at, in order
local noop = function () end

package.loaded["service.scheduler"] = {
    at = function (self, when, action) timeouts[#timeouts + 1] = action end,
}
package.loaded["service"] = {
    config = { server = { front_addr = "tcp://127.0.0.1:1", broker = "9999", user = "000001", pass = "p" } },
    uv = uv,
    log = { debug = noop, info = noop, warn = noop, error = noop },
    get_async = function () return nil end,
    get_session = function () return coroutine.running() end,
    -- resuming a finished session raises, so a second wake-up fails the test
    resume_session = function (co, ...) assert(coroutine.resume(co, ...)) end,
    yield_session = coroutine.yield,
}

local service = require "service"
local S = require "ctp.templates.trader"
local trader = S._trader

-- Run f(...) as a session; returns a function that waits (driving the uv
-- loop, at most 5 s) until it has finished and returns its results.
local function spawn(f, ...)
    local results
    local co = coroutine.create(function (...) results = { f(...) } end)
    assert(coroutine.resume(co, ...))
    return function ()
        local deadline = uv.now() + 5000
        while coroutine.status(co) ~= "dead" and uv.now() < deadline do
            uv.run("once")
            uv.update_time()
        end
        t.eq(coroutine.status(co), "dead", "session finished")
        return unpack(results or {})
    end
end

-- messages the template's on_idle will receive
local inbox = {}
trader.recv = function () return table.remove(inbox, 1) end

-- 1. a request that cannot be sent fails at once, and its timeout is ignored
do
    trader.trader.connected = 4 -- ready, but never started: req returns -100
    local wait = spawn(S.query_account)
    local rst, err = wait()
    t.eq(rst, nil, "failed send: no result")
    t.eq(err, "trader not started", "failed send: error")
    timeouts[#timeouts]() -- must not resume the finished session
end

-- 2. a bad field fails the request instead of blocking the queue
do
    local wait = spawn(S.query_instrument_margin_rate, string.rep("x", 100))
    local rst, err = wait()
    t.eq(rst, nil, "bad field: no result")
    t.eq(type(err) == "string" and err:find("longer than", 1, true) ~= nil, true, "bad field: error")
    timeouts[#timeouts]()
end

-- 3. a timed-out request leaves the queue; its late response is ignored and
--    the next request gets its own response
do
    local next_id = 100
    trader.req = function () next_id = next_id + 1; return next_id end

    local wait = spawn(S.query_account)
    while next_id == 100 do uv.run("once") end -- until it has been sent
    timeouts[#timeouts]()
    local rst, err = wait()
    t.eq(err, "timedout", "timeout: error")

    local wait2 = spawn(S.query_position)
    while next_id == 101 do uv.run("once") end
    t.eq(next_id, 102, "next request sent after a timeout")

    inbox[#inbox + 1] = { func_name = "OnRspQryTradingAccount", req_id = 101, is_last = true, field = {} }
    inbox[#inbox + 1] = { func_name = "OnRspQryInvestorPosition", req_id = 102, is_last = false,
        field = { InstrumentID = "rb2601" } }
    inbox[#inbox + 1] = { func_name = "OnRspQryInvestorPosition", req_id = 102, is_last = true,
        field = { InstrumentID = "sc2701" } }
    service.on_idle()

    local pos = wait2()
    t.eq(type(pos) == "table" and #pos, 2, "response rows")
    t.eq(pos and pos[2] and pos[2].InstrumentID, "sc2701", "response field")
    timeouts[#timeouts]() -- the second request's timeout, after its response
end

t.done()
