-- 查询账户当日的所有成交，清洗后以 JSONL 写到 stdout：每笔成交一行，最后一行是汇总。
--
--   luajit examples/tradelog/tradelog.lua <profile> [symbol]
--
-- profile 是 ~/.ctp.luajit/accounts.lua 里 trader 下的名字；symbol 可选，只看该合约。
-- CTP 只返回当前交易日的成交；夜盘的成交算在下一个交易日。日志写 stderr，
-- 失败时退出码非 0。字段说明和写入 SQLite 见 README.md。
local service = require "service"
local root = require "service.root"
local accounts = require "ctp.accounts"

local here = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local clean = dofile(here .. "clean.lua")

function root.boot(...)
    local profile_name, symbol = ...
    profile_name = profile_name or ""
    local server = accounts["trader"][profile_name]

    if not server then
        return service.quit("no matching server found for profile: " .. profile_name)
    end
    service.quit(service.call(0, "run", server, symbol))
end

-- 成功返回 nil，失败返回原因
function root.run(server, symbol)
    service.spawn {
        name = "trader",
        source = [[return require "ctp.templates.trader"]],
        config = { server = server }
    }

    local ok, err = service.call("trader", "start")
    if not ok then
        service.call("trader", "quit")
        return "trader start failed: " .. tostring(err)
    end

    local trades
    trades, err = service.call("trader", "query_trade", symbol)
    local day = service.call("trader", "status").trading_day
    service.call("trader", "quit")

    if not trades then
        return "query_trade failed: " .. tostring(err)
    end

    local records = clean.records(trades)
    local out = {}
    for i, r in ipairs(records) do
        out[i] = clean.encode(r, clean.FIELDS)
    end
    out[#out + 1] = clean.encode(clean.summary(server.user, day, #records), clean.SUMMARY_FIELDS)
    io.stdout:write(table.concat(out, "\n"), "\n")
    io.stdout:flush()
end

return root
