local service = require "service"
local root = require "service.root"

local scheduler = require "service.scheduler"
local config = service.config or {}

local ctp = require "ctp"
local accounts = require "ctp.accounts"

local S = root

do
    local myid = service.get_id()
    scheduler:daily("08:45:00", function() service.send(myid, "start_all") end)
    scheduler:daily("15:45:00", function() service.send(myid, "stop_all") end)
    scheduler:daily("20:45:00", function() service.send(myid, "start_all") end)
    scheduler:daily("04:00:00", function() service.send(myid, "stop_all") end)
end


-- profile 依次取命令行参数、service.config.profile，默认 gtja-3
function S.boot(profile)
    profile = profile or config.profile or "gtja-3"
    if not (accounts["collector"][profile] and accounts["trader"][profile]) then
        return service.quit("no collector/trader account for profile: " .. profile)
    end
    service.log.info("watcher | profile %s", profile)

    service.spawn { name = "db_writer", source = "@db_writer.lua", config = {} }

    -- 过滤、每 100ms 打包一批转发给 db_writer，见 collector.lua
    service.spawn {
        name = "collector",
        source = "@collector.lua",
        config = {
            server = accounts["collector"][profile],
            writer = "db_writer",
        },
        mailbox_size = 8096,
    }

    service.spawn { name = "trader", source = [[ return require "ctp.templates.trader" ]], 
        config = {
            server = accounts["trader"][profile],
        } }

    service.call(service.get_id(), "start_all")
end

function S.start_all()
    service.call("collector", "start")
    service.call("trader", "start")

    local instruments, err = service.call("trader", "query_instrument")
    if not instruments then
        -- 周末、节假日定时启动时前置不开放
        service.log.error("watcher | query_instrument failed: %s", tostring(err))
        return
    end

    local exchanges = {}
    for _, entry in ipairs(instruments) do
        exchanges[entry.InstrumentID] = entry.ExchangeID
    end
    service.call("collector", "set_exchanges", exchanges)

    do
        local subs = {}
        local count = 0
        for _, entry in ipairs(instruments) do
            count = count + 1
            table.insert(subs, entry.InstrumentID)

            -- subscribe for every 10 instruments
            if count == 10 then
                service.call("collector", "subscribe", subs)
                subs = {}
                count = 0
            end
        end
        if #subs > 0 then
            service.call("collector", "subscribe", subs)
        end
    end -- end subscribe
end

function S.stop_all()
    service.call("trader", "stop")
    service.call("collector", "stop")
end

function S.quit()
    service.log.debug("root is quiting")
    -- 先停 collector：它把攒着的 tick 和日表发给 db_writer 之后才返回，
    -- db_writer 再收到 quit，最后一次 flush 能带上这些数据
    service.call("collector", "stop")
    service.send("db_writer", "quit")
    service.send("collector", "quit")
    service.send("trader", "quit")
    service.quit()
end

return S
