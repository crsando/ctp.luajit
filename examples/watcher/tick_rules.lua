-- watcher 的行情规则：纯函数，不依赖 service 和 CTP，可离线测试
-- （tick_rules_test.lua）。collector.lua 用它过滤、打包 tick，db_writer.lua
-- 用它的行格式和日表列映射写库。设计见 db_writer.md。
local M = {}

local BJ = 8 * 3600 -- CTP 时间是北京时间
local DAY = 86400

-- 行情时间与本机时间相差超过这个值，就是订阅时柜台补发的旧快照，不进 tick 表
M.STALE_US = 5 * 60 * 1000000

-- tick 表的一行：collector 把多行平铺在一个数组里发给 db_writer，
-- 每行 STRIDE 个值，按下面的顺序。不用带键的表，省掉每行的键名打包。
M.ROW = {
    "symbol",        -- InstrumentID
    "ts",            -- 交易所时间，微秒
    "received_at",   -- 本机收到的时间，微秒
    "last_price",    -- LastPrice
    "volume",        -- Volume，当日累计
    "turnover",      -- Turnover，当日累计
    "open_interest", -- OpenInterest
    "bid_price1", "bid_volume1",
    "ask_price1", "ask_volume1",
}
M.STRIDE = #M.ROW

-- 把一行追加到平铺数组 rows（已有 n 个值），返回新的 n
function M.append(rows, n, tick, ts, received_at)
    rows[n + 1] = tick.InstrumentID
    rows[n + 2] = ts
    rows[n + 3] = received_at
    rows[n + 4] = tick.LastPrice
    rows[n + 5] = tick.Volume
    rows[n + 6] = tick.Turnover
    rows[n + 7] = tick.OpenInterest
    rows[n + 8] = tick.BidPrice1
    rows[n + 9] = tick.BidVolume1
    rows[n + 10] = tick.AskPrice1
    rows[n + 11] = tick.AskVolume1
    return n + M.STRIDE
end

-- 和上一笔相比，tick 表关心的字段有没有变化。成交额随成交量变，不单独比较。
function M.changed(prev, tick)
    return prev.LastPrice ~= tick.LastPrice
        or prev.Volume ~= tick.Volume
        or prev.OpenInterest ~= tick.OpenInterest
        or prev.BidPrice1 ~= tick.BidPrice1
        or prev.BidVolume1 ~= tick.BidVolume1
        or prev.AskPrice1 ~= tick.AskPrice1
        or prev.AskVolume1 ~= tick.AskVolume1
end

--
-- 无效值：CTP 用 DBL_MAX 表示“没有”，空档位、没成交过的合约也会给 0。
-- 返回 NaN 的写成 double 后 QuestDB 存为 NULL；返回 nil 的整数列不写，也是 NULL。
--
local NaN = 0 / 0

-- 价格：0、负数和 DBL_MAX 都不是价格
function M.price(p)
    if type(p) == "number" and p > 0 and p < 1e300 then return p end
    return NaN
end

-- 金额（成交额）：0 是有效值
function M.amount(v)
    if type(v) == "number" and v < 1e300 then return v end
    return NaN
end

-- 整数（量、持仓量）：CTP 里持仓量是 double，期货都是整数
function M.int(v)
    if type(v) == "number" and v >= 0 and v < 1e18 and v % 1 == 0 then return v end
    return nil
end

--
-- 时间
--

-- 1970-01-01 起的天数（Howard Hinnant 的 days_from_civil）
local function days_from_civil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * ((m + 9) % 12) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

-- 交易所时间（微秒）。只用 UpdateTime 和毫秒，日期取本机的北京日期：
-- ActionDay 不可靠（大商所夜盘填的是下一个交易日）。行情时间和本机时间
-- 相差超过半天，说明跨了零点：23:59:59 的行情在 00:00:01 收到算前一天，
-- 反过来算后一天。时间格式不对时返回 nil。
function M.exchange_ts_us(update_time, ms, now_us)
    local h, m, s = tostring(update_time):match("^(%d%d):(%d%d):(%d%d)$")
    if not h then return nil end
    ms = ms or 0
    if type(ms) ~= "number" or ms < 0 or ms > 999 or ms % 1 ~= 0 then return nil end
    local sec = h * 3600 + m * 60 + s
    local bj = math.floor(now_us / 1000000) + BJ
    local day = math.floor(bj / DAY)
    local diff = sec - (bj - day * DAY)
    if diff > DAY / 2 then
        day = day - 1
    elseif diff < -DAY / 2 then
        day = day + 1
    end
    return ((day * DAY + sec - BJ) * 1000 + ms) * 1000
end

-- 交易日 YYYYMMDD 的北京时间零点（微秒），日表的指定时间戳
function M.day_ts_us(trading_day)
    local y, m, d = tostring(trading_day):match("^(%d%d%d%d)(%d%d)(%d%d)$")
    if not y then return nil end
    return (days_from_civil(tonumber(y), tonumber(m), tonumber(d)) * DAY - BJ) * 1000000
end

--
-- 日表：每个合约每个交易日一行，当天不变或只关心最终值的字段
--

-- { 列名, CTP 字段名, 类型 }，类型是上面的 price / amount / int
M.DAILY = {
    { "pre_settlement_price", "PreSettlementPrice", "price" },
    { "pre_close_price", "PreClosePrice", "price" },
    { "pre_open_interest", "PreOpenInterest", "int" },
    { "upper_limit_price", "UpperLimitPrice", "price" },
    { "lower_limit_price", "LowerLimitPrice", "price" },
    { "open_price", "OpenPrice", "price" },
    { "highest_price", "HighestPrice", "price" },
    { "lowest_price", "LowestPrice", "price" },
    { "close_price", "ClosePrice", "price" },
    { "settlement_price", "SettlementPrice", "price" },
    { "volume", "Volume", "int" },
    { "turnover", "Turnover", "amount" },
    { "open_interest", "OpenInterest", "int" },
}

-- collector 发给 db_writer 的日表行：只带日表要的字段
function M.daily(tick, exchange, trading_day, ts)
    local d = {
        symbol = tick.InstrumentID,
        exchange = exchange,
        trading_day = trading_day,
        updated_at = ts, -- 取自哪一笔 tick（交易所时间，微秒）
    }
    for _, c in ipairs(M.DAILY) do
        d[c[2]] = tick[c[2]]
    end
    return d
end

return M
