-- watcher 的行情服务：ctp.templates.collector，每个 tick 原样转发给 db_writer。
-- 整理成行、攒批写库都在 db_writer.lua 里做。
--
-- config：server（必填），writer（默认 "db_writer"）
local service = require "service"
local S = require "ctp.templates.collector"

local WRITER = service.config.writer or "db_writer"

local send_errors = 0

function S.on_tick(tick)
    local ok, err = service.send(WRITER, "on_tick", tick)
    if not ok then
        -- db_writer 已经退出，或者 mailbox 扩容时内存不够；mailbox 满了会自动扩容，
        -- flush 慢只会让消息排队，不会走到这里
        send_errors = send_errors + 1
        if send_errors == 1 or send_errors % 1000 == 0 then
            service.log.error("collector | send to %s failed (%d times): %s", WRITER, send_errors, tostring(err))
        end
    end
end

return S
