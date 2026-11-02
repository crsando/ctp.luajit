-- ctp.order_rules: order decisions as pure functions — no CTP calls, no
-- service, plain tables in and out — so they can be tested offline.
--
--   valid_price(p)                                  CTP marks no price with DBL_MAX
--   round_tick(p, tick)
--   aggressive_price(md, tick, side, slip_ticks)    price that crosses the book
--   close_plan(positions, symbol, side, exchange, volume, opts)
--                                                   legs { offset, volume } to place
--
-- side is "buy" or "sell". positions are CThostFtdcInvestorPositionField
-- rows (query_position), md a CThostFtdcDepthMarketDataField
-- (query_depth_market_data).
local ctp = require "ctp"

local M = {}

-- SHFE and INE keep today's and yesterday's positions apart: '1' (Close)
-- closes yesterday's only, today's need '3' (CloseToday).
M.SPLIT_TODAY = { SHFE = true, INE = true }

-- A real price: CTP fills missing prices with DBL_MAX.
function M.valid_price(p)
    return type(p) == "number" and p > 0 and p < 1e300
end

-- Decimal places of a tick such as 0.2 or 0.005.
local function decimals(tick)
    local frac = string.format("%.10g", tick):match("%.(%d+)$")
    return frac and #frac or 0
end

-- p rounded to a multiple of tick, without float residue (n * 0.2 can give
-- 3966.6000000000004).
function M.round_tick(p, tick)
    local n = math.floor(p / tick + 0.5)
    return tonumber(string.format("%." .. decimals(tick) .. "f", n * tick))
end

-- A limit price that should fill at once: the opposite best (ask to buy,
-- bid to sell; the last price when that side is empty), slip_ticks further,
-- within the price limits. nil and an error when md has no usable price.
function M.aggressive_price(md, tick, side, slip_ticks)
    if not md then return nil, "no market data" end
    if not (type(tick) == "number" and tick > 0) then return nil, "no price tick" end
    slip_ticks = slip_ticks or 0
    local base, price
    if side == "buy" then
        base = M.valid_price(md.AskPrice1) and md.AskPrice1 or md.LastPrice
        if not M.valid_price(base) then return nil, "no price" end
        price = M.round_tick(base + slip_ticks * tick, tick)
        if M.valid_price(md.UpperLimitPrice) then price = math.min(price, md.UpperLimitPrice) end
    elseif side == "sell" then
        base = M.valid_price(md.BidPrice1) and md.BidPrice1 or md.LastPrice
        if not M.valid_price(base) then return nil, "no price" end
        price = M.round_tick(base - slip_ticks * tick, tick)
        if M.valid_price(md.LowerLimitPrice) then price = math.max(price, md.LowerLimitPrice) end
    else
        return nil, "side must be buy or sell"
    end
    return price
end

-- The position side an order of this side closes: buying closes shorts.
function M.opposite(side)
    return side == "buy" and ctp.THOST_FTDC_PD_Short or ctp.THOST_FTDC_PD_Long
end

-- Closable volume of symbol's position in direction dir: { yd, td, held }.
-- Pending close orders are taken out (a long position's are in ShortFrozen,
-- a short one's in LongFrozen). Exchanges that do not split today / yesterday
-- count everything as yd.
local function closable(positions, symbol, dir, exchange)
    local frozen_key = dir == ctp.THOST_FTDC_PD_Long and "ShortFrozen" or "LongFrozen"
    local c = { yd = 0, td = 0, held = 0 }
    for _, p in ipairs(positions or {}) do
        if p.InstrumentID == symbol and p.PosiDirection == dir and (p.Position or 0) > 0 then
            c.held = c.held + p.Position
            local avail = math.max(p.Position - (p[frozen_key] or 0), 0)
            if M.SPLIT_TODAY[exchange] and p.PositionDate == ctp.THOST_FTDC_PSD_Today then
                c.td = c.td + avail
            else
                c.yd = c.yd + avail
            end
        end
    end
    return c
end
M.closable = closable

-- Legs for a net order of volume lots: close the opposite position first,
-- then open whatever is left (selling 3 against 2 long: close 2, open 1
-- short). Returns legs, a list of { offset = THOST_FTDC_OF_*, volume = n },
-- and the closable summary { yd, td, held }.
-- opts.close_today_first: on SHFE / INE close today's before yesterday's
-- (default: yesterday's first).
function M.close_plan(positions, symbol, side, exchange, volume, opts)
    assert(side == "buy" or side == "sell", "side must be buy or sell")
    assert(type(volume) == "number" and volume > 0 and volume % 1 == 0, "volume must be a positive integer")
    local c = closable(positions, symbol, M.opposite(side), exchange)
    local order
    if M.SPLIT_TODAY[exchange] then
        local yd = { offset = ctp.THOST_FTDC_OF_CloseYesterday, n = c.yd }
        local td = { offset = ctp.THOST_FTDC_OF_CloseToday, n = c.td }
        order = (opts and opts.close_today_first) and { td, yd } or { yd, td }
    else
        order = { { offset = ctp.THOST_FTDC_OF_Close, n = c.yd } }
    end

    local legs, left = {}, volume
    for _, o in ipairs(order) do
        local n = math.min(left, o.n)
        if n > 0 then
            legs[#legs + 1] = { offset = o.offset, volume = n }
            left = left - n
        end
    end
    if left > 0 then
        legs[#legs + 1] = { offset = ctp.THOST_FTDC_OF_Open, volume = left }
    end
    return legs, c
end

M.OFFSET_NAME = {
    [ctp.THOST_FTDC_OF_Open] = "open",
    [ctp.THOST_FTDC_OF_Close] = "close",
    [ctp.THOST_FTDC_OF_CloseToday] = "close_today",
    [ctp.THOST_FTDC_OF_CloseYesterday] = "close_yesterday",
}

return M
