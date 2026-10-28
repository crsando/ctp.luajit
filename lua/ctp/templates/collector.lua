--
-- 行情服务模板
--
--   S.start { timeout = ms }   连接并登录；成功返回 true，失败返回 nil, err（此时已经 stop）
--   S.subscribe(symbols)       记入订阅集合；已登录时立即订阅，否则登录后再订阅
--   S.unsubscribe(symbols)
--   S.status()                 状态、重连次数、最近一次错误等
--   S.on_tick(tick)            每个 tick 调用一次，由使用者覆盖
--
-- 启动成功之后的断线由 CTP 自动重连、libctpc 自动重新登录，登录后按订阅集合
-- 重新订阅，不需要使用者处理。
--
local ctp = require "ctp"

local service = require "service"
local config = service.config; do
        assert(config.server, "no config.server")
        config.auto_disconnect = true
    end

-- CTP 的错误信息是 GBK；用 iconv.lua 转换，不可用时原样保留（见 ctp.gbk）
local to_utf8 = require("ctp.gbk").to_utf8

local DEFAULT_START_TIMEOUT_MS = 10000
local SUBSCRIBE_BATCH = 100

local S = {}
local collector = ctp.new_collector(config.server)
    :async(service.get_async())
S._collector = collector -- expose

local quotes = {}
local subscriptions = {} -- symbol -> true: 应当订阅的合约，跨重连保留

-- state: stopped | starting | ready | disconnected
local status = {
    state = "stopped",
    since = os.time(),
    reconnects = 0,   -- 启动成功后重新登录的次数
    last_error = nil,
    tick_errors = 0,  -- S.on_tick 抛错的次数
}

local pending_start = nil -- { session, timer, done }

local function set_state(state)
    if status.state ~= state then
        service.log.debug("collector | state %s -> %s", status.state, state)
        status.state = state
        status.since = os.time()
    end
end

local function fail(err)
    status.last_error = err
    service.log.error("collector | %s", err)
end

local function rsp_error(rsp)
    local info = rsp.rsp_info
    if info and info.ErrorID ~= 0 then
        return string.format("%d %s", info.ErrorID, to_utf8(info.ErrorMsg))
    end
    return nil
end

local function symbol_list(symbols)
    if type(symbols) == "string" then
        symbols = { symbols }
    end
    assert(type(symbols) == "table", "symbols: string or table of strings expected")
    for _, s in ipairs(symbols) do
        assert(type(s) == "string" and s ~= "", "symbols: string or table of strings expected")
    end
    return symbols
end

-- 分批发给 CTP；返回 true，或 nil, err（第一个失败的批次）
local function send(method, list)
    for i = 1, #list, SUBSCRIBE_BATCH do
        local batch = { unpack(list, i, math.min(i + SUBSCRIBE_BATCH - 1, #list)) }
        local rc, err = collector[method](collector, batch)
        if rc ~= 0 then
            err = string.format("%s failed: %s", method, err)
            fail(err)
            return nil, err
        end
    end
    return true
end

local function resubscribe()
    local list = {}
    for symbol in pairs(subscriptions) do list[#list + 1] = symbol end
    table.sort(list)
    if #list > 0 then
        service.log.info("collector | subscribing %d symbols", #list)
        send("subscribe", list)
    end
end

local function stop_collector()
    collector:stop()
    set_state("stopped")
end

-- start 只结束一次：登录成功、登录失败、超时或 stop，以先到者为准
local function finish_start(p, ok, err)
    if p.done then return end
    p.done = true
    pending_start = nil
    if p.timer then
        p.timer:stop()
        p.timer:close()
        p.timer = nil
    end
    if not ok then
        fail("start failed: " .. err)
        stop_collector()
    end
    service.resume_session(p.session, ok, err)
end

--
-- 事件处理（ctp_md_recv 的消息，见 ctpc.h）
--
local E = {}

function E.OnFrontConnected(rsp)
    service.log.debug("collector | front connected, logging in")
end

function E.OnRspUserLogin(rsp)
    if status.state == "stopped" then
        return -- 上一次运行留下的（stop 已清空队列，正常不会出现）
    end
    local err = rsp_error(rsp)
    if err then
        err = "login failed: " .. err
        if pending_start then
            finish_start(pending_start, nil, err)
        else
            -- 重连后登录被拒：CTP 不会再自动登录，直到下一次重连
            fail(err)
        end
        return
    end

    if status.state == "disconnected" then
        status.reconnects = status.reconnects + 1
        service.log.info("collector | logged in again (reconnect #%d)", status.reconnects)
    else
        service.log.info("collector | logged in")
    end
    set_state("ready")
    resubscribe()
    if pending_start then
        finish_start(pending_start, true)
    end
end

function E.OnFrontDisconnected(rsp)
    local err = rsp_error(rsp) or "disconnected"
    status.last_error = err
    -- 启动中的断线不算失败：CTP 会重连，直到 start 超时
    if status.state == "ready" then
        service.log.warn("collector | %s, waiting for CTP to reconnect", err)
        set_state("disconnected")
    else
        service.log.debug("collector | %s", err)
    end
end

function E.OnRspSubMarketData(rsp)
    local err = rsp_error(rsp)
    if err then
        fail(string.format("subscribe %s failed: %s", rsp.field and rsp.field.InstrumentID or "?", err))
    end
end

function E.OnRspUnSubMarketData(rsp)
    local err = rsp_error(rsp)
    if err then
        fail(string.format("unsubscribe %s failed: %s", rsp.field and rsp.field.InstrumentID or "?", err))
    end
end

function E.OnRspError(rsp)
    fail("error response: " .. (rsp_error(rsp) or "?"))
end

function E.OnRtnDepthMarketData(rsp)
    local tick = rsp.field
    quotes[tick.InstrumentID] = tick.LastPrice
    -- 这个 on_tick 有可能会被改变，我们每次要取最新的函数，然后pcall
    local ok, err = pcall(S.on_tick, tick)
    if not ok then
        status.tick_errors = status.tick_errors + 1
        if status.tick_errors == 1 or status.tick_errors % 1000 == 0 then
            service.log.error("collector | on_tick failed (%d times): %s", status.tick_errors, err)
        end
    end
end

--
-- service interfaces
--

-- opts.timeout: 等待登录的毫秒数，默认 10000
function S.start(opts)
    if status.state == "ready" or status.state == "disconnected" then
        return true -- 已经在运行；断线时由 CTP 重连
    end
    if status.state == "starting" then
        return nil, "already starting"
    end

    local timeout = opts and opts.timeout or DEFAULT_START_TIMEOUT_MS
    set_state("starting")
    status.last_error = nil
    status.reconnects = 0

    local ok, err = collector:start()
    if not ok then
        fail("start failed: " .. err)
        stop_collector()
        return nil, err
    end

    local p = { session = service.get_session(), done = false }
    -- set_timeout 的定时器触发后会自己关闭
    p.timer = service.set_timeout(timeout, function ()
            p.timer = nil
            finish_start(p, nil, "timedout")
        end)
    pending_start = p

    -- 由 E.OnRspUserLogin 或超时完成 resume
    return service.yield_session()
end

function S.stop()
    if pending_start then
        finish_start(pending_start, nil, "stopped")
    else
        stop_collector()
    end
    return true
end

function S.quit()
    S.stop()
    service.quit()
end

-- 返回 true，或 nil, err（CTP 拒绝了请求；合约仍留在集合里，重连后会再订阅）
function S.subscribe(symbols)
    local new = {}
    for _, symbol in ipairs(symbol_list(symbols)) do
        if not subscriptions[symbol] then
            subscriptions[symbol] = true
            new[#new + 1] = symbol
        end
    end
    if status.state == "ready" and #new > 0 then
        return send("subscribe", new)
    end
    return true
end

function S.unsubscribe(symbols)
    local gone = {}
    for _, symbol in ipairs(symbol_list(symbols)) do
        if subscriptions[symbol] then
            subscriptions[symbol] = nil
            quotes[symbol] = nil
            gone[#gone + 1] = symbol
        end
    end
    if status.state == "ready" and #gone > 0 then
        return send("unsubscribe", gone)
    end
    return true
end

function S.status()
    local n = 0
    for _ in pairs(subscriptions) do n = n + 1 end
    return {
        state = status.state,
        since = status.since,
        connection = collector:state(), -- libctpc 的连接状态
        reconnects = status.reconnects,
        last_error = status.last_error,
        subscriptions = n,
        ticks_dropped = collector:ticks_dropped(),
        tick_errors = status.tick_errors,
    }
end

function S.get_quotes()
    return quotes
end

-- placeholder
-- default implementation, needs reload
function S.on_tick(tick)
    -- do nothing
end

function service.on_idle()
    while true do
        local rsp = collector:recv(false) -- non-blocking
        if rsp == nil then break end  -- no data, break while loop
        local handler = E[rsp.func_name]
        if handler then
            handler(rsp)
        else
            service.log.debug("collector | unhandled %s", rsp.func_name)
        end
    end
end


return S
