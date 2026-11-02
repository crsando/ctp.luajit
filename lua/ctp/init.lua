-- ctp: LuaJIT binding of libctpc, the C bridge to the CTP SDK.
--
-- libctpc.so (Linux) / libctpc.dylib (macOS) and the cdefs.lua generated
-- with it (tools/gen.lua) are loaded from one library directory:
-- $CTPC_LIBDIR, or the one `make install` wrote into ctp.config. The two must
-- come from the same build; ctpc_build_info() is checked against cdefs.lua to
-- make sure.
--
-- The C side logs through the logger shared with service.lua; see
-- docs/logging.md.
local ffi = require "ffi"
local to_utf8 = require("ctp.gbk").to_utf8

local function find_libdir()
    local dir = os.getenv("CTPC_LIBDIR")
    if dir and dir ~= "" then return dir end
    local ok, config = pcall(require, "ctp.config")
    if ok and type(config) == "table" and config.libdir then return config.libdir end
    error("ctp: no library directory; run `make install` or set CTPC_LIBDIR", 0)
end

local LIBDIR = find_libdir()
local cdefs = assert(loadfile(LIBDIR .. "/cdefs.lua"))()
ffi.cdef(cdefs.cdef)

-- libctpc.so on Linux, libctpc.dylib on macOS. The name is spelled out
-- rather than left to ffi.load's suffix probing: a full path is passed, so
-- the loader never searches LD_LIBRARY_PATH / DYLD paths.
local LIBNAME = LIBDIR .. (ffi.os == "OSX" and "/libctpc.dylib" or "/libctpc.so")
local C = ffi.load(LIBNAME)

do
    local info = ffi.string(C.ctpc_build_info())
    if info ~= cdefs.build_info then
        error(string.format("ctp: %s is %q but cdefs.lua is %q; reinstall",
            LIBNAME, info, cdefs.build_info), 0)
    end
end

local M = {}

-- load constants (THOST_FTDC_*) directly into the module
for k, v in pairs(cdefs.constants) do
    M[k] = v
end

--
-- request results
--
local errors = {
    [C.CTPC_E_NETWORK] = "network failure",
    [C.CTPC_E_PENDING] = "too many pending requests",
    [C.CTPC_E_RATE] = "too many requests per second",
    [C.CTPC_E_NOT_STARTED] = "trader not started",
    [C.CTPC_E_INVALID] = "invalid argument",
    [C.CTPC_E_UNKNOWN] = "unknown CTP error",
}

-- Message for a negative ctp_trader_ReqXxx result.
function M.strerror(rc)
    return errors[rc] or ("error " .. tostring(rc))
end

--
-- struct layouts, from the generated cdefs.lua
--
local layouts = {} -- struct name -> { list = { { field, kind, size }, ... }, by_name = { ... }, text = { ... } }

-- String fields that CTP fills with GBK text (names, messages, memos); every
-- other string field is an ID, code, date or address. Decided by field name,
-- once per struct, so a tick (no such fields) costs nothing.
local TEXT_SUFFIXES = { "Name$", "Msg$", "Content$", "Memo$", "Remark$" }
local TEXT_FIELDS = { Message = true, RetInfo = true, UserEventInfo = true }

local function is_text_field(field)
    if TEXT_FIELDS[field] then return true end
    for _, p in ipairs(TEXT_SUFFIXES) do
        if field:find(p) then return true end
    end
    return false
end

local function layout(name)
    local l = layouts[name]
    if l == nil then
        local fields = cdefs.structs[name]
        if not fields then return nil end
        l = { list = fields, by_name = {}, text = {} }
        for _, f in ipairs(fields) do
            l.by_name[f[1]] = f
            if f[2] == "string" and is_text_field(f[1]) then
                l.text[#l.text + 1] = f[1]
            end
        end
        layouts[name] = l
    end
    return l
end

local struct_types = {} -- struct name -> ctype
local pointer_types = {} -- struct name -> ctype of a pointer to it

local function struct_type(name)
    local t = struct_types[name]
    if t == nil then
        t = ffi.typeof("struct " .. name)
        struct_types[name] = t
    end
    return t
end

local function pointer_type(name)
    local t = pointer_types[name]
    if t == nil then
        t = ffi.typeof("struct " .. name .. " *")
        pointer_types[name] = t
    end
    return t
end

-- Copy the struct p of type name into a Lua table: strings as strings, char
-- fields as their byte value, numbers as numbers. With utf8, the GBK text
-- fields (see is_text_field) are converted to UTF-8.
local function totable(p, name, utf8)
    local l = layout(name)
    if not l then return nil end
    local o = {}
    for _, f in ipairs(l.list) do
        local k = f[1]
        if f[2] == "string" then
            o[k] = ffi.string(p[k])
        else
            o[k] = tonumber(p[k])
        end
    end
    if utf8 then
        for _, k in ipairs(l.text) do
            o[k] = to_utf8(o[k])
        end
    end
    return o
end

-- Copy the values of t into the struct p of type name. A string must fit with
-- its terminating zero; a char field takes a one-character string or a byte.
local function fill(p, name, t)
    local l = layout(name)
    for k, v in pairs(t) do
        local f = l.by_name[k]
        if not f then
            error(string.format("%s has no field %s", name, tostring(k)), 3)
        end
        local kind = f[2]
        if kind == "string" then
            if type(v) ~= "string" then
                error(string.format("%s.%s: string expected, got %s", name, k, type(v)), 3)
            end
            if #v >= f[3] then
                error(string.format("%s.%s: %q is longer than %d bytes", name, k, v, f[3] - 1), 3)
            end
            ffi.copy(p[k], v)
        else
            if kind == "char" and type(v) == "string" and #v == 1 then
                v = v:byte()
            end
            if type(v) ~= "number" then
                error(string.format("%s.%s: number expected, got %s", name, k, type(v)), 3)
            end
            p[k] = v
        end
    end
end

-- A new struct of type name (e.g. "CThostFtdcQryOrderField"), filled from t.
function M.new_struct(name, t)
    if not layout(name) then error("unknown struct " .. tostring(name), 2) end
    local p = struct_type(name)()
    if t then fill(p, name, t) end
    return p
end

-- A Lua table copy of p, a struct of type name or a pointer to one. Strings
-- are the raw bytes; pass utf8 = true to convert the GBK text fields.
function M.totable(p, name, utf8)
    return totable(p, name, utf8)
end

-- Check a string bound for a fixed-size char array of a libctpc struct.
local function check_string(s, field, value, label)
    if type(value) ~= "string" then
        error(string.format("%s: %s must be a string, got %s", label, field, type(value)), 3)
    end
    if #value >= ffi.sizeof(s[field]) then
        error(string.format("%s: %s is longer than %d bytes", label, field, ffi.sizeof(s[field]) - 1), 3)
    end
    return value
end

-- The SDK crashes on a front address without "protocol://"; see ctpc.cpp.
local function check_front_addr(s, value, label)
    check_string(s, "front_addr", value, label)
    if not value:match("^%a[%w]*://.") then
        error(string.format("%s: front_addr %q must look like tcp://host:port", label, value), 3)
    end
    return value
end

-- A ctp_rsp_t as a Lua table: func_name, field_name, req_id, is_last, and
-- field / rsp_info converted with totable. This is the one place CTP text
-- turns into UTF-8: everything above it (templates, examples) only sees
-- UTF-8 in ErrorMsg, StatusMsg, InstrumentName and the other text fields.
local function cast_rsp(rsp)
    if rsp == nil then return nil end
    local rst = {}
    rst.req_id = tonumber(rsp.req_id)
    rst.field_name = ffi.string(rsp.field_name)
    rst.func_name = ffi.string(rsp.func_name)
    if rsp.field ~= nil and layout(rst.field_name) then
        rst.field = totable(ffi.cast(pointer_type(rst.field_name), rsp.field), rst.field_name, true)
    end
    if rsp.rsp_info ~= nil then
        rst.rsp_info = totable(ffi.cast(pointer_type("CThostFtdcRspInfoField"), rsp.rsp_info), "CThostFtdcRspInfoField", true)
    end
    rst.is_last = rsp.is_last
    return rst
end

local function symbols_table_to_char_pp(symbols)
    assert(type(symbols) == "table")
    local num = #symbols

    if num == 0 then
        return 0, "no valid symbol table"
    end

    local c_symbols = ffi.new("char *[?]", num)
    local buffers = {} -- 在lua里保存一下，避免被错误的gc回收
    for i = 1, num do
        local value = assert(symbols[i], "invalid symbol item")
        assert(type(value) == "string", "invalid symbol time: not string")

        -- +1 用于字符串末尾的 \0
        local buffer = ffi.new("char[?]", #value + 1)

        -- ffi.new 创建的内存默认清零，因此末尾已经是 \0
        ffi.copy(buffer, value, #value)

        buffers[i] = buffer
        c_symbols[i - 1] = buffer -- C 数组从 0 开始
    end

    return c_symbols, num, buffers
end

--
-- market data
--
local Collector = {}
Collector.__index = Collector

function M.new_collector(server)
    assert(server, "new_collector: server config required")

    local md = C.ctp_md_new()
    C.ctp_md_init(md,
        check_front_addr(md, server.front_addr, "new_collector"),
        check_string(md, "broker", server.broker, "new_collector"),
        check_string(md, "user", server.user, "new_collector"))

    return setmetatable({ md = md }, Collector)
end

function Collector:async(async)
    self.md.async = ffi.new("void *", async)
    return self
end

local md_states = {
    [C.CTPC_MD_DISCONNECTED] = "disconnected",
    [C.CTPC_MD_CONNECTED] = "connected",
    [C.CTPC_MD_LOGGED_IN] = "logged_in",
}

-- Returns 0 when sent, or a non-zero code and its message.
local function md_result(rc)
    rc = tonumber(rc)
    if rc == 0 then return 0 end
    return rc, rc < 0 and M.strerror(rc) or ("CTP error " .. rc)
end

function Collector:subscribe(symbols)
    local c_symbols, num, buffers = symbols_table_to_char_pp(symbols)
    return md_result(C.ctp_md_subscribe(self.md, c_symbols, num))
end

function Collector:unsubscribe(symbols)
    local c_symbols, num, buffers = symbols_table_to_char_pp(symbols)
    return md_result(C.ctp_md_unsubscribe(self.md, c_symbols, num))
end

-- Create the API and start connecting; whether that works arrives later as
-- OnFrontConnected / OnRspUserLogin messages. Returns self, or nil and an
-- error when the API could not be created (see the log).
function Collector:start()
    if C.ctp_md_start(self.md) ~= 1 then
        return nil, "ctp_md_start failed"
    end
    return self
end

function Collector:stop()
    C.ctp_md_stop(self.md)
    return self
end

-- The next message (see ctp_md_recv in ctpc.h) as a table, or nil.
function Collector:recv(blocking)
    local rsp = C.ctp_md_recv(self.md, blocking)
    local t = cast_rsp(rsp)
    C.ctp_rsp_free(rsp)
    return t
end

-- "disconnected", "connected" or "logged_in"
function Collector:state()
    return md_states[tonumber(self.md.state)]
end

function Collector:is_ready()
    return self.md.state == C.CTPC_MD_LOGGED_IN
end

-- Ticks dropped because Lua did not keep up.
function Collector:ticks_dropped()
    return tonumber(C.ctp_md_ticks_dropped(self.md))
end

--
-- trading
--
local Trader = {}
Trader.__index = Trader

-- server: front_addr, broker, user, pass, and app_id / auth_code for
-- terminal authentication (empty when the front does not require it).
function M.new_trader(server)
    assert(server, "new_trader: server config required")
    local trader = C.ctp_trader_new()
    C.ctp_trader_init(trader,
        check_front_addr(trader, server.front_addr, "new_trader"),
        check_string(trader, "broker", server.broker, "new_trader"),
        check_string(trader, "user", server.user, "new_trader"),
        check_string(trader, "password", server.pass, "new_trader"),
        check_string(trader, "app_id", server.app_id or "", "new_trader"),
        check_string(trader, "auth_code", server.auth_code or "", "new_trader")
    )
    return setmetatable({
        trader = trader,
        -- filled into every request whose struct has these fields
        defaults = { BrokerID = server.broker, InvestorID = server.user },
        session = nil, -- FrontID / SessionID of the last login; see on_login
        order_ref = 0, -- the last order ref allocated or granted by a login
    }, Trader)
end

local trader_states = {
    [C.CTPC_TRADER_DISCONNECTED] = "disconnected",
    [C.CTPC_TRADER_CONNECTED] = "connected",
    [C.CTPC_TRADER_AUTHENTICATED] = "authenticated",
    [C.CTPC_TRADER_LOGGED_IN] = "logged_in",
    [C.CTPC_TRADER_READY] = "ready",
}

-- Create the API and start connecting; the login chain's outcome arrives
-- later as messages (see ctp_trader_start in ctpc.h). Returns self, or nil
-- and an error when the API could not be created (see the log).
function Trader:start()
    if C.ctp_trader_start(self.trader) ~= 1 then
        return nil, "ctp_trader_start failed"
    end
    return self
end

function Trader:stop()
    C.ctp_trader_stop(self.trader)
    return self
end

function Trader:async(async)
    self.trader.async = ffi.new("void*", async)
    return self
end

-- "disconnected", "connected", "authenticated", "logged_in" or "ready"
function Trader:state()
    return trader_states[tonumber(self.trader.state)]
end

function Trader:is_ready()
    return self.trader.state == C.CTPC_TRADER_READY
end

-- The struct for CThostFtdcTraderApi::Req<name>, filled from fields.
-- BrokerID / InvestorID default to the account's. Unknown requests, unknown
-- fields and oversized strings raise an error.
function Trader:request_struct(name, fields)
    local st = cdefs.requests[name]
    if not st then error("unknown request " .. tostring(name), 3) end
    local p = struct_type(st)()
    local by_name = layout(st).by_name
    for k, v in pairs(self.defaults) do
        if by_name[k] then fill(p, st, { [k] = v }) end
    end
    if fields then fill(p, st, fields) end
    return p
end

-- Send CThostFtdcTraderApi::Req<name>, e.g. trader:req("QryOrder", { InstrumentID = "rb2601" }).
-- Returns the request id, matched by the OnRsp<name> responses, or a
-- negative code and its message. Bad arguments raise as in request_struct.
function Trader:req(name, fields)
    local p = self:request_struct(name, fields)
    local rc = C["ctp_trader_Req" .. name](self.trader, p)
    if rc < 0 then return rc, M.strerror(rc) end
    return rc
end

function Trader:recv_raw(blocking)
    -- raw receive: the caller frees the message with ctp_rsp_free
    return C.ctp_trader_recv(self.trader, blocking)
end

-- The next message as a table, or nil. A successful OnRspUserLogin also
-- updates the session (on_login) before it is returned.
function Trader:recv(blocking)
    local rsp = C.ctp_trader_recv(self.trader, blocking)
    local t = cast_rsp(rsp)
    C.ctp_rsp_free(rsp)
    if t and t.func_name == "OnRspUserLogin" then self:on_login(t) end
    return t
end

--
-- order refs
--
-- Allocated here, in the one thread that owns the trader, and fixed before
-- the order is sent: the SPI thread never touches them. CTP wants them
-- increasing within a session (ErrorID 22 otherwise). A login grants
-- MaxOrderRef; the next ref is above both it and every ref used before, so
-- refs never go back across reconnects either.

-- Take the session from an OnRspUserLogin message; failed logins are ignored.
function Trader:on_login(rsp)
    local f = rsp and rsp.field
    if not f or (rsp.rsp_info and rsp.rsp_info.ErrorID ~= 0) then return end
    self.session = { FrontID = f.FrontID, SessionID = f.SessionID }
    self.order_ref = math.max(self.order_ref, tonumber(f.MaxOrderRef) or 0)
end

-- The next order ref, as 12 digits (TThostFtdcOrderRefType holds 12), or nil
-- and an error before the first login.
function Trader:next_order_ref()
    if not self.session then return nil, "not logged in" end
    self.order_ref = self.order_ref + 1
    return string.format("%012d", self.order_ref)
end

-- Insert an order. symbol: InstrumentID; price < 0.0001: LastPrice + IOC,
-- otherwise a limit order good for the day; volume: buy when positive, sell
-- when negative; flag: the offset, THOST_FTDC_OF_* (a byte or a 1-char
-- string). Returns the order's identity, BrokerID / InvestorID / FrontID /
-- SessionID / OrderRef, as CTP reports it back in OnRtnOrder; or nil and an
-- error when the order could not be sent.
function Trader:order_insert(symbol, price, volume, flag)
    if type(volume) ~= "number" or volume == 0 then
        return nil, "volume must be a non-zero number"
    end
    local ref, err = self:next_order_ref()
    if not ref then return nil, err end
    local fields = {
        InstrumentID = symbol,
        OrderRef = ref,
        Direction = volume > 0 and M.THOST_FTDC_D_Buy or M.THOST_FTDC_D_Sell,
        VolumeTotalOriginal = math.abs(volume),
        CombOffsetFlag = type(flag) == "number" and string.char(flag) or flag,
        CombHedgeFlag = string.char(M.THOST_FTDC_HF_Speculation),
        VolumeCondition = M.THOST_FTDC_VC_AV,
        MinVolume = 1,
        ContingentCondition = M.THOST_FTDC_CC_Immediately,
        ForceCloseReason = M.THOST_FTDC_FCC_NotForceClose,
        IsAutoSuspend = 0,
        UserForceClose = 0,
    }
    if price < 0.0001 then
        fields.OrderPriceType = M.THOST_FTDC_OPT_LastPrice
        fields.TimeCondition = M.THOST_FTDC_TC_IOC -- 立即成交否则撤销
    else
        fields.OrderPriceType = M.THOST_FTDC_OPT_LimitPrice
        fields.LimitPrice = price
        fields.TimeCondition = M.THOST_FTDC_TC_GFD -- 当日有效
    end
    local rc, msg = self:req("OrderInsert", fields)
    if rc < 0 then return nil, msg end
    return {
        BrokerID = self.defaults.BrokerID,
        InvestorID = self.defaults.InvestorID,
        FrontID = self.session.FrontID,
        SessionID = self.session.SessionID,
        OrderRef = ref,
    }
end

-- order_cancel(order) or order_cancel(symbol, exchange_id, order_sys_id)
function Trader:order_cancel(symbol, exchange_id, order_sys_id)
    if type(symbol) == "table" then
        local order = symbol
        symbol = order.InstrumentID
        exchange_id = order.ExchangeID
        order_sys_id = order.OrderSysID
    end
    return self:req("OrderAction", {
        ActionFlag = M.THOST_FTDC_AF_Delete,
        InstrumentID = symbol,
        ExchangeID = exchange_id,
        OrderSysID = order_sys_id,
    })
end

function Trader:logout()
    return self:req("UserLogout", { UserID = self.defaults.InvestorID })
end

function Trader:password_update(pass_old, pass_new)
    local rc, err = self:req("UserPasswordUpdate", {
        UserID = self.defaults.InvestorID,
        OldPassword = pass_old,
        NewPassword = pass_new,
    })
    -- The next login uses the new password, whether or not the change
    -- succeeds; see DESIGN.md.
    if rc > 0 then
        ffi.copy(self.trader.password, pass_new)
    end
    return rc, err
end

function Trader:session_info()
    return {
        BrokerID = ffi.string(self.trader.broker),
        InvestorID = ffi.string(self.trader.user),
        FrontID = tonumber(self.trader.front_id),
        SessionID = tonumber(self.trader.session_id),
    }
end

return M
