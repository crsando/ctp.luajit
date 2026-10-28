-- 查询账户当日的所有成交（只看成交，不看委托）：
--
--   luajit examples/tradelog.lua <profile> [symbol]
--
-- profile 是 ~/.ctp.luajit/accounts.lua 里 trader 下的名字；symbol 可选，只看该合约。
-- CTP 只返回当前交易日的成交；夜盘的成交算在下一个交易日。
local service = require "service"
local root = require "service.root"
local accounts = require "ctp.accounts"

local DIRECTION = { ["0"] = "买", ["1"] = "卖" }
local OFFSET = { ["0"] = "开", ["1"] = "平", ["2"] = "强平", ["3"] = "平今", ["4"] = "平昨", ["5"] = "强减", ["6"] = "本地强平" }

-- 按终端显示宽度左对齐：汉字占 2 列（string.format 的 %-Ns 按字节算）
local function pad(s, width)
    local w = 0
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        w = w + (#ch > 1 and 2 or 1)
    end
    return s .. string.rep(" ", width - w)
end

local function char(map, c)
    local s = string.char(c)
    return map[s] or s
end

function root.boot(...)
    local profile_name, symbol = ...
    profile_name = profile_name or ""
    local server = accounts["trader"][profile_name]

    if not server then
        service.log.error("no matching server found for profile: " .. profile_name)
    else
        service.call(0, "run", server, symbol)
    end

    service.quit()
end

function root.run(server, symbol)
    service.spawn {
        name = "trader",
        source = [[return require "ctp.templates.trader"]],
        config = { server = server }
    }

    local ok, err = service.call("trader", "start")
    if not ok then
        service.log.error("trader start failed: %s", err)
        service.call("trader", "quit")
        return
    end

    local trades
    trades, err = service.call("trader", "query_trade", symbol)
    local day = service.call("trader", "status").trading_day
    service.call("trader", "quit")

    if not trades then
        service.log.error("query_trade failed: %s", err)
        return
    end

    table.sort(trades, function (a, b)
        if a.TradeDate ~= b.TradeDate then return a.TradeDate < b.TradeDate end
        if a.TradeTime ~= b.TradeTime then return a.TradeTime < b.TradeTime end
        return a.TradeID < b.TradeID
    end)

    print(string.format("交易日 %s，成交 %d 笔%s", tostring(day), #trades, symbol and ("（" .. symbol .. "）") or ""))
    if #trades == 0 then return end

    local function line(date, time, inst, exch, dir, offset, price, volume, trade_id, order_id)
        print(table.concat({ pad(date, 8), pad(time, 8), pad(inst, 10), pad(exch, 6), pad(dir, 4),
            pad(offset, 8), string.rep(" ", 10 - #price) .. price, string.rep(" ", 6 - #volume) .. volume,
            pad(trade_id, 12), order_id }, " "))
    end
    print(table.concat({ pad("日期", 8), pad("时间", 8), pad("合约", 10), pad("交易所", 6), pad("方向", 4),
        pad("开平", 8), "      价格", "  手数", pad("成交编号", 12), "报单编号" }, " "))
    local sum = {} -- 合约 -> { buy, sell }
    for _, t in ipairs(trades) do
        line(t.TradeDate, t.TradeTime, t.InstrumentID, t.ExchangeID,
            char(DIRECTION, t.Direction), char(OFFSET, t.OffsetFlag),
            string.format("%.2f", t.Price), tostring(t.Volume),
            (t.TradeID:gsub("^%s+", "")), (t.OrderSysID:gsub("^%s+", "")))
        local s = sum[t.InstrumentID] or { buy = 0, sell = 0 }
        if string.char(t.Direction) == "0" then s.buy = s.buy + t.Volume else s.sell = s.sell + t.Volume end
        sum[t.InstrumentID] = s
    end

    print("按合约汇总：")
    local names = {}
    for name in pairs(sum) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        print(string.format("  %s 买 %d 手，卖 %d 手", pad(name, 10), sum[name].buy, sum[name].sell))
    end
end

return root
