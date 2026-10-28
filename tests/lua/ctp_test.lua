-- Offline tests of lua/ctp: loads libctpc.so from $CTPC_LIBDIR, never
-- connects. Run from the repository root: make test-lua.
package.path = "lua/?.lua;lua/?/init.lua;tests/lua/?.lua;" .. package.path

local ffi = require "ffi"
local t = require "check"
local ctp = require "ctp"

-- constants from ThostFtdcUserApiDataType.h
t.eq(ctp.THOST_FTDC_AF_Delete, string.byte("0"), "char constant")
t.eq(ctp.THOST_FTDC_D_Sell, string.byte("1"), "char constant")
t.eq(ctp.THOST_FTDC_VTC_BankBankToFuture, "102001", "multi-char constant")

-- new_struct / totable round trip
do
    local p = ctp.new_struct("CThostFtdcInputOrderField", {
        InstrumentID = "rb2601",
        ExchangeID = "SHFE",
        Direction = ctp.THOST_FTDC_D_Sell,
        TimeCondition = "3", -- a char field also takes a one-character string
        LimitPrice = 3500.5,
        VolumeTotalOriginal = 3,
    })
    local o = ctp.totable(p, "CThostFtdcInputOrderField")
    t.eq(o.InstrumentID, "rb2601", "string field")
    t.eq(o.ExchangeID, "SHFE", "string field")
    t.eq(o.Direction, string.byte("1"), "char field as byte")
    t.eq(o.TimeCondition, string.byte("3"), "char field from string")
    t.eq(o.LimitPrice, 3500.5, "double field")
    t.eq(o.VolumeTotalOriginal, 3, "int field")
    t.eq(o.OrderRef, "", "unset string field")

    -- the longest string that fits, and one byte more
    local size = ffi.sizeof(p.ExchangeID)
    local fits = string.rep("x", size - 1)
    t.eq(ctp.totable(ctp.new_struct("CThostFtdcInputOrderActionField", { ExchangeID = fits }),
        "CThostFtdcInputOrderActionField").ExchangeID, fits, "string of size - 1 fits")
    t.raises(function () ctp.new_struct("CThostFtdcInputOrderActionField", { ExchangeID = fits .. "x" }) end,
        "longer than", "oversized string")

    t.raises(function () ctp.new_struct("CThostFtdcInputOrderActionField", { NoSuchField = 1 }) end,
        "has no field NoSuchField", "unknown field")
    t.raises(function () ctp.new_struct("CThostFtdcInputOrderActionField", { InstrumentID = 1 }) end,
        "string expected", "number for a string field")
    t.raises(function () ctp.new_struct("CThostFtdcInputOrderField", { VolumeTotalOriginal = "3" }) end,
        "number expected", "string for an int field")
    t.raises(function () ctp.new_struct("CThostFtdcNoSuchField") end, "unknown struct", "unknown struct")
end

-- new_trader checks the account strings before they reach strcpy
do
    local server = { front_addr = "tcp://127.0.0.1:1", broker = "9999", user = "000001", pass = "secret" }
    local trader = ctp.new_trader(server)
    t.eq(ffi.string(trader.trader.app_id), "", "app_id defaults to empty")

    t.raises(function () ctp.new_trader { front_addr = "tcp://127.0.0.1:1", broker = "9999", user = "000001" } end,
        "password must be a string", "missing password")
    t.raises(function ()
        ctp.new_trader { front_addr = "tcp://127.0.0.1:1", broker = string.rep("9", 11), user = "u", pass = "p" }
    end, "broker is longer than 10 bytes", "oversized broker")
    t.raises(function () ctp.new_collector { front_addr = "tcp://127.0.0.1:1", broker = "9999" } end,
        "user must be a string", "collector without user")
end

-- requests: before start every request fails at once, without a request id
do
    local trader = ctp.new_trader { front_addr = "tcp://127.0.0.1:1", broker = "9999", user = "000001", pass = "p" }
    local rc, err = trader:req("QryTradingAccount")
    t.eq(rc, -100, "request before start")
    t.eq(err, "trader not started", "request before start message")
    t.eq(tonumber(trader.trader.req_id), 0, "failed request takes no id")

    t.eq((trader:order_cancel("rb2601", "SHFE", "123")), -100, "order_cancel goes through req")
    t.eq((trader:logout()), -100, "logout goes through req")
    t.eq((trader:password_update("p", "new")), -100, "password_update goes through req")
    t.eq(ffi.string(trader.trader.password), "p", "password kept when the request fails")

    -- account defaults, overridden by explicit fields
    local o = ctp.totable(trader:request_struct("QryTradingAccount"), "CThostFtdcQryTradingAccountField")
    t.eq(o.BrokerID, "9999", "BrokerID default")
    t.eq(o.InvestorID, "000001", "InvestorID default")
    o = ctp.totable(trader:request_struct("QryTradingAccount", { InvestorID = "000002", CurrencyID = "CNY" }),
        "CThostFtdcQryTradingAccountField")
    t.eq(o.InvestorID, "000002", "explicit field over default")
    t.eq(o.CurrencyID, "CNY", "explicit field")
    o = ctp.totable(trader:request_struct("OrderAction", {}), "CThostFtdcInputOrderActionField")
    t.eq(o.BrokerID, "9999", "request name to struct name")

    t.raises(function () trader:req("NoSuchRequest") end, "unknown request", "unknown request")
    t.raises(function () trader:req("QryInstrument", { BrokerID = "9999" }) end,
        "has no field BrokerID", "field the request struct lacks")
    t.raises(function () trader:req("QryInstrument", { InstrumentID = string.rep("x", 100) }) end,
        "longer than", "oversized request field")
end

t.done()
