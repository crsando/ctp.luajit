-- 手动下单：
--
--   luajit examples/trade.lua <profile> buy|sell <symbol> [--dry-run]
--
-- profile 是 ~/.ctp.luajit/accounts.lua 里 trader 下的名字。固定 1 手，按净持仓：
--   buy:  有空头持仓就买平一手，否则买开一手；
--   sell: 有多头持仓就卖平一手，否则卖开一手。
-- 规则都在模板的 S.place（定价、开平见 ctp.order_rules）：对手价让 2 个价位、
-- 不超过涨跌停的限价单，上期所/能源中心先平昨再平今，5 秒没成交就撤单。
-- --dry-run 只查询并打印计划，不发报单。
local service = require "service"
local root = require "service.root"
local accounts = require "ctp.accounts"
local rules = require "ctp.order_rules"

local VOLUME = 1
local WATCHDOG_MS = 30000 -- 撤单回报丢了也不会一直挂着

local USAGE = "usage: luajit trade.lua <profile> buy|sell <symbol> [--dry-run]"

local function show(p)
    local legs = {}
    for _, leg in ipairs(p.legs) do
        legs[#legs + 1] = string.format("%s %d", rules.OFFSET_NAME[leg.offset], leg.volume)
    end
    local c = p.closable
    local avail = rules.SPLIT_TODAY[p.exchange] and string.format("昨%d 今%d", c.yd, c.td) or tostring(c.yd)
    print(string.format("%s %s(%s) %d 手 @ %.10g  [%s；反向可平 %s；买一 %s 卖一 %s 最新 %s，%s]",
        p.side, p.symbol, p.exchange, p.volume, p.price, table.concat(legs, " + "),
        avail, tostring(p.market.bid), tostring(p.market.ask),
        tostring(p.market.last), tostring(p.market.time)))
    for i, leg in ipairs(p.legs) do
        if leg.msg then
            print(string.format("  leg %d %s: %s  OrderSysID=%s  %s", i, rules.OFFSET_NAME[leg.offset],
                tostring(leg.msg), tostring(leg.entry and leg.entry.OrderSysID),
                tostring(leg.entry and leg.entry.StatusMsg or "")))
        end
    end
    if p.ok == false then print("error: " .. tostring(p.error)) end
end

function root.boot(profile, side, symbol, flag)
    local server = profile and accounts.trader and accounts.trader[profile]
    if not server or (side ~= "buy" and side ~= "sell") or not symbol
        or (flag ~= nil and flag ~= "--dry-run") then
        if profile and not server then print("no trader profile " .. profile .. " in ~/.ctp.luajit/accounts.lua") end
        print(USAGE)
        return service.quit()
    end

    local watchdog = service.set_timeout(WATCHDOG_MS, function ()
        print(string.format("no result in %d s; check the order with query_order / the broker's terminal", WATCHDOG_MS / 1000))
        os.exit(2)
    end)

    service.spawn { name = "trader", source = [[return require "ctp.templates.trader"]],
        config = { server = server } }
    local ok, err = service.call("trader", "start")
    if ok then
        local p
        p, err = service.call("trader", "place", side, symbol, VOLUME, { dry_run = flag == "--dry-run" })
        if p then show(p) end
    end
    if err then print("error: " .. tostring(err)) end
    watchdog:stop()
    watchdog:close()
    service.call("trader", "quit")
    service.quit()
end

return root
