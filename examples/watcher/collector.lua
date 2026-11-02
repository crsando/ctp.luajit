-- watcher 的行情服务：ctp.templates.collector 加上过滤和批量转发，设计见 db_writer.md。
--
--   tick 表：和上一笔相比一档、成交量、持仓量都没变的 tick 丢掉；行情时间偏离
--            本机超过 5 分钟的（订阅时补发的旧快照）丢掉；其余攒成平铺数组，
--            每 batch_ms 发一次 db_writer.on_ticks(trading_day, rows)。
--   日表：   每个合约本节第一笔有效 tick 随下一批发出，之后每 daily_ms 发一次
--            有变化的合约，stop 时再发一次：db_writer.on_daily(list)。
--
-- config：server（必填），writer（默认 "db_writer"），batch_ms（100），
-- max_batch_rows（攒到这么多行立即发，2000），daily_ms（300000），stale_ms（行情时间
-- 偏离本机超过多少毫秒算旧快照，300000；0 表示不过滤，用于 simnow-7x24 这类回放环境）。
local service = require "service"
local rules = require "tick_rules"
local S = require "ctp.templates.collector"

local config = service.config
local WRITER = config.writer or "db_writer"
local BATCH_MS = config.batch_ms or 100
local MAX_BATCH_ROWS = config.max_batch_rows or 2000
local DAILY_MS = config.daily_ms or 300000
local STALE_US = (config.stale_ms or rules.STALE_US / 1000) * 1000

local gettimeofday = service.uv.gettimeofday
local function now_us()
    local sec, usec = gettimeofday()
    return sec * 1000000 + usec
end

local rows, n, batch_day = {}, 0, nil -- 待发的 tick 行（平铺，n 个值）
local last = {}        -- symbol -> 上一笔 tick，判断有没有变化
local fresh = {}       -- symbol -> { tick, ts }：最近一笔有效 tick，写日表用
local daily_new = {}   -- 本节第一次出现、还没写日表的合约
local daily_dirty = {} -- 上次写日表后有变化的合约
local daily_seen = {}  -- 本节已经出现过的合约（stop 时清空）
local exchanges = {}   -- symbol -> ExchangeID（行情前置不填，由 set_exchanges 给）

local counters -- 本节的计数，stop 时打印并清零
local function reset_counters()
    counters = { ticks = 0, rows = 0, batches = 0, unchanged = 0, stale = 0, bad_time = 0 }
end
reset_counters()

local function trading_day(tick)
    local day = S.trading_day()
    if day then return day end
    return tick.TradingDay ~= "" and tick.TradingDay or nil
end

local function send_ticks()
    if n == 0 then return end
    service.send(WRITER, "on_ticks", batch_day, rows)
    counters.batches = counters.batches + 1
    rows, n = {}, 0
end

-- 发出若干集合里的合约的日表行，并清空这些集合
local function send_daily(...)
    local list, done = {}, {}
    for i = 1, select("#", ...) do
        local set = select(i, ...)
        for symbol in pairs(set) do
            local f = fresh[symbol]
            if f and not done[symbol] then
                done[symbol] = true
                list[#list + 1] = rules.daily(f.tick, exchanges[symbol], f.day, f.ts)
            end
            set[symbol] = nil
        end
    end
    if #list > 0 then
        service.send(WRITER, "on_daily", list)
    end
end

local function log_skip(what, count, tick, extra)
    if count == 1 or count % 1000 == 0 then
        service.log.warn("collector | skipped %s tick %s %s (%d times)%s", what,
            tostring(tick.InstrumentID), tostring(tick.UpdateTime), count, extra or "")
    end
end

function S.on_tick(tick)
    counters.ticks = counters.ticks + 1
    local symbol = tick.InstrumentID
    local prev = last[symbol]
    last[symbol] = tick
    if prev and not rules.changed(prev, tick) then
        counters.unchanged = counters.unchanged + 1
        return
    end

    local received_at = now_us()
    local ts = rules.exchange_ts_us(tick.UpdateTime, tick.UpdateMillisec, received_at)
    if not ts then
        counters.bad_time = counters.bad_time + 1
        return log_skip("bad time", counters.bad_time, tick)
    end
    if STALE_US > 0 and math.abs(ts - received_at) > STALE_US then
        counters.stale = counters.stale + 1
        -- 偶尔几条是订阅时的旧快照；持续出现说明本机时钟不准
        return log_skip("stale", counters.stale, tick, ", check the local clock if this keeps growing")
    end

    local day = trading_day(tick)
    fresh[symbol] = { tick = tick, ts = ts, day = day }
    if not daily_seen[symbol] then
        daily_seen[symbol] = true
        daily_new[symbol] = true
    end
    daily_dirty[symbol] = true

    if n == 0 then batch_day = day end
    n = rules.append(rows, n, tick, ts, received_at)
    counters.rows = counters.rows + 1
    if n >= MAX_BATCH_ROWS * rules.STRIDE then
        send_ticks()
    end
end

local batch_timer = service.uv.new_timer()
batch_timer:start(BATCH_MS, BATCH_MS, function ()
    send_ticks()
    send_daily(daily_new)
end)

local daily_timer = service.uv.new_timer()
daily_timer:start(DAILY_MS, DAILY_MS, function ()
    send_daily(daily_dirty)
end)

-- 合约的交易所，写日表用：{ [symbol] = ExchangeID }
function S.set_exchanges(map)
    exchanges = map or {}
    return true
end

-- 本节过滤和转发的计数
function S.stats()
    local t = {}
    for k, v in pairs(counters) do t[k] = v end
    t.pending_rows = n / rules.STRIDE
    return t
end

-- 停止前把攒着的 tick 和日表都发出去；下一节重新写一次日表
local stop = S.stop
function S.stop()
    send_ticks()
    send_daily(daily_new, daily_dirty)
    daily_seen = {}
    if counters.ticks > 0 then
        service.log.info("collector | ticks %d, rows %d in %d batches, unchanged %d, stale %d, bad time %d",
            counters.ticks, counters.rows, counters.batches, counters.unchanged, counters.stale, counters.bad_time)
        reset_counters()
    end
    return stop()
end

local quit = S.quit -- 模板的 quit 会调用上面的 S.stop
function S.quit()
    for _, t in ipairs { batch_timer, daily_timer } do
        if not t:is_closing() then
            t:stop()
            t:close()
        end
    end
    return quit()
end

return S
