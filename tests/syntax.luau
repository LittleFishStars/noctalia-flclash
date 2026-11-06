--!nocheck
-- tests/syntax.luau —— 用 luau CLI 做纯语法检查：luau tests/syntax.luau
-- 只编译不执行，因此不需要假宿主。
local files = {
    "lib/flclash.luau",
    "bar.luau",
    "panel.luau",
}

for _, path in ipairs(files) do
    local chunk, err = loadfile(path)
    if chunk == nil then
        print("[FAIL] " .. path .. "\n  " .. tostring(err))
    else
        print("[ok] " .. path)
    end
end
