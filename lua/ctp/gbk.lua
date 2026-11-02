-- GBK/GB18030 -> UTF-8 through the system iconv(3), called with the FFI.
--
-- CTP hands out text (error messages, order status, instrument names) in
-- GBK. iconv is part of glibc on Linux (ffi.C) and lives in libiconv.dylib on
-- macOS, so nothing has to be installed for this module.
--
-- Conversion is best effort: requiring this module never fails, and when
-- iconv cannot be opened to_utf8 hands its input back unchanged. Callers that
-- need to know can check `available` or `error`.
--
-- Each service VM is its own Lua state and loads its own copy, so the
-- converter below is never shared between threads.
local ffi = require "ffi"

local M = {}

-- Declared one by one: another module may already have declared some of
-- them, and a redefinition would fail the whole cdef.
for _, decl in ipairs {
    "typedef void *iconv_t;",
    "iconv_t iconv_open(const char *tocode, const char *fromcode);",
    "size_t iconv(iconv_t cd, char **inbuf, size_t *inbytesleft, char **outbuf, size_t *outbytesleft);",
    "int iconv_close(iconv_t cd);",
} do
    pcall(ffi.cdef, decl)
end

local ICONV_FAILED = ffi.cast("size_t", -1)
local EINVAL = 22 -- the same on Linux and macOS

local lib, cd, open_error

do
    local ok, l = pcall(function ()
        return ffi.os == "OSX" and ffi.load("iconv") or ffi.C
    end)
    if not ok then
        open_error = "cannot load iconv: " .. tostring(l)
    else
        local ok_open, h = pcall(l.iconv_open, "UTF-8", "GB18030") -- to, from
        if not ok_open then
            open_error = "iconv_open: " .. tostring(h)
        elseif h == ffi.cast("iconv_t", -1) then
            open_error = "iconv_open: GB18030 -> UTF-8 not supported (errno " .. ffi.errno() .. ")"
        else
            lib, cd = l, ffi.gc(h, l.iconv_close)
        end
    end
end

-- True when a converter is open and usable.
M.available = cd ~= nil

-- Why the converter is unusable, or nil when it is.
M.error = open_error

local inp = ffi.new("char *[1]")
local outp = ffi.new("char *[1]")
local inleft = ffi.new("size_t[1]")
local outleft = ffi.new("size_t[1]")

-- Convert s from GB18030. A string always comes back. ASCII is returned as
-- is without calling iconv. A sequence cut off at the end (CTP truncates
-- fixed-size fields mid-character) is dropped and the rest kept; any other
-- failure returns the input unchanged, so a broken string never breaks a
-- callback.
function M.to_utf8(s)
    if cd == nil or type(s) ~= "string" or not s:find("[\128-\255]") then return s end

    local n = #s
    -- GB18030 -> UTF-8 grows at most 1.5x (2 bytes -> 3); 4-byte stays 4
    local size = n * 2
    local inbuf = ffi.new("char[?]", n)
    ffi.copy(inbuf, s, n)
    local out = ffi.new("char[?]", size)

    lib.iconv(cd, nil, nil, nil, nil) -- reset the shift state
    inp[0], inleft[0] = inbuf, n
    outp[0], outleft[0] = out, size
    local r = lib.iconv(cd, inp, inleft, outp, outleft)
    if r == ICONV_FAILED and ffi.errno() ~= EINVAL then
        return s
    end
    return ffi.string(out, size - tonumber(outleft[0]))
end

return M
