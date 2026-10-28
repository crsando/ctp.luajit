--
-- 交易服务模板
--
--   S.start { timeout = ms }   连接、认证、登录、结算确认；成功返回 true，
--                              失败返回 nil, err（此时已经 stop）
--   S.stop()
--   S.status()                 状态、会话、重连次数、最近一次错误
--   S.query_account() ...      查询，按 1 次/秒流控
--   S.trade(...)               下单并等待结束
--
-- 启动成功之后的断线由 CTP 自动重连、libctpc 自动重走登录链路；断线时正在
-- 执行的查询立即失败，排队中的查询等重新就绪后再发。
--
local inspect = require "inspect"
local ctp = require "ctp"

-- 我自己的库，帮我解决一些编码问题
local iconv = require "iconv"
local cv, err = iconv.open("UTF-8", "GB18030") -- to, from

-- local service = require "lservice3" .input(...)
local service = require "service"
local scheduler = require "service.scheduler"
local uv = service.uv
local config = service.config; do 
        assert(config.server, "no config.server")
        config.auto_disconnect = true
    end

-- read only: 只允许query, 禁止所有 order
local _read_only = config.read_only or true

local function slice(t, k)
    if not t then return nil end
    local o = {}
    for i, e in ipairs(t) do 
        o[i] = e[k]
    end
    return o
end

--
-- internal procedure management
--
local R = {} -- handle trader response
local S = {} -- handle service request/response

--
-- global(per-service) variables
--
local server, trader; do
    server = config.server
    trader = ctp.new_trader(server)
        :async(service.get_async())
    S._trader = trader -- expose
end

local DEFAULT_START_TIMEOUT_MS = 10000

-- state: stopped | starting | ready | disconnected
local status = {
    state = "stopped",
    since = os.time(),
    reconnects = 0,  -- 启动成功后重新就绪的次数
    last_error = nil,
    session = nil,   -- 最近一次登录：FrontID / SessionID / TradingDay / MaxOrderRef
}

--
-- warp query request/response
-- hard rule: one query at a time, a queue is used to ensure this
--
local query = {
    start_index = 1,
    last_index = 0,
    max_length = 100,

    timer = uv.new_timer(),
    timer_wall_ms = nil,
    
    reorder = function(self)
            local s, e = self.start_index, self.last_index
            local n = self.last_index - self.start_index + 1

            local i = 1 
            while i <= n do 
                local tmp = self[self.start_index + i - 1]
                self[self.start_index + i - 1] = nil
                self[i] = tmp
                i = i + 1
            end

            self.start_index = 1 
            self.last_index = n
        end,

    -- entry point
    -- 一个request的链路是这样的
    -- lua 段发出request  -> trader:req(name) -> C-side 执行 ctp_trader_ReqXxx
    -- 此时在query:request() 中会coroutine.yield，把当前service的session挂起
    -- 进而等候OnRspXXXX，这个阶段会由service.on_idle给到handler去处理，如果发现是query类的，通过query:update()收集rsp_info等信息，
    -- 最后确认bLast = True后，通过resume_session，把执行回到对应的session
    -- 此时，在query:request()中，收到的是两个，一个err（0 表示成功），一个rst，后者rst是所有OnRspXXX的结果的一个table。
    --
    -- name 是 CTP 的请求名（ReqXxx 去掉 Req），fields 是请求结构体的字段，见 trader:req()
    request = function(self, name, fields)
            if status.state == "stopped" or status.state == "starting" then
                return "not started", nil
            end
            local co = service.get_session()

            local entity = {
                    session = co,
                    req_id = nil,
                    name = name,
                    fields = fields,
                    cache = {},
                    done = false,
                }

            -- 注意：我们这里永远只是enqueue，我们并不会在这里立即处理
            -- 所有的处理在on_idle里头进行流量控制
            local _, enqueue_err = self:enqueue(entity)
            if enqueue_err then
                return enqueue_err, nil
            end

            -- 这个process本质是在维护一个timer
            -- 如果query中有东西，那么每隔interval_ms就执行一次
            -- 否则就停止timer
            -- 此处的目的是如果还有东西的话，保证timer会继续执行下去
            self:process()

            -- request 的硬性约束：一个request最多接受等待10秒，否则强制结束，避免让一个session一直挂在那里
            scheduler:at(os.time() + 10, function()
                    self:finish(entity, "timedout")
                end)

            --
            -- 正常来说，这里是由 query:finish() 完成 resume
            --
            local err, rst = service.yield_session()

            if err ~= 0 then
                return err, nil
            end

            -- 正常返回值的处理

            --
            -- 现在的策略是：把rst进行一些处理后再返回
            -- 由于rst这里其实是包含了各种rsp_info, req_id之类的东西的，所以我们需要去除，只保留field
            --
            local body = slice(rst, "field")

            -- 需要自己决定是否只取第一个返回结果
            return err, body
        end,

    -- exit point
    -- 一个请求只结束一次：最后一条回报、发送失败、超时，以先到者为准，之后的都忽略。
    -- err: 0 表示成功，否则是错误信息
    finish = function(self, entity, err, rst)
            if entity.done then return end
            entity.done = true
            if self:first() == entity then
                self:dequeue()
            end
            service.resume_session(entity.session, err, rst)
        end,

    -- 断线：正在等回报的请求不会再有回报，立即失败；还没发出的留在队列里
    abort_inflight = function(self, err)
            local q = self:first()
            if q and q.req_id and not q.done then
                self:finish(q, err)
            end
        end,

    enqueue = function(self, entity)
            -- check
            if self.start_index == 1 and self.last_index >= self.max_length then 
                return 0, "too many queries"
            end 

            if self.last_index >= self.max_length then 
                self:reorder()
            end

            -- enqueue first, then process on idle
            do 
                self.last_index = self.last_index + 1
                self[self.last_index] = entity
            end
        end,

    dequeue = function(self)
            self[self.start_index] = nil 
            self.start_index = self.start_index + 1
        end,

    first = function(self)
            if self.last_index >= self.start_index then 
                return self[self.start_index]
            else 
                return nil
            end
        end,

    -- send the real ctp request/query by trader
    process = function(self)
            -- 两次查询之间的最小间隔
            local interval_ms = 1000

            local function get_current_ms()
                local sec, usec = uv.gettimeofday()
                -- sec 是秒，usec 是微秒
                return sec * 1000 + math.floor(usec / 1000)
            end

            local function process_step() 
                -- 我们在这里强制检查
                -- 若trader尚未ready，什么都不做，继续保留在其中
                if not trader:is_ready() then return 0 end
                local q = self:first()
                -- 已经结束（超时）的请求直接丢弃
                while q and q.done do
                    self:dequeue()
                    q = self:first()
                end
                if q and (not q.req_id) then 
                    -- 设置下一次query的最小时间戳，当前时间+1s
                    self.timer_wall_ms = get_current_ms() + interval_ms
                    local ok, rc, err = pcall(trader.req, trader, q.name, q.fields)

                    if not ok then
                        self:finish(q, rc) -- 请求名或字段错误
                    elseif rc < 0 then
                        self:finish(q, err) -- 没有发出去，不会有回报
                    else
                        q.req_id = rc
                    end

                    return 1 -- did something
                else 
                    return 0 -- did nothing
                end
            end

            if not self.timer:is_active() then 
                local curr_ms = get_current_ms()
                local delta_ms; do 
                        delta_ms = (self.timer_wall_ms or curr_ms) - curr_ms
                        delta_ms = (delta_ms > 0) and delta_ms or 0
                    end
                
                self.timer:start(delta_ms, interval_ms, function()
                        if not self:first() then 
                            self.timer:stop()
                        else 
                            process_step()
                        end
                    end)
            end
        end,

    -- 当我们从Trader接收到OnRspXXX这类消息的时候，Update对应的Request Cache，如果is_last，则self:finish完成一个request的处理。
    update = function (self, rsp)
            local q = self:first()

            if not q then return end

            -- check request id for a match, ignore if not matched
            if not ( q.req_id == rsp.req_id ) then 
                service.log.debug("req_id not match, ignore reponse | %s | req_id : %d", rsp.func_name, rsp.req_id)
                return 
            end

            -- cache rst
            do 
                q.cache[#(q.cache) + 1] = rsp
            end

            -- finish query
            if rsp.is_last == true then 
                self:finish(q, 0, q.cache)
            end
        end,
} -- end query object definitions

--
-- 启动与连接状态
--
local function set_state(state)
    if status.state ~= state then
        service.log.debug("trader | state %s -> %s", status.state, state)
        status.state = state
        status.since = os.time()
    end
end

local function fail(err)
    status.last_error = err
    service.log.error("trader | %s", err)
end

local function rsp_error(rsp)
    local info = rsp.rsp_info
    if info and info.ErrorID ~= 0 then
        return string.format("%d %s", info.ErrorID, cv and cv:convert(info.ErrorMsg) or info.ErrorMsg)
    end
    return nil
end

local pending_start = nil -- { session, timer, done }

local function stop_trader()
    query:abort_inflight("stopped")
    trader:stop()
    set_state("stopped")
end

-- start 只结束一次：就绪、登录链路某一步失败、超时或 stop，以先到者为准
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
        -- 超时本身说明不了原因，附上启动期间最后一个错误（如前置握手失败）
        fail("start failed: " .. err .. (p.last_error and (", last error: " .. p.last_error) or ""))
        stop_trader()
    end
    service.resume_session(p.session, ok, err)
end

-- 登录链路中的一步失败：启动中则 start 失败；重连中则只能等 CTP 下一次重连
local function chain_failed(step, err)
    if status.state == "stopped" then return end -- 上一次运行留下的
    err = step .. " failed: " .. err
    if pending_start then
        finish_start(pending_start, nil, err)
    else
        fail(err .. " (waiting for the next reconnect)")
    end
end

function R.OnFrontConnected(rsp)
    service.log.debug("trader | front connected, authenticating")
end

function R.OnRspAuthenticate(rsp)
    local err = rsp_error(rsp)
    if err then return chain_failed("authenticate", err) end
    service.log.debug("trader | authenticated, logging in")
end

function R.OnRspUserLogin(rsp)
    local err = rsp_error(rsp) or (rsp.field == nil and "no login response" or nil)
    if err then return chain_failed("login", err) end
    local f = rsp.field
    status.session = {
        FrontID = f.FrontID,
        SessionID = f.SessionID,
        TradingDay = f.TradingDay,
        MaxOrderRef = f.MaxOrderRef,
    }
    service.log.debug("trader | logged in, FrontID %d SessionID %d TradingDay %s, confirming settlement",
        f.FrontID, f.SessionID, f.TradingDay)
end

function R.OnRspSettlementInfoConfirm(rsp)
    local err = rsp_error(rsp)
    if err then return chain_failed("settlement confirm", err) end
    if status.state == "stopped" then
        return -- 上一次运行留下的（stop 已清空队列，正常不会出现）
    end
    if status.state == "disconnected" then
        status.reconnects = status.reconnects + 1
        service.log.info("trader | ready again (reconnect #%d), SessionID %s",
            status.reconnects, status.session and status.session.SessionID)
    else
        service.log.info("trader | ready")
    end
    set_state("ready")
    if pending_start then
        finish_start(pending_start, true)
    end
end

function R.OnFrontDisconnected(rsp)
    local err = rsp_error(rsp) or "disconnected"
    status.last_error = err
    if pending_start then pending_start.last_error = err end
    query:abort_inflight("disconnected")
    -- 启动中的断线不算失败：CTP 会重连，直到 start 超时
    if status.state == "ready" then
        service.log.warn("trader | %s, waiting for CTP to reconnect", err)
        set_state("disconnected")
    else
        service.log.debug("trader | %s", err)
    end
end

-- opts.timeout: 等待就绪的毫秒数，默认 10000
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
    status.session = nil

    local ok, err = trader:start()
    if not ok then
        fail("start failed: " .. err)
        stop_trader()
        return nil, err
    end

    local p = { session = service.get_session(), done = false }
    -- set_timeout 的定时器触发后会自己关闭
    p.timer = service.set_timeout(timeout, function ()
            p.timer = nil
            finish_start(p, nil, "timedout")
        end)
    pending_start = p

    -- 由 R.OnRspSettlementInfoConfirm、登录链路失败或超时完成 resume
    return service.yield_session()
end

function S.stop()
    if pending_start then
        finish_start(pending_start, nil, "stopped")
    else
        stop_trader()
    end
    return true
end

function S.status()
    local session = status.session
    return {
        state = status.state,
        since = status.since,
        connection = trader:state(), -- libctpc 的连接状态
        reconnects = status.reconnects,
        last_error = status.last_error,
        front_id = session and session.FrontID,
        session_id = session and session.SessionID,
        trading_day = session and session.TradingDay,
    }
end

--
-- query interfaces
--

function S.query_account()
    local err, rst = query:request("QryTradingAccount")
    if rst and rst[1] then 
        return rst[1]
    else 
        return nil, err
    end
end

--[[
/////////////////////////////////////////////////////////////////////////
///TFtdcPosiDirectionType是一个持仓多空方向类型
/////////////////////////////////////////////////////////////////////////
///净
#define THOST_FTDC_PD_Net '1'
///多头
#define THOST_FTDC_PD_Long '2'
///空头
#define THOST_FTDC_PD_Short '3'
]]
function S.query_position()
    local err, rst = query:request("QryInvestorPosition")
    return rst
end

function S.query_instrument_margin_rate(symbol)
    local err, rst = query:request("QryInstrumentMarginRate", { InstrumentID = symbol })
    if rst and rst[1] then 
        return rst[1]
    else 
        return nil, err
    end
end

function S.query_instrument(symbol)
    service.log.debug("S.query_instrument | %s", symbol)
    symbol = symbol or ""

    local ok, rst = query:request("QryInstrument", { InstrumentID = symbol })

    if not rst then return nil end

    -- 由于当前我们只关心期货数据，不关心期权，所以这里做一个非常简单的过滤
    local info = {}; do 
        for _, entry in ipairs(rst) do 
            if entry.ProductClass == ctp.THOST_FTDC_PC_Futures then 
                entry.InstrumentName = cv and cv:convert(entry.InstrumentName) or "" -- workaround for gbk bug
                table.insert(info ,entry)
            end
        end
    end

    rst = info

    if symbol == "" then 
        return rst
    else 
        return (rst and rst[1] or {})
    end
end

function S.query_order()
    local err, rst = query:request("QryOrder")
    if rst and rst[1] then 
        return rst[1]
    else 
        return nil, err 
    end
end

--
-- Order Related Stuffs
-- 

local function trim(s)
    if s == nil then
        return nil
    end
    return s:match("^%s*(.-)%s*$")
end

local function make_order_hashkey(o)
    if o and 
        (o.BrokerID ~= nil) and 
         (o.InvestorID ~= nil) and 
         (o.FrontID ~= nil) and 
         (o.SessionID ~= nil) and 
         (o.OrderRef ~= nil) then  

        local key = string.format("%s+%s+%s+%s+%s",
            trim(o.BrokerID),
            trim(o.InvestorID),
            tostring(o.FrontID),
            tostring(o.SessionID),
            trim(o.OrderRef)
        )

        return key
    else 
        return nil
    end 
end

local function match_order_sysid(o1, o2)
    if (trim(o1.ExchangeID) == trim(o2.ExchangeID)) and 
        (trim(o1.OrderSysID) == trim(o2.OrderSysID)) then 
        return true 
    else 
        return false 
    end
end

-- order book
local order = {
    --
    -- cache 的作用是存放提交中、未交易完成的订单，追踪状态更新
    -- 理论上全部成交后就可以清楚了
    --
    cache = { },

    --
    -- methods
    --
    
    -- 单纯的插入订单，不等待
    insert = function (self, symbol, price, volume, flag)
            local o = trader:order_insert(symbol, price, volume, flag)
            local key = make_order_hashkey(o)
            do 
                o._key = key
                o._symbol = symbol
                o._price = price
                o._volume = volume
                o._flag = flag
            end 
            self.cache[key] = o
            service.log.debug("order inserted %s | %s", key, inspect(o, {newline =""}))
            return o
        end,


    --
    -- 正常交易执行的链路：发起发调用trade/cancel（对应coroutine挂起），结束收到消息后调用finish（coroutine继续）
    --

    -- 执行交易，等待交易完成
    -- return: msg, entry
    trade = function (self, ...)
            local symbol, price, volume, flag
            local n_args = select("#", ...)
            local args = {...}

            args.timeout = tonumber(args.timeout)

            if (n_args == 1) and (type(args[1]) == "table") then 
                args = args[1]
                symbol, price, volume, flag = args.symbol, args.price, args.volume, args.flag
            elseif n_args == 4 then 
                symbol, price, volume, flag = ...
            else 
                return "invalid args", nil
            end

            if not symbol then 
                return "no symbol", nil
            elseif not volume then 
                return "no volume", nil
            end

            -- defaults
            price = price or 0.0 -- 默认市价单
            flag = flag or ctp.THOST_FTDC_OFEN_Open -- 默认开仓

            local o = self:insert(symbol, price, volume, flag)

            if o and o._key then 
                local co = service.get_session()
                self.cache[o._key]._session = co
                
                -- timeout mechanisim

                if args.timeout then 
                    -- 超时自动撤单
                    service.set_timeout(args.timeout, function()
                            -- 注意我们假定 cancel一定会完成，这里不额外的超时处理
                            -- cancel 成功后，会自动执行 order:finish()，进而resume回到下面的coroutine.yield()那里
                            if not o._traded then 
                                self:cancel(o)
                            end
                        end)
                end

                -- wait for order to trade
                -- local msg, entry = service.yield_session()
                local msg, entry = coroutine.yield()
                return msg, entry
            else 
                return "order insertion failed", nil
            end 
        end,

    -- 主动取消一个挂单
    cancel = function (self, ...)
            local o = ...
            service.log.debug("order cancel : %s | %s | %s | %s", o._key, o.InstrumentID, o.ExchangeID, o.OrderSysID)
            trader:order_cancel(o)

            o._status = "timedout"
            -- self:finish(o._key, "timedout")
        end,

    -- 订单结束有几种情况
    -- Time-out: 暂时未实现
    -- Traded: OnRtnTrade + Volume 满足条件
    -- Canceled: 订单被取消
    -- 这个函数不校验（校验在update中进行），而是直接结束这个订单，清理cache
    -- return: ok, error_msg
    finish = function (self, key, msg)
            if not key then return 0, "no key provied" end 

            local entry = self.cache[key]
            if not entry then return 0, "no entry provied" end 

            self.cache[key] = nil  -- release cache

            if entry._session then 
                local co = entry._session
                entry._session = nil -- release session
                service.resume_session( co, msg, entry )
                -- success
                return 1, nil
            else 
                return 0, "no coroutine found"
            end 
        end,

    -- 跟新cache信息，同时判断这个订单是否需要被结束
    update = function (self, rsp)
            local function _merge_entry(dst, src)
                dst = dst or {}
                for k, v in pairs(src) do 
                    dst[k] = src[k] or dst[k]
                end
                return dst
            end 

            local count = 0
            local key = make_order_hashkey(rsp.field)

            -- update entry, create new if needed
            if key then 
                -- Translation
                self.cache[key] = _merge_entry(self.cache[key], rsp.field)
                count = count + 1
            else -- OnRtnTrade has no OrderRef, using ExchangeID and OrderSysID
                for k, entry in pairs(self.cache) do 
                    if match_order_sysid(entry, rsp.field) then 
                        key = k 
                        self.cache[k] = _merge_entry(entry, rsp.field)
                        count = count + 1
                        break
                    end
                end
            end

            if not key then 
                return count, "key match error on update"
            else 
                -- print("update cached ok", key, inspect(self.cache[key]))
            end

            local entry = self.cache[key]
            -- 判断是否需要结束这个订单

            -- 一般是报单阶段产生错误，来自OnRspOrderInsert
            if (trim(rsp.func_name) == "OnRspOrderInsert") and rsp.rsp_info and rsp.rsp_info.ErrorID then 
                service.log.debug("finish order %s | %s", key, "on *insert error*")
                self:finish(key, "invalid: (" .. rsp.rsp_info.ErrorID ..")" )
            -- 仅在OnRtnTrade，且Volume达标（不在OnRtnOrder时结束订单）
            elseif (trim(rsp.func_name) == "OnRtnTrade") and (entry.OrderStatus == ctp.THOST_FTDC_OST_AllTraded) then 
                self.cache[key]._traded = true
                service.log.debug("finish order %s | %s", key, "all-traded")
                self:finish(key, "complete")
            elseif entry.OrderStatus == ctp.THOST_FTDC_OST_Canceled then 
                local error_msg = rsp and rsp.rsp_info and rsp.rsp_info.ErrorMsg or ""
                service.log.debug("finish order %s | %s | %s", key, error_msg, rsp.field.StatusMsg)
                self:finish(key, "canceled")
            end 

            return count
        end,
}


-- Explicit Define OnRtnOrder/OnRtnTrade
function R.OnRtnOrder(rsp) order:update(rsp) end
function R.OnRtnTrade(rsp) order:update(rsp) end
function R.OnRspOrderAction(rsp) order:update(rsp) end

-- Handle Error
function R.OnRspError(rsp)
    local err = rsp_error(rsp)
    if rsp.rsp_info then
        rsp.rsp_info.ErrorMsg = cv and cv:convert(rsp.rsp_info.ErrorMsg) or rsp.rsp_info.ErrorMsg
    end
    service.log.debug("R.OnRspError: %s", inspect(rsp))
    if pending_start and err then
        pending_start.last_error = err
    end
    query:update(rsp)
end

-- 这只在报单异常时才会出现
function R.OnRspOrderInsert(rsp)
    -- 这个巨坑，我们手动补几个字段 
    for k, v in pairs(trader:session_info()) do 
        rsp.field[k] = v
    end

    order:update(rsp)
end

--
-- Fundemental Stuffs
--

function S.quit()
    service.log.debug("trader is quitting")
    if trader then 
        S.stop()
        trader = nil
    end
    service.quit()
end

-- main loop
-- process trader internal messages
function service.on_idle()
    -- process trader messages
    while (trader ~= nil) do 
        local rsp = trader:recv(false) -- non-blocking
        if rsp then 
            -- process trader messages
            local handler = R[rsp.func_name] or function (rsp) query:update(rsp) end 
            local ok, err = pcall(handler, rsp)
            if not ok then
                service.log.error("trader | handling %s failed: %s", rsp.func_name, err)
            end
        else 
            -- exit idle status when there is no remaing messages
            return 
        end
    end
end

-- Nuke Every Existing Positions
function S.nuke()
    local rst = service.call(service.get_id(), "query_position")

    for _, entry in ipairs(rst) do 
        local volume; do 
                volume = entry.Position
                if entry.PosiDirection == ctp.THOST_FTDC_PD_Long then 
                    volume = (-1) * volume
                end
            end
        if volume ~= 0 then 
            -- order:insert(entry.InstrumentID, 0, volume, ctp.THOST_FTDC_OF_Close)
            service.call(service.get_id(), "trade", entry.InstrumentID, 0, volume, ctp.THOST_FTDC_OF_Close)
        end
    end
end

function S.trade(...)
    -- if _read_only then return nil end
    return order:trade(...)
end

return S