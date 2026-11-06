--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- tests/panel_assert.luau —— panel.luau 的完整渲染链冒烟
-- 前置：env.luau（假宿主）+ lib + panel 源码已拼进同一 chunk。
-- panel 顶层 draw() 已执行过一次（加载即渲染），这里继续驱动交互。
-- ══════════════════════════════════════════════════════════════════════════

-- onOpen：开流（假宿主返回 nil → 走差分兜底）+ 全量刷新 + 渲染
onOpen("test")
ok(RENDERED ~= nil, "onOpen 后已渲染")
ok(findNode(RENDERED, "scroll") ~= nil, "面板根节点是滚动区")
ok(findNode(RENDERED, "graph") ~= nil, "流量卡包含速率曲线")
ok(countNodes(RENDERED, "column", function(n)
    return n.props.fill == "surface_variant/0.35"
end) >= 2, "流量卡与控制卡都有填充底色")
ok(countNodes(RENDERED, "box", function(n)
    return n.props.border ~= nil
end) == 0, "整体不用边框画层级")

-- 分组卡：主代理 / 自动选择 / GLOBAL（hidden 默认不显示）
local groupCards = countNodes(RENDERED, "column", function(n)
    return n.props.fill == "surface_variant/0.3"
end)
eq(groupCards, 3, "可见分组卡数量")
ok(countNodes(RENDERED, "label", function(n)
    return n.props.text == "代理分组"
end) >= 1, "分组分区标题")

--- 找分组头行：带 onClick 的 row，且子节点里有对应组名的 label
local function headRowOf(groupName)
    local function walk(t)
        if t == nil or type(t) ~= "table" then
            return nil
        end
        if t.type == "row" and t.props.onClick ~= nil then
            for _, child in ipairs(t.children or {}) do
                if child.type == "label" and child.props.text == groupName then
                    return t
                end
            end
        end
        for _, child in ipairs(t.children or {}) do
            local hit = walk(child)
            if hit ~= nil then
                return hit
            end
        end
        return nil
    end
    return walk(RENDERED)
end

-- 展开第一张分组卡（主代理）
local head = headRowOf("主代理")
ok(head ~= nil, "找到主代理分组头行")
head.props.onClick()
ok(RENDERED ~= nil, "展开后重渲染")
ok(countNodes(RENDERED, "row", function(n)
    return n.props.fill == "surface_variant/0.5"
end) >= 1, "当前节点行有选中底色")
ok(countNodes(RENDERED, "button", function(n)
    return n.props.text == "整组测速"
end) == 1, "展开后有整组测速按钮")

-- 点击第一个节点行 → PUT 切换节点
local nodeLine = findNode(RENDERED, "row", function(n)
    return n.props.onClick ~= nil
        and n.props.tooltip ~= nil
        and tostring(n.props.tooltip):find("切换到", 1, true) ~= nil
end)
ok(nodeLine ~= nil, "找到节点行")
local before = #REQUESTS
nodeLine.props.onClick()
eq(#REQUESTS, before + 2, "点击节点：PUT 切换 + 重拉 /proxies")
eq(REQUESTS[before + 1].method, "PUT", "切换节点是 PUT")
eq(jsonDecode(REQUESTS[before + 1].body).name, "自动选择", "切换到分组第一个节点")
eq(REQUESTS[before + 2].url, "/proxies", "切换后重拉分组")

-- 整组测速按钮
local testBtn = findNode(RENDERED, "button", function(n)
    return n.props.text == "整组测速"
end)
ok(testBtn ~= nil, "测速按钮存在")
local beforeTest = #REQUESTS
testBtn.props.onClick()
eq(#REQUESTS, beforeTest + 2, "测速：GET delay + 重拉 /proxies")
eq(REQUESTS[beforeTest + 1].method, "GET", "测速是 GET")
ok(REQUESTS[beforeTest + 1].url:find("/group/", 1, true) == 1, "测速路径")

-- 收起分组
head = headRowOf("主代理")
head.props.onClick()
eq(countNodes(RENDERED, "row", function(n)
    return n.props.fill == "surface_variant/0.5"
end), 0, "收起后没有节点行")

-- 模式切换：点「全局」按钮 → PATCH {"mode":"global"}
-- 假宿主的 tr 返回键名本身，面板回落到内置中文兜底，因此按钮文本是中文
local globalBtn = findNode(RENDERED, "button", function(n)
    return n.props.text == "全局"
end)
ok(globalBtn ~= nil, "全局模式按钮存在")
ok(findNode(RENDERED, "button", function(n)
    return n.props.text == "规则"
end) ~= nil, "规则模式按钮存在")
ok(findNode(RENDERED, "button", function(n)
    return n.props.text == "直连"
end) ~= nil, "直连模式按钮存在")
local beforeMode = #REQUESTS
globalBtn.props.onClick()
eq(#REQUESTS, beforeMode + 2, "切模式：PATCH + 重拉 /configs")
eq(REQUESTS[beforeMode + 1].method, "PATCH", "切模式是 PATCH")
eq(jsonDecode(REQUESTS[beforeMode + 1].body).mode, "global", "切模式 body")
eq(REQUESTS[beforeMode + 2].url, "/configs", "切模式后重拉配置")

-- TUN 开关 → PATCH {"tun":{"enable":false}}
local tunToggle = findNode(RENDERED, "toggle")
ok(tunToggle ~= nil, "TUN 开关存在")
eq(tunToggle.props.checked, true, "TUN 初始开启（canned 配置）")
local beforeTun = #REQUESTS
tunToggle.props.onChange("false")
eq(#REQUESTS, beforeTun + 2, "切换 TUN：PATCH + 重拉 /configs")
eq(jsonDecode(REQUESTS[beforeTun + 1].body).tun.enable, false, "TUN body")

-- 连接区：展开后出现连接卡与断开按钮
local connsHead = headRowOf("活动连接")
ok(connsHead ~= nil, "找到连接分区头")
connsHead.props.onClick()
ok(countNodes(RENDERED, "column", function(n)
    return n.props.fill == "surface_variant/0.3"
end) >= 2, "展开后出现连接卡")
ok(countNodes(RENDERED, "button", function(n)
    return n.props.tooltip == "断开全部连接"
end) == 1, "连接头有清空按钮")

-- 离线态：请求全挂后标题图标变 error
FAIL_MODE = true
REQUESTS = {}
requestConns()
-- http 回调只标脏，重绘发生在 tick：这正是不超 CPU budget 的关键
eq(role_before_tick(), "primary", "回调内不重绘（标题仍是上一帧）")
update()
local titleGlyph = findNode(RENDERED, "glyph", function(n)
    return n.props.name == "world"
end)
eq(titleGlyph.props.color, "error", "tick 重绘后标题图标 error")
FAIL_MODE = false

print(string.format("[panel] %d 项断言通过", CHECKS))
