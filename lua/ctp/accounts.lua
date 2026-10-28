local function load_accounts()
    -- 获取家目录路径（兼容 Windows 和 Linux/macOS）
    local home = os.getenv("HOME") or os.getenv("USERPROFILE")
    if not home then return nil end

    local filepath = home .. "/.ctp.luajit/accounts.lua"

    -- 加载文件（此时只编译不执行）
    local chunk, err = loadfile(filepath)
    if not chunk then
        error("failed loading: " .. tostring(err))
    end

    -- 执行文件，获取返回值
    -- 假设 accounts.lua 结尾有 return 了一个 table
    local accounts = chunk() 
    return accounts
end

return load_accounts()