-- GBK/GB18030 -> UTF-8 via iconv.lua (the project's own POSIX iconv binding).
--
-- CTP hands out text (error messages, instrument names) in GBK. iconv.lua is
-- required for that: it is the module the templates expect, with the
-- converter-object API
--
--     local cv = assert(iconv.open("UTF-8", "GB18030"))  -- to, from
--     cv:convert(s)
--
-- A missing iconv is not fatal — the templates treat conversion as best
-- effort — so requiring this module never fails: when iconv cannot be loaded
-- or opened, to_utf8 hands its input back unchanged. Callers that need to
-- know can check `available` or `error`.

local M = {}

local cv, open_error

do
    local ok, iconv = pcall(require, "iconv")
    if not ok then
        open_error = "cannot load iconv: " .. tostring(iconv)
    elseif type(iconv.open) ~= "function" then
        open_error = "iconv has no open(); iconv.lua is required"
    else
        local ok_open, err
        ok_open, cv, err = pcall(iconv.open, "UTF-8", "GB18030") -- to, from
        if not ok_open then
            open_error = "iconv.open: " .. tostring(err)
            cv = nil
        elseif not cv then
            open_error = "iconv.open: " .. tostring(err and err.message or err)
        end
    end
end

-- True when a converter is open and usable.
M.available = cv ~= nil

-- Why the converter is unusable, or nil when it is.
M.error = open_error

-- Convert s from GB18030. A string always comes back: on any failure the
-- input is returned as is, so a broken sequence never breaks a callback.
function M.to_utf8(s)
    if cv == nil or type(s) ~= "string" or s == "" then return s end
    local ok, r = pcall(cv.convert, cv, s)
    if ok and type(r) == "string" then return r end
    return s
end

return M
