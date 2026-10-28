-- 用真实前置检查 ctp.templates.collector 的启动逻辑：
--
--   luajit examples/collector_smoke.lua [profile] [symbol ...]
--
-- profile 是 ~/.ctp.luajit/accounts.lua 里 collector 下的名字，默认 simnow-7x24。
-- 1. 启动、订阅、收 SMOKE_SECONDS（默认 30）秒 tick，期间打印状态，然后 stop；
-- 2. 把前置换成不可达的地址，确认 start 在超时后失败并已 stop。
local service = require "service"
local root = require "service.root"
local accounts = require "ctp.accounts"
local uv = require "luv"

local SECONDS = tonumber(os.getenv("SMOKE_SECONDS")) or 30

-- 模板加上一个 tick 计数，供 root 查询
local SOURCE = [[
    local S = require "ctp.templates.collector"
    local count, last = 0, {}
    function S.on_tick(tick)
        count = count + 1
        last[tick.InstrumentID] = string.format("%s.%03d %s", tick.UpdateTime, tick.UpdateMillisec, tick.LastPrice)
    end
    function S.ticks() return count, last end
    return S
]]

local function copy(t)
    local o = {}
    for k, v in pairs(t) do o[k] = v end
    return o
end

local function show_status(name)
    local st = service.call(name, "status")
    print(string.format("  status: state=%s connection=%s reconnects=%d subscriptions=%d dropped=%d last_error=%s",
        st.state, st.connection, st.reconnects, st.subscriptions, st.ticks_dropped, tostring(st.last_error)))
    return st
end

local results = {}
local function check(ok, label)
    results[#results + 1] = string.format("%s  %s", ok and "PASS" or "FAIL", label)
end

function root.boot(profile, ...)
    profile = profile or "simnow-7x24"
    local server = accounts.collector and accounts.collector[profile]
    if not server then
        service.log.error("no collector profile %s in ~/.ctp.luajit/accounts.lua", profile)
        return service.quit()
    end
    local symbols = { ... }
    if #symbols == 0 then symbols = { "rb2601", "au2612", "IF2611" } end

    print(string.format("== 1. %s (%s), %d s", profile, server.front_addr, SECONDS))
    service.spawn { name = "collector", source = SOURCE, config = { server = server } }

    local t0 = uv.hrtime()
    local ok, err = service.call("collector", "start")
    print(string.format("  start -> %s %s (%.1f s)", tostring(ok), tostring(err or ""), (uv.hrtime() - t0) / 1e9))
    check(ok == true, "start logs in")

    if ok then
        print("  subscribe " .. table.concat(symbols, ","), service.call("collector", "subscribe", symbols))
        for i = 1, SECONDS, 5 do
            service.sleep(5000)
            local count = service.call("collector", "ticks")
            io.write(string.format("  +%2ds ticks=%d", i + 4, count))
            show_status("collector")
        end
        local count, last = service.call("collector", "ticks")
        for symbol, line in pairs(last) do print("  last " .. symbol .. " " .. line) end
        check(count > 0, "ticks received (none outside trading hours on a live front)")
        check(service.call("collector", "status").ticks_dropped == 0, "no ticks dropped")
    end

    service.call("collector", "stop")
    check(show_status("collector").state == "stopped", "stop")
    service.call("collector", "quit")

    -- 2. 不可达的前置：start 应在超时后失败，并已停止
    local bad = copy(server)
    bad.front_addr = "tcp://127.0.0.1:9"
    print("== 2. unreachable front " .. bad.front_addr .. ", timeout 3 s")
    service.spawn { name = "unreachable", source = SOURCE, config = { server = bad } }
    ok, err = service.call("unreachable", "start", { timeout = 3000 })
    print("  start -> " .. tostring(ok) .. " " .. tostring(err))
    check(ok == nil and err == "timedout", "unreachable front: start times out")
    check(show_status("unreachable").state == "stopped", "unreachable front: stopped after the timeout")
    service.call("unreachable", "quit")

    print("== results")
    for _, line in ipairs(results) do print("  " .. line) end
    service.quit()
end

return root
