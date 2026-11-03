-- db_writer 用到的纯函数：时间换算、无效值、日表列映射。不依赖 service 和
-- QuestDB，离线测试见 tick_rules_test.lua。设计见 db_writer.md。
local M = {}

local BJ = 8 * 3600 -- CTP 时间是北京时间
local DAY = 86400

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

-- 本机时钟和交易所时间允许的偏差：行情最多比本机时间晚这么多（本机时钟慢）
M.CLOCK_SKEW = 300

-- 交易所时间（微秒）。只用 UpdateTime 和毫秒，日期取本机的北京日期：
-- ActionDay、TradingDay 各有交易所填错（见 docs/md-time-fields.md）。
-- 行情不会来自未来：按本机当天算出的时间比本机时间晚超过 CLOCK_SKEW，就是
-- 前一天的（订阅时补发的旧快照、23:59:59 的行情在 00:00:01 收到）；比本机时间
-- 早 24 小时减 CLOCK_SKEW 以上，就是本机时钟慢、行情已经过了零点，算后一天。
-- 时间格式不对时返回 nil。
function M.exchange_ts_us(update_time, ms, now_us)
    local h, m, s = tostring(update_time):match("^(%d%d):(%d%d):(%d%d)$")
    if not h then return nil end
    ms = ms or 0
    if type(ms) ~= "number" or ms < 0 or ms > 999 or ms % 1 ~= 0 then return nil end
    local sec = h * 3600 + m * 60 + s
    local bj = math.floor(now_us / 1000000) + BJ
    local day = math.floor(bj / DAY)
    local diff = sec - (bj - day * DAY)
    if diff > M.CLOCK_SKEW then
        day = day - 1
    elseif diff <= M.CLOCK_SKEW - DAY then
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
-- { 列名, CTP 字段名, 类型 }，类型是上面的 price / amount / int
--
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

return M
