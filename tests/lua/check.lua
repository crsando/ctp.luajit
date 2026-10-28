-- Minimal assertions for the Lua tests: failures are counted and reported,
-- done() exits non-zero if any.
local M = {}
local failures, checks = 0, 0

local function fail(label, msg)
    failures = failures + 1
    io.stderr:write(string.format("FAIL %s: %s\n", label, msg))
end

function M.eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        fail(label, string.format("got %s, want %s", tostring(got), tostring(want)))
    end
end

-- f must raise an error whose message contains pattern (plain text).
function M.raises(f, pattern, label)
    checks = checks + 1
    local ok, err = pcall(f)
    if ok then
        fail(label, "no error raised")
    elseif not tostring(err):find(pattern, 1, true) then
        fail(label, "error " .. tostring(err) .. " does not contain " .. pattern)
    end
end

function M.done()
    local name = arg and arg[0] or "test"
    if failures > 0 then
        io.stderr:write(string.format("%s: %d of %d checks failed\n", name, failures, checks))
        os.exit(1)
    end
    print(string.format("%s: %d checks ok", name, checks))
end

return M
