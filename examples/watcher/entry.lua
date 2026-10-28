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


function S.boot()
    local profile = config.profile or "gtja-3"

    service.spawn { name = "db_writer", source = "@db_writer.lua", config = {} }

    service.spawn {
        name = "collector",
        source = [[
            local service = require "service"
            local ctp = require "ctp"
            local S = require "ctp.templates.collector"
            function S.on_tick(tick)
                service.log.debug("on_tick | %s | %f", tick.InstrumentID, tick.LastPrice)
                service.send("db_writer", "on_tick", tick)
            end
            return S
        ]],
        config = {
            server = accounts["collector"][profile]
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

    local instruments = service.call("trader", "query_instrument")

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
    service.send("db_writer", "quit")
    service.send("collector", "quit")
    service.send("trader", "quit")
    service.quit()
end

return S
