-- 用真实前置检查 ctp.templates.trader 的启动逻辑（只查询，不下单）：
--
--   luajit examples/trader_smoke.lua [profile]
--
-- profile 是 ~/.ctp.luajit/accounts.lua 里 trader 下的名字，默认 hy-sim。
-- 1. 启动（认证、登录、结算确认），查询资金和持仓，打印状态，然后 stop；
-- 2. 把前置换成不可达的地址，确认 start 在超时后失败并已 stop。
-- 不会用错误密码测试登录失败：可能触发账户锁定。
local service = require "service"
local root = require "service.root"
local accounts = require "ctp.accounts"
local uv = require "luv"

local SOURCE = [[ return require "ctp.templates.trader" ]]

local function copy(t)
    local o = {}
    for k, v in pairs(t) do o[k] = v end
    return o
end

local function show_status(name)
    local st = service.call(name, "status")
    print(string.format("  status: state=%s connection=%s front=%s session=%s day=%s reconnects=%d last_error=%s",
        st.state, st.connection, tostring(st.front_id), tostring(st.session_id), tostring(st.trading_day),
        st.reconnects, tostring(st.last_error)))
    return st
end

local results = {}
local function check(ok, label)
    results[#results + 1] = string.format("%s  %s", ok and "PASS" or "FAIL", label)
end

function root.boot(profile)
    profile = profile or "hy-sim"
    local server = accounts.trader and accounts.trader[profile]
    if not server then
        service.log.error("no trader profile %s in ~/.ctp.luajit/accounts.lua", profile)
        return service.quit()
    end

    print(string.format("== 1. %s (%s)", profile, server.front_addr))
    service.spawn { name = "trader", source = SOURCE, config = { server = server } }

    local acct, err = service.call("trader", "query_account")
    check(acct == nil and err == "not started", "query before start fails at once")

    local t0 = uv.hrtime()
    local ok
    ok, err = service.call("trader", "start")
    print(string.format("  start -> %s %s (%.1f s)", tostring(ok), tostring(err or ""), (uv.hrtime() - t0) / 1e9))
    check(ok == true, "start: authenticate, log in, confirm settlement")

    if ok then
        local st = show_status("trader")
        check(st.state == "ready" and st.connection == "ready" and st.session_id ~= nil, "status after start")

        acct, err = service.call("trader", "query_account")
        print(string.format("  query_account -> Balance=%s Available=%s %s",
            tostring(acct and acct.Balance), tostring(acct and acct.Available), tostring(err or "")))
        check(acct ~= nil and acct.Balance ~= nil, "query_account")

        local pos
        pos, err = service.call("trader", "query_position")
        print(string.format("  query_position -> %s rows %s", pos and #pos or "nil", tostring(err or "")))
        for _, p in ipairs(pos or {}) do
            print(string.format("    %s dir=%s pos=%d", p.InstrumentID, string.char(p.PosiDirection), p.Position))
        end
        check(pos ~= nil, "query_position")
    end

    service.call("trader", "stop")
    check(show_status("trader").state == "stopped", "stop")
    service.call("trader", "quit")

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
