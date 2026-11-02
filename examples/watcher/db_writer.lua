-- 把 collector 批量转发的行情写入 QuestDB：tick 表 ctp_tick、日表 ctp_daily。
-- 设计说明见 db_writer.md；建表语句在 ctp_tables.sql，需在第一次写入前执行。
local qdb = require "questdb"
local service = require "service"
local rules = require "tick_rules"

local config = service.config or {}
local QUESTDB_CONF = config.questdb_conf or "http::addr=192.168.5.13:9000;"
local TICK_TABLE = config.tick_table or "ctp_tick"
local DAILY_TABLE = config.daily_table or "ctp_daily"
local BATCH_SIZE = config.batch_size or 1000
local FLUSH_INTERVAL_MS = config.flush_interval_ms or 1000

local price, amount, int = rules.price, rules.amount, rules.int
local us = qdb.time.us
local STRIDE = rules.STRIDE

local sender = assert(qdb.sender { conf = QUESTDB_CONF })
local buffer = assert(sender:buffer())
local write_errors = 0

-- 整数列：无效值不写，QuestDB 存为 NULL
local function int_column(name, v)
    v = int(v)
    if v then assert(buffer:int64(name, v)) end
end

-- 平铺数组 r 中从 i 开始的一行，列顺序见 tick_rules.ROW
local function write_tick(r, i, day)
    assert(buffer:table(TICK_TABLE))
    assert(buffer:symbol("symbol", r[i]))
    if day then assert(buffer:symbol("trading_day", day)) end
    assert(buffer:double("last_price", price(r[i + 3])))
    int_column("volume", r[i + 4])
    assert(buffer:double("turnover", amount(r[i + 5])))
    int_column("open_interest", r[i + 6])
    assert(buffer:double("bid_price1", price(r[i + 7])))
    int_column("bid_volume1", r[i + 8])
    assert(buffer:double("ask_price1", price(r[i + 9])))
    int_column("ask_volume1", r[i + 10])
    assert(buffer:timestamp_us("received_at", us(r[i + 2])))
    assert(buffer:at(us(r[i + 1])))
end

local function write_daily(d)
    local ts = rules.day_ts_us(d.trading_day)
    if not ts then error("bad trading day " .. tostring(d.trading_day)) end
    assert(buffer:table(DAILY_TABLE))
    assert(buffer:symbol("symbol", d.symbol))
    if d.exchange and d.exchange ~= "" then
        assert(buffer:symbol("exchange_id", d.exchange))
    end
    for _, c in ipairs(rules.DAILY) do
        local kind, v = c[3], d[c[2]]
        if kind == "int" then
            int_column(c[1], v)
        else
            assert(buffer:double(c[1], (kind == "price" and price or amount)(v)))
        end
    end
    if d.updated_at then assert(buffer:timestamp_us("updated_at", us(d.updated_at))) end
    assert(buffer:at(us(ts)))
end

-- HTTP 传输在客户端内部已经重试过，仍然失败就丢掉这一批，内存不无限增长。
local function flush()
    local rows = buffer:row_count()
    if rows == 0 then
        return
    end
    local ok, err = buffer:flush()
    if not ok then
        service.log.error("db_writer | flush failed, %d rows dropped: %s", rows, tostring(err))
        buffer:clear()
    end
end

local flush_timer = service.uv.new_timer()
flush_timer:start(FLUSH_INTERVAL_MS, FLUSH_INTERVAL_MS, flush)

-- 一行写到一半失败：buffer 无法撤销半行，只能清空，否则后面每一行都会失败
local function write(f, label, ...)
    local ok, err = pcall(f, ...)
    if not ok then
        write_errors = write_errors + 1
        if write_errors == 1 or write_errors % 1000 == 0 then
            service.log.error("db_writer | write %s failed (%d times), %d buffered rows dropped: %s",
                tostring(label), write_errors, buffer:row_count(), tostring(err))
        end
        buffer:clear()
    end
    if buffer:row_count() >= BATCH_SIZE then
        flush()
    end
end

local S = {}

-- collector 每 100ms 发来一批：trading_day 和平铺的行（tick_rules.ROW）
function S.on_ticks(trading_day, rows)
    for i = 1, #rows, STRIDE do
        write(write_tick, rows[i], rows, i, trading_day)
    end
end

-- 日表行（tick_rules.daily），按 (ts, symbol) upsert
function S.on_daily(list)
    for _, d in ipairs(list) do
        write(write_daily, d.symbol, d)
    end
end

function S.quit()
    flush_timer:stop()
    flush_timer:close()
    flush()
    sender:close()
    service.quit()
end

return service.dispatch(S)
