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

-- GBK text: ctp.gbk through the system iconv, and totable(..., true) as
-- cast_rsp uses it. "\196\227\186\195" is 你好 in GBK.
do
    local gbk = require "ctp.gbk"
    t.eq(gbk.available, true, "iconv available")
    t.eq(gbk.error, nil, "iconv no error")
    t.eq(gbk.to_utf8("\196\227\186\195"), "你好", "gbk to utf8")
    t.eq(gbk.to_utf8("rb2601"), "rb2601", "ascii unchanged")
    t.eq(gbk.to_utf8(""), "", "empty unchanged")
    t.eq(gbk.to_utf8(nil), nil, "nil unchanged")
    t.eq(gbk.to_utf8("CTP:\196\227\186"), "CTP:你", "sequence cut at the end is dropped")
    t.eq(gbk.to_utf8("\255\255x"), "\255\255x", "invalid input returned as is")
    t.eq(gbk.to_utf8(string.rep("\196\227", 40)), string.rep("你", 40), "long string")

    local p = ctp.new_struct("CThostFtdcOrderField", {
        InstrumentID = "rb2601",
        StatusMsg = "\196\227\186\195",
        OrderMemo = "\196\227",
        ExchangeInstID = "\196\227", -- not a text field: stays raw
    })
    local raw = ctp.totable(p, "CThostFtdcOrderField")
    t.eq(raw.StatusMsg, "\196\227\186\195", "totable keeps raw bytes")
    local o = ctp.totable(p, "CThostFtdcOrderField", true)
    t.eq(o.StatusMsg, "你好", "StatusMsg converted")
    t.eq(o.OrderMemo, "你", "OrderMemo converted")
    t.eq(o.ExchangeInstID, "\196\227", "non-text field not converted")
    t.eq(o.InstrumentID, "rb2601", "id unchanged")

    local i = ctp.totable(ctp.new_struct("CThostFtdcRspInfoField",
        { ErrorID = 31, ErrorMsg = "CTP:\196\227\186\195" }), "CThostFtdcRspInfoField", true)
    t.eq(i.ErrorMsg, "CTP:你好", "ErrorMsg converted")
    local n = ctp.totable(ctp.new_struct("CThostFtdcInstrumentField",
        { InstrumentName = "\196\227\186\195" }), "CThostFtdcInstrumentField", true)
    t.eq(n.InstrumentName, "你好", "InstrumentName converted")
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
    -- the SDK crashes on these
    t.raises(function () ctp.new_collector { front_addr = "127.0.0.1:1", broker = "9999", user = "u" } end,
        "must look like tcp://host:port", "collector front without protocol")
    t.raises(function () ctp.new_trader { front_addr = "127.0.0.1:1", broker = "9999", user = "u", pass = "p" } end,
        "must look like tcp://host:port", "trader front without protocol")
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

-- order refs: allocated in Lua from the login's MaxOrderRef, never going back
do
    local trader = ctp.new_trader { front_addr = "tcp://127.0.0.1:1", broker = "9999", user = "000001", pass = "p" }
    local ref, err = trader:next_order_ref()
    t.eq(ref, nil, "no order ref before login")
    t.eq(err, "not logged in", "no order ref before login message")
    local o
    o, err = trader:order_insert("rb2601", 3500, 1, ctp.THOST_FTDC_OF_Open)
    t.eq(o, nil, "order_insert before login")
    t.eq(err, "not logged in", "order_insert before login message")

    local function login(front, session, max_ref, error_id)
        trader:on_login { func_name = "OnRspUserLogin",
            field = { FrontID = front, SessionID = session, MaxOrderRef = max_ref },
            rsp_info = error_id and { ErrorID = error_id, ErrorMsg = "" } or nil }
    end

    login(1, 100, "7")
    t.eq(trader:next_order_ref(), "000000000008", "first ref is MaxOrderRef + 1")
    t.eq(trader:next_order_ref(), "000000000009", "refs increase")
    t.eq(trader.session.SessionID, 100, "session from login")

    login(1, 200, "3") -- reconnect, server grants a lower ref
    t.eq(trader:next_order_ref(), "000000000010", "refs never go back across logins")
    t.eq(trader.session.SessionID, 200, "session follows the new login")
    login(1, 300, "            ") -- blank MaxOrderRef
    t.eq(trader:next_order_ref(), "000000000011", "blank MaxOrderRef")
    login(1, 400, "100")
    t.eq(trader:next_order_ref(), "000000000101", "higher MaxOrderRef wins")
    login(9, 999, "5000", 3) -- failed login
    t.eq(trader.session.SessionID, 400, "failed login ignored")
    t.eq(trader:next_order_ref(), "000000000102", "failed login keeps refs")

    -- not started: the request fails, nothing is returned, the ref is spent
    o, err = trader:order_insert("rb2601", 3500, 1, ctp.THOST_FTDC_OF_Open)
    t.eq(o, nil, "order_insert not started")
    t.eq(err, "trader not started", "order_insert not started message")
    t.eq(trader.order_ref, 103, "failed insert spends its ref")
    t.eq((trader:order_insert("rb2601", 3500, 0, ctp.THOST_FTDC_OF_Open)), nil, "zero volume refused")
    t.eq(trader.order_ref, 103, "zero volume spends no ref")

    -- the fields sent, captured instead of sent
    local sent
    trader.req = function (self, name, fields)
        sent = ctp.totable(self:request_struct(name, fields), "CThostFtdcInputOrderField")
        return 42
    end
    o = trader:order_insert("rb2601", 3500, -2, ctp.THOST_FTDC_OF_Close)
    t.eq(o.OrderRef, "000000000104", "identity: OrderRef")
    t.eq(o.FrontID, 1, "identity: FrontID")
    t.eq(o.SessionID, 400, "identity: SessionID")
    t.eq(o.BrokerID, "9999", "identity: BrokerID")
    t.eq(o.InvestorID, "000001", "identity: InvestorID")
    t.eq(sent.OrderRef, "000000000104", "sent OrderRef")
    t.eq(sent.InstrumentID, "rb2601", "sent InstrumentID")
    t.eq(sent.BrokerID, "9999", "sent BrokerID")
    t.eq(sent.Direction, ctp.THOST_FTDC_D_Sell, "negative volume sells")
    t.eq(sent.VolumeTotalOriginal, 2, "volume")
    t.eq(sent.CombOffsetFlag, string.char(ctp.THOST_FTDC_OF_Close), "offset flag")
    t.eq(sent.CombHedgeFlag, string.char(ctp.THOST_FTDC_HF_Speculation), "hedge flag")
    t.eq(sent.OrderPriceType, ctp.THOST_FTDC_OPT_LimitPrice, "limit order")
    t.eq(sent.LimitPrice, 3500, "limit price")
    t.eq(sent.TimeCondition, ctp.THOST_FTDC_TC_GFD, "limit order is GFD")
    t.eq(sent.VolumeCondition, ctp.THOST_FTDC_VC_AV, "any volume")
    t.eq(sent.MinVolume, 1, "min volume")
    t.eq(sent.ContingentCondition, ctp.THOST_FTDC_CC_Immediately, "immediately")
    t.eq(sent.ForceCloseReason, ctp.THOST_FTDC_FCC_NotForceClose, "not force close")

    o = trader:order_insert("rb2601", 0, 1, "0")
    t.eq(o.OrderRef, "000000000105", "next ref")
    t.eq(sent.Direction, ctp.THOST_FTDC_D_Buy, "positive volume buys")
    t.eq(sent.CombOffsetFlag, "0", "offset flag as a string")
    t.eq(sent.OrderPriceType, ctp.THOST_FTDC_OPT_LastPrice, "price 0: last price")
    t.eq(sent.TimeCondition, ctp.THOST_FTDC_TC_IOC, "price 0: IOC")
    t.eq(sent.LimitPrice, 0, "price 0: no limit price")

    -- recv takes the session from a login message itself: queue one as the
    -- SPI thread would
    local dir = os.getenv("CTPC_LIBDIR")
    local C = ffi.load(dir .. (ffi.os == "OSX" and "/libctpc.dylib" or "/libctpc.so"))
    local tr = ctp.new_trader { front_addr = "tcp://127.0.0.1:1", broker = "9999", user = "000001", pass = "p" }
    local f = ctp.new_struct("CThostFtdcRspUserLoginField", { FrontID = 5, SessionID = 77, MaxOrderRef = "41" })
    C.ctp_trader_send(tr.trader, C.ctp_rsp_new("OnRspUserLogin", "CThostFtdcRspUserLoginField", 1, true,
        f, ffi.sizeof(f), nil, 0))
    local msg = tr:recv(false)
    t.eq(msg and msg.func_name, "OnRspUserLogin", "login message received")
    t.eq(tr.session and tr.session.SessionID, 77, "recv sets the session")
    t.eq(tr:next_order_ref(), "000000000042", "recv grants MaxOrderRef")
end

t.done()
