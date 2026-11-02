-- 把 CTP 成交回报（CThostFtdcTradeField 转成的 table）清洗成持久化记录，并编码成 JSONL。
-- 纯函数，不依赖 service / ctp，测试见 clean_test.lua；字段含义见 README.md。
local M = {}

-- 记录和汇总行的字段，按这个顺序输出
M.FIELDS = { "trade_id", "investor_id", "trading_day", "traded_at", "instrument_id",
    "direction", "volume", "price", "commission" }
M.SUMMARY_FIELDS = { "summary", "profile", "symbol", "investor_id", "trading_day", "count" }

local DIRECTION = { ["0"] = "buy", ["1"] = "sell" }

local function trim(s)
    return (s:match("^%s*(.-)%s*$"))
end

-- "20261102" -> 2026, 11, 2
local function ymd(s)
    local y, m, d = s:match("^(%d%d%d%d)(%d%d)(%d%d)$")
    if not y then error("bad date: " .. tostring(s)) end
    return tonumber(y), tonumber(m), tonumber(d)
end

-- 取正午，避开夏令时切换
local function add_days(y, m, d, n)
    local t = os.date("*t", os.time { year = y, month = m, day = d + n, hour = 12 })
    return t.year, t.month, t.day, t.wday
end

-- 交易日之前的最近一个工作日（wday：1 周日，7 周六）
local function prev_weekday(y, m, d)
    local wday
    repeat
        y, m, d, wday = add_days(y, m, d, -1)
    until wday ~= 1 and wday ~= 7
    return y, m, d
end

-- 由交易日和成交时间推出成交发生的自然日。不用 TradeDate：大商所、郑商所夜盘的
-- TradeDate 可能是交易日而不是自然日。夜盘总是在前一个工作日的晚上（节前最后一个
-- 交易日没有夜盘），所以不需要节假日日历：
--   18:00 以后       前一个工作日
--   06:00 以前       前一个工作日的次日（夜盘过了午夜）
--   其他（日盘）     交易日当天
function M.calendar_date(trading_day, time)
    local y, m, d = ymd(trading_day)
    local hour = tonumber(time:match("^(%d%d):%d%d:%d%d$") or error("bad time: " .. tostring(time)))
    if hour >= 18 then
        y, m, d = prev_weekday(y, m, d)
    elseif hour < 6 then
        y, m, d = prev_weekday(y, m, d)
        y, m, d = add_days(y, m, d, 1)
    end
    return string.format("%04d-%02d-%02d", y, m, d)
end

local function iso_day(day)
    return string.format("%04d-%02d-%02d", ymd(day))
end

-- t 是 CThostFtdcTradeField 转成的 table：字符串字段可能带空白，char 字段是数字
function M.record(t)
    local day = trim(t.TradingDay)
    local direction = DIRECTION[string.char(t.Direction)]
        or error("unknown Direction: " .. tostring(t.Direction))
    local time = trim(t.TradeTime)
    return {
        trade_id = table.concat({ trim(t.InvestorID), day, trim(t.ExchangeID), trim(t.TradeID), direction }, "."),
        investor_id = trim(t.InvestorID),
        trading_day = iso_day(day),
        traded_at = M.calendar_date(day, time) .. "T" .. time .. "+08:00",
        instrument_id = trim(t.InstrumentID),
        direction = direction,
        volume = t.Volume,
        price = t.Price,
        commission = nil, -- 预留，以后补
    }
end

-- 清洗并按成交时间排序
function M.records(trades)
    local out = {}
    for i, t in ipairs(trades) do out[i] = M.record(t) end
    table.sort(out, function (a, b)
        if a.traded_at ~= b.traded_at then return a.traded_at < b.traded_at end
        return a.trade_id < b.trade_id
    end)
    return out
end

-- 一次运行的汇总，对应 runs 表。账户和交易日来自登录 session，没有成交时也有值；
-- 成交记录（trades 表）的这两项来自成交回报本身。symbol 非空说明只查了一个合约。
function M.summary(count, profile, symbol, investor_id, trading_day)
    if not investor_id or investor_id == "" then error("no investor_id in login session") end
    return {
        summary = true,
        profile = profile,
        symbol = symbol,
        investor_id = trim(investor_id),
        trading_day = iso_day(trading_day or error("no trading day in login session")),
        count = count,
    }
end

local ESCAPE = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function value(v)
    local kind = type(v)
    if v == nil then
        return "null"
    elseif kind == "boolean" then
        return tostring(v)
    elseif kind == "number" then
        if v ~= v or v == math.huge or v == -math.huge then error("non-finite number") end
        return string.format("%.14g", v)
    elseif kind == "string" then
        return '"' .. v:gsub('[%c"\\]', function (c)
            return ESCAPE[c] or string.format("\\u%04x", c:byte())
        end) .. '"'
    end
    error("cannot encode " .. kind)
end

-- 按 keys 的顺序编码成一行 JSON；缺的字段输出 null
function M.encode(obj, keys)
    local parts = {}
    for i, k in ipairs(keys) do
        parts[i] = '"' .. k .. '":' .. value(obj[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

return M
