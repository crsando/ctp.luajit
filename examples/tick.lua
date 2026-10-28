-- 监听一个合约的 tick，逐条打印：
--
--   luajit examples/tick.lua <symbol> [profile]
--
-- symbol 如 IM2703；profile 是 ~/.ctp.luajit/accounts.lua 里 collector 下的名字，
-- 默认 hy-sim。Ctrl-C 退出。
local service = require "service"
local root = require "service.root"
local accounts = require "ctp.accounts"

function root.boot(symbol, profile)
    profile = profile or "hy-sim"
    local server = accounts["collector"][profile]

    if not symbol then
        service.log.error("usage: luajit examples/tick.lua <symbol> [profile]")
        return service.quit()
    elseif not server then
        service.log.error("no matching server found for profile: " .. profile)
        return service.quit()
    end

    service.spawn {
        name = "collector",
        source = [[
            local S = require "ctp.templates.collector"
            function S.on_tick(t)
                print(string.format("%s %s.%03d %s last=%.2f vol=%d oi=%.0f bid=%.2f/%d ask=%.2f/%d",
                    t.ActionDay, t.UpdateTime, t.UpdateMillisec, t.InstrumentID,
                    t.LastPrice, t.Volume, t.OpenInterest,
                    t.BidPrice1, t.BidVolume1, t.AskPrice1, t.AskVolume1))
                io.stdout:flush()
            end
            return S
        ]],
        config = { server = server },
    }

    local ok, err = service.call("collector", "start")
    if not ok then
        service.log.error("collector start failed: %s", err)
        service.call("collector", "quit")
        return service.quit()
    end

    service.call("collector", "subscribe", symbol)
    service.log.info("listening %s on %s (%s), Ctrl-C to quit", symbol, profile, server.front_addr)

    -- 不 quit：root 继续运行，tick 由 collector 打印。CTP SDK 的线程会让默认的
    -- SIGINT 结束不了进程，所以自己处理 Ctrl-C / SIGTERM，先停 collector 再退出。
    local myid = service.get_id()
    for _, name in ipairs { "sigint", "sigterm" } do
        service.uv.new_signal():start(name, function () service.send(myid, "quit") end)
    end
end

local quitting = false
function root.quit()
    if quitting then return end
    quitting = true
    service.call("collector", "quit")
    service.quit()
end

return root
