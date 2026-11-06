--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- panel.luau —— FlClash / mihomo 控制面板
--
-- 自上而下（填充色阶画层级、不用边框、颜色只给状态）：
--   流量卡    实时 ↓/↑ 大数字 + 速率曲线（/traffic 流，60s 窗口）+ 累计/连接/内存
--   控制卡    模式分段按钮（规则/全局/直连）· TUN 开关 · 允许局域网开关
--   代理分组  每组一张卡：当前节点与延迟；展开后逐节点点选，支持整组测速
--   活动连接  按速率排序的连接列表；单条断开 / 一键清空
--   工具行    清除 fake-ip 缓存 · 数据源说明
--
-- 写操作仅由用户点击触发：PUT /proxies、PATCH /configs、DELETE /connections、
-- POST /cache/fakeip/flush；其余全部只读。
--
-- 打开方式：栏组件左键，或
--   noctalia msg panel-toggle ylxc/flclash:panel
-- ══════════════════════════════════════════════════════════════════════════

local f = require("./lib/flclash.luau")

-- ── 运行状态 ───────────────────────────────────────────────────────────────

local open = false
local snap = nil -- /connections 快照
local cfgSnap = nil -- /configs 快照
local proxies = nil -- /proxies map（proxies 字段）
local version = nil -- /version
local lastOk = nil -- 最近一轮是否全绿；nil = 还没轮询过
local lastAt = 0 -- 最近一次任何数据到达的时刻（秒）

local downRing = {} -- 速率曲线样本（B/s）
local upRing = {}
local speeds = { down = 0, up = 0 }
local stream = nil
local streamAlive = false
local prevTotals = nil -- 差分基线 { at(ms), dl, ul }

local prevConn = { at = nil, map = {} } -- 连接差分基线
local rows = {} -- 连接行（已差分排序）
local connCount = 0
local connNowMs = 0 -- 快照到达时刻（毫秒），供 update() 做连接差分
local dirty = false -- 数据到了但还没重绘；http 回调只标脏，不做重活

local delayCache = {} -- { [组名] = { [节点名] = ms } }
local testing = {} -- { [组名] = true }
local expanded = nil -- 当前展开的组名
local nodesOpen = {} -- { [组名] = true } 节点列表是否超过首屏限制后展开
local connsOpen = false

local inflightConns = false
local inflightProxies = false
local inflightCfg = false
local lastConnsAt = 0
local lastProxiesAt = 0
local lastCfgAt = 0

local draw, requestConns, requestProxies -- 前向声明

local function tr(key, fallback)
    return f.tr(key, fallback)
end

-- ── 抓取 ───────────────────────────────────────────────────────────────────

local function pushSample(d, u, cfg)
    f.ringPush(downRing, d, cfg.history)
    f.ringPush(upRing, u, cfg.history)
    speeds.down = d
    speeds.up = u
end

local function startStream()
    if stream ~= nil then
        return
    end
    local handle = f.startTraffic(function(sample)
        if open and streamAlive then
            pushSample(sample.down or 0, sample.up or 0, f.cfg())
            dirty = true -- 由 update() 统一重绘，流回调里不构建渲染树
        end
    end, function()
        streamAlive = false
        stream = nil
        prevTotals = nil
    end)
    if handle ~= nil then
        stream = handle
        streamAlive = true
    end
end

local function stopStream()
    if stream ~= nil then
        streamAlive = false
        pcall(function()
            stream.stop()
        end)
        stream = nil
    end
    prevTotals = nil
end

--- /connections 累计量差分（流不可用时的兜底速率源）
local function applyDiff(data, nowMs)
    local dl = data.downloadTotal or 0
    local ul = data.uploadTotal or 0
    if prevTotals ~= nil then
        local dt = (nowMs - prevTotals.at) / 1000
        if dt > 0.2 then
            local d = math.max(0, (dl - prevTotals.dl) / dt)
            local u = math.max(0, (ul - prevTotals.ul) / dt)
            if not streamAlive then
                pushSample(d, u, f.cfg())
            end
        end
    end
    prevTotals = { at = nowMs, dl = dl, ul = ul }
end

requestConns = function()
    if inflightConns then
        return
    end
    inflightConns = true
    f.connections(function(ok, _status, data)
        inflightConns = false
        if ok and type(data) == "table" then
            snap = data
            connCount = data.connections and #data.connections or 0
            connNowMs = noctalia.nowMs()
            applyDiff(data, connNowMs)
            lastOk = true
            lastAt = os.time()
        else
            lastOk = false
            lastAt = os.time()
        end
        dirty = true -- http 回调里绝不构建渲染树
    end)
end

requestProxies = function()
    if inflightProxies then
        return
    end
    inflightProxies = true
    f.proxies(function(ok, _status, data)
        inflightProxies = false
        if ok and type(data) == "table" then
            proxies = data.proxies
            lastAt = os.time()
            dirty = true
        end
    end)
end

local function requestCfg()
    if inflightCfg then
        return
    end
    inflightCfg = true
    f.configs(function(ok, _status, data)
        inflightCfg = false
        if ok and type(data) == "table" then
            cfgSnap = data
            lastAt = os.time()
            dirty = true
        end
    end)
end

local function fetchVersion()
    f.version(function(ok, _status, data)
        if ok and type(data) == "table" then
            version = data
            dirty = true
        end
    end)
end

local function refreshAll()
    requestConns()
    requestCfg()
    requestProxies()
end

-- ── 写操作 ─────────────────────────────────────────────────────────────────

local function notifyFail(what, errMsg)
    noctalia.notifyError(what, errMsg or tr("action_failed", "操作失败"))
end

local function patchMode(mode)
    if cfgSnap ~= nil then
        cfgSnap.mode = mode -- 乐观更新，失败由下一轮轮询纠正
        draw()
    end
    f.patchConfigs({ mode = mode }, function(ok, _status, _data, errMsg)
        if not ok then
            notifyFail(tr("mode_title", "切换模式"), errMsg)
        end
        requestCfg()
    end)
end

local function patchTun(enable)
    if cfgSnap ~= nil and cfgSnap.tun ~= nil then
        cfgSnap.tun.enable = enable
        draw()
    end
    f.patchConfigs({ tun = { enable = enable } }, function(ok, _status, _data, errMsg)
        if not ok then
            notifyFail(tr("tun_title", "TUN 模式"), errMsg)
        end
        requestCfg()
    end)
end

local function patchLan(enable)
    if cfgSnap ~= nil then
        cfgSnap["allow-lan"] = enable
        draw()
    end
    f.patchConfigs({ ["allow-lan"] = enable }, function(ok, _status, _data, errMsg)
        if not ok then
            notifyFail(tr("lan_title", "允许局域网"), errMsg)
        end
        requestCfg()
    end)
end

local function selectNode(group, node)
    if proxies ~= nil and proxies[group] ~= nil then
        proxies[group].now = node -- 乐观更新
        draw()
    end
    f.selectProxy(group, node, function(ok, _status, _data, errMsg)
        if not ok then
            notifyFail(tr("select_failed", "切换节点"), errMsg)
        end
        requestProxies()
    end)
end

local function testGroup(group)
    testing[group] = true
    draw()
    local cfg = f.cfg()
    f.groupDelay(group, cfg, function(ok, _status, data, errMsg)
        testing[group] = nil
        if ok and type(data) == "table" then
            local per = {}
            for name, ms in pairs(data) do
                per[name] = tonumber(ms)
            end
            delayCache[group] = per
        else
            notifyFail(tr("delay_title", "延迟测速"), errMsg)
        end
        -- mihomo 测速后 history 已更新；重拉一份保持 extra 一致
        requestProxies()
        draw()
    end)
end

local function closeOne(id)
    f.closeConn(id, function(ok, _status, _data, errMsg)
        if not ok then
            notifyFail(tr("close_conn", "断开连接"), errMsg)
        end
        requestConns()
    end)
end

local function closeAll()
    f.closeAllConns(function(ok, _status, _data, errMsg)
        if not ok then
            notifyFail(tr("close_all", "断开全部连接"), errMsg)
        end
        prevConn = { at = nil, map = {} }
        requestConns()
    end)
end

local function flushFakeip()
    f.flushFakeip(function(ok, _status, _data, errMsg)
        if ok then
            noctalia.notify(tr("flush_ok", "fake-ip 缓存已清除"))
        else
            notifyFail(tr("flush_title", "清除 fake-ip"), errMsg)
        end
    end)
end

-- ── 派生 ───────────────────────────────────────────────────────────────────

local function mode()
    if cfgSnap ~= nil and cfgSnap.mode ~= nil then
        return tostring(cfgSnap.mode)
    end
    return "rule"
end

local function tunEnabled()
    return cfgSnap ~= nil and cfgSnap.tun ~= nil and cfgSnap.tun.enable == true
end

local function lanEnabled()
    return cfgSnap ~= nil and cfgSnap["allow-lan"] == true
end

--- 节点当前延迟：组测速缓存优先，其次 mihomo 的 history
local function nodeDelay(group, name, cfg)
    local per = delayCache[group]
    if per ~= nil and per[name] ~= nil then
        return per[name]
    end
    if proxies ~= nil then
        return f.delayOf(proxies[name], cfg.testUrl)
    end
    return nil
end

-- ── 小组件 ─────────────────────────────────────────────────────────────────

local function sectionHead(glyph, text, count, extra)
    local head = {
        ui.glyph({ name = glyph, size = 14, color = "on_surface_variant" }),
        ui.label({ text = text, fontWeight = "semibold" }),
    }
    if count then
        table.insert(head, ui.label({ text = tostring(count), color = "on_surface_variant", fontSize = 11 }))
    end
    table.insert(head, ui.spacer({ flexGrow = 1 }))
    if extra then
        table.insert(head, extra)
    end
    return ui.row({ gap = 8, align = "center" }, head)
end

--- 可折叠分区标题行：整行可点；不用 ui.button，后面还要接卡片
local function toggleHead(glyph, text, count, isOpen, toggle, tooltipText, extra)
    local head = {
        ui.glyph({ name = glyph, size = 14, color = "on_surface_variant" }),
        ui.label({ text = text, fontWeight = "semibold" }),
        ui.label({ text = tostring(count), color = "on_surface_variant", fontSize = 11 }),
        ui.spacer({ flexGrow = 1 }),
    }
    table.insert(head, ui.label({
        text = isOpen and tr("panel_collapse", "收起") or tr("panel_show", "展开"),
        color = "on_surface_variant",
        fontSize = 10,
    }))
    if extra ~= nil then
        table.insert(head, extra)
    end
    return ui.row({ gap = 8, align = "center", onClick = toggle, tooltip = tooltipText }, head)
end

-- ── 流量卡 ─────────────────────────────────────────────────────────────────

local function trafficCard()
    local d, u = f.ringNormalize(downRing, upRing)
    local lines = {
        ui.row({ gap = 10, align = "center" }, {
            ui.glyph({ name = "arrow-down", size = 18, color = "primary" }),
            ui.label({ text = f.speed(speeds.down), fontSize = 20, fontWeight = "bold", color = "primary" }),
            ui.spacer({ flexGrow = 1 }),
            ui.glyph({ name = "arrow-up", size = 18, color = "secondary" }),
            ui.label({ text = f.speed(speeds.up), fontSize = 20, fontWeight = "bold", color = "secondary" }),
        }),
        ui.graph({
            values = d,
            values2 = u,
            color = "primary",
            color2 = "secondary",
            lineWidth = 2,
            fillOpacity = 0.22,
            height = 56,
        }),
        ui.row({ gap = 10, align = "center" }, {
            ui.label({
                text = string.format(
                    "%s ↓%s ↑%s",
                    tr("panel_total", "累计"),
                    f.bytes(snap and snap.downloadTotal or 0),
                    f.bytes(snap and snap.uploadTotal or 0)
                ),
                color = "on_surface_variant",
                fontSize = 11,
            }),
            ui.spacer({ flexGrow = 1 }),
            ui.glyph({ name = "plug-connected", size = 12, color = "on_surface_variant" }),
            ui.label({ text = tostring(connCount), fontSize = 11, color = "on_surface" }),
            ui.glyph({ name = "cpu", size = 12, color = "on_surface_variant" }),
            ui.label({
                text = snap ~= nil and snap.memory ~= nil and f.bytes(snap.memory) or "--",
                fontSize = 11,
                color = "on_surface",
            }),
        }),
    }
    return ui.column({ gap = 8, padding = 12, radius = 12, fill = "surface_variant/0.35" }, lines)
end

-- ── 控制卡 ─────────────────────────────────────────────────────────────────

local function modeButton(modeKey, label)
    local active = mode() == modeKey
    return ui.button({
        text = label,
        variant = active and "primary" or "ghost",
        controlSize = "sm",
        selected = active,
        onClick = function()
            if not active then
                patchMode(modeKey)
            end
        end,
    })
end

local function switchRow(glyph, label, checked, onChange, tooltipText)
    return ui.row({ gap = 8, align = "center", tooltip = tooltipText }, {
        ui.glyph({ name = glyph, size = 13, color = checked and "primary" or "on_surface_variant" }),
        ui.label({ text = label, fontSize = 12, flexGrow = 1 }),
        ui.toggle({ checked = checked, onChange = onChange }),
    })
end

local function controlCard()
    local lines = {
        ui.row({ gap = 6, align = "center" }, {
            modeButton("rule", tr("mode_rule", "规则")),
            modeButton("global", tr("mode_global", "全局")),
            modeButton("direct", tr("mode_direct", "直连")),
            ui.spacer({ flexGrow = 1 }),
        }),
        switchRow(
            "shield-lock",
            tr("tun_title", "TUN 模式"),
            tunEnabled(),
            function(value)
                patchTun(value == "true")
            end,
            tr("tun_hint", "接管全局流量（FlClash 的虚拟网卡）")
        ),
        switchRow(
            "broadcast",
            tr("lan_title", "允许局域网"),
            lanEnabled(),
            function(value)
                patchLan(value == "true")
            end,
            tr("lan_hint", "局域网设备可通过本机代理端口上网")
        ),
    }
    return ui.column({ gap = 8, padding = 12, radius = 12, fill = "surface_variant/0.35" }, lines)
end

-- ── 分组卡 ─────────────────────────────────────────────────────────────────

local MAX_NODES = 40

local function nodeRow(group, name, cfg)
    local current = group.now == name
    local delay = nodeDelay(group.name, name, cfg)
    local role = f.delayRole(delay)
    local line = {
        ui.glyph({
            name = current and "circle-check" or "point",
            size = 13,
            color = current and "primary" or "on_surface_variant",
        }),
        ui.label({
            text = name,
            fontSize = 11,
            fontWeight = current and "semibold" or "normal",
            maxLines = 1,
        }),
        ui.spacer({ flexGrow = 1 }),
    }
    if group.now ~= nil and group.fixed == name then
        table.insert(line, ui.glyph({ name = "pin", size = 11, color = "tertiary" }))
    end
    table.insert(line, ui.label({
        text = f.ms(delay),
        fontSize = 11,
        fontWeight = "bold",
        color = role,
    }))
    return ui.row({
        gap = 8,
        align = "center",
        paddingH = 8,
        paddingV = 5,
        radius = 8,
        fill = current and "surface_variant/0.5" or nil,
        onClick = function()
            if group.type == "Selector" or group.fixed ~= nil or group.name == "GLOBAL" then
                selectNode(group.name, name)
            else
                noctalia.notify(
                    tr("readonly_group_title", "自动分组"),
                    tr("readonly_group_body", "该分组由策略自动选择，可在 FlClash 中查看策略")
                )
            end
        end,
        tooltip = string.format(tr("select_hint", "切换到 %s"), name),
    }, line)
end

local function groupCard(group, cfg)
    local isOpen = expanded == group.name
    local delay = nodeDelay(group.name, group.now, cfg)
    local head = {
        ui.glyph({ name = f.groupGlyph(group.type), size = 13, color = "on_surface_variant" }),
        ui.label({ text = group.name, fontWeight = "semibold", fontSize = 12, maxLines = 1 }),
        ui.label({ text = f.groupTypeText(group.type), color = "on_surface_variant", fontSize = 10 }),
        ui.spacer({ flexGrow = 1 }),
    }
    if testing[group.name] then
        table.insert(head, ui.glyph({ name = "loader", size = 12, color = "tertiary" }))
    end
    if group.now ~= nil and group.now ~= "" then
        table.insert(head, ui.label({
            text = group.now,
            fontSize = 11,
            color = "on_surface_variant",
            maxLines = 1,
            maxWidth = 150,
        }))
        table.insert(head, ui.label({
            text = f.ms(delay),
            fontSize = 11,
            fontWeight = "bold",
            color = f.delayRole(delay),
        }))
    end
    table.insert(head, ui.label({
        text = isOpen and tr("panel_collapse", "收起") or tr("panel_show", "展开"),
        color = "on_surface_variant",
        fontSize = 10,
    }))

    local lines = {
        ui.row({ gap = 8, align = "center", onClick = function()
            if isOpen then
                expanded = nil
            else
                expanded = group.name
            end
            draw()
        end }, head),
    }

    if isOpen then
        local nodes = group.all or {}
        local shown = math.min(#nodes, MAX_NODES)
        if not nodesOpen[group.name] then
            shown = math.min(shown, 12)
        end
        if #nodes == 0 then
            table.insert(lines, ui.label({
                text = tr("panel_no_nodes", "该分组没有节点。"),
                color = "on_surface_variant",
                fontSize = 11,
            }))
        else
            for index = 1, shown do
                table.insert(lines, nodeRow(group, nodes[index], cfg))
            end
        end
        -- 按钮排在该容器最后（宿主的渲染顺序要求）
        if #nodes > shown then
            table.insert(lines, ui.button({
                text = nodesOpen[group.name]
                        and tr("panel_collapse", "收起")
                    or string.format(tr("panel_expand_more", "展开其余 %d 个"), #nodes - shown),
                glyph = nodesOpen[group.name] and "chevron-up" or "chevron-down",
                glyphSize = 13,
                variant = "ghost",
                controlSize = "sm",
                onClick = function()
                    nodesOpen[group.name] = not nodesOpen[group.name]
                    draw()
                end,
            }))
        end
        table.insert(lines, ui.button({
            text = testing[group.name] and tr("testing", "测速中…") or tr("test_group", "整组测速"),
            glyph = testing[group.name] and "loader" or "bolt",
            glyphSize = 13,
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
                if not testing[group.name] then
                    testGroup(group.name)
                end
            end,
        }))
    end

    return ui.column({
        gap = 5,
        padding = 9,
        radius = 10,
        fill = "surface_variant/0.3",
    }, lines)
end

local function groupSection(cfg)
    local groups = f.orderedGroups(proxies, cfg.showHidden)
    local lines = {}
    if #groups == 0 then
        table.insert(lines, ui.label({
            text = lastOk == false and tr("panel_groups_unavailable", "分组读取失败，请检查控制器。")
                or tr("panel_no_groups", "没有可见分组。"),
            color = "on_surface_variant",
            fontSize = 11,
        }))
        return lines
    end
    for _, group in ipairs(groups) do
        table.insert(lines, groupCard(group, cfg))
    end
    return lines
end

-- ── 连接区 ─────────────────────────────────────────────────────────────────

local function connRow(row)
    local exit = f.exitNode(row.chains)
    local ruleText = row.rule or ""
    if row.rulePayload ~= nil and row.rulePayload ~= "" then
        ruleText = ruleText .. "(" .. tostring(row.rulePayload) .. ")"
    end
    local meta = {}
    if ruleText ~= "" then
        table.insert(meta, ruleText)
    end
    if exit ~= nil then
        table.insert(meta, string.format("→ %s", exit))
    end
    if row.process ~= nil and row.process ~= "" then
        table.insert(meta, tostring(row.process))
    end

    local hostText = row.host ~= "" and row.host or "?"
    if row.port ~= nil and row.port ~= "" and row.port ~= 0 then
        hostText = hostText .. ":" .. tostring(row.port)
    end

    local lines = {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({
                name = row.network == "udp" and "wifi" or "network",
                size = 12,
                color = "on_surface_variant",
            }),
            ui.label({ text = hostText, fontSize = 11, fontWeight = "semibold", maxLines = 1 }),
            ui.spacer({ flexGrow = 1 }),
            ui.label({
                text = string.format("↓%s ↑%s", f.compact(row.dSpd), f.compact(row.uSpd)),
                fontSize = 10,
                color = (row.dSpd + row.uSpd) > 0 and "primary" or "on_surface_variant",
            }),
            ui.label({
                text = string.format("↓%s ↑%s", f.compact(row.dl), f.compact(row.ul)),
                fontSize = 10,
                color = "on_surface_variant",
            }),
            ui.button({
                glyph = "x",
                glyphSize = 12,
                variant = "ghost",
                controlSize = "sm",
                tooltip = tr("close_conn", "断开连接"),
                onClick = function()
                    closeOne(row.id)
                end,
            }),
        }),
        ui.row({ gap = 8, align = "center" }, {
            ui.label({
                text = table.concat(meta, " · "),
                color = "on_surface_variant",
                fontSize = 10,
                maxLines = 1,
            }),
        }),
    }
    return ui.column({
        gap = 4,
        padding = 9,
        radius = 10,
        fill = "surface_variant/0.3",
        tooltip = string.format("%s · %s", hostText, table.concat(meta, " · ")),
    }, lines)
end

local function connSection(cfg)
    local lines = {}
    local extra = ui.button({
        glyph = "trash",
        glyphSize = 13,
        variant = "ghost",
        controlSize = "sm",
        tooltip = tr("close_all", "断开全部连接"),
        onClick = function()
            closeAll()
        end,
    })
    table.insert(lines, toggleHead(
        "plug-connected",
        tr("panel_conns", "活动连接"),
        connCount,
        connsOpen,
        function()
            connsOpen = not connsOpen
            draw()
        end,
        tr("panel_conns_toggle", "点击展开或收起连接列表"),
        extra
    ))
    if not connsOpen then
        return lines
    end

    if #rows == 0 then
        table.insert(lines, ui.label({
            text = tr("panel_no_conns", "当前没有活动连接。"),
            color = "on_surface_variant",
            fontSize = 11,
        }))
    else
        local shown = math.min(#rows, cfg.maxConns)
        for index = 1, shown do
            table.insert(lines, connRow(rows[index]))
        end
        if #rows > shown then
            table.insert(lines, ui.label({
                text = string.format(tr("panel_more", "还有 %d 条…"), #rows - shown),
                color = "on_surface_variant",
                fontSize = 10,
            }))
        end
    end
    return lines
end

-- ── 离线卡 ─────────────────────────────────────────────────────────────────

local function offlineCard()
    local cfg = f.cfg()
    local lines = {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "alert-triangle", size = 14, color = "error" }),
            ui.label({
                text = cfgSnap == nil and tr("panel_offline", "外部控制器不可达") or tr("panel_partial", "部分接口请求失败"),
                fontWeight = "semibold",
            }),
        }),
        ui.label({
            text = string.format("%s %s", tr("panel_endpoint", "控制器"), cfg.url),
            color = "on_surface_variant",
            fontSize = 11,
        }),
        ui.label({
            text = cfg.secret == "" and tr("panel_no_secret", "未配置密钥：在插件设置里填入 FlClash 的外部控制器密钥。")
                or tr("panel_offline_hint", "确认 FlClash 正在运行，且外部控制器地址与密钥和设置一致。"),
            color = "on_surface_variant",
            fontSize = 10,
        }),
        ui.button({
            text = tr("panel_retry", "重试"),
            glyph = "refresh",
            glyphSize = 13,
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
                refreshAll()
            end,
        }),
    }
    return ui.column({ gap = 6, padding = 10, radius = 10, fill = "surface_variant/0.45" }, lines)
end

-- ── 主体 ───────────────────────────────────────────────────────────────────

local function body(cfg)
    local nodes = {}

    if lastOk == false and snap == nil then
        table.insert(nodes, offlineCard())
        return nodes
    end
    if snap == nil then
        table.insert(nodes, ui.label({
            text = tr("panel_loading", "正在连接外部控制器…"),
            color = "on_surface_variant",
        }))
        return nodes
    end

    table.insert(nodes, trafficCard())
    table.insert(nodes, controlCard())

    table.insert(nodes, ui.spacer({ height = 4 }))
    local groups = groupSection(cfg)
    table.insert(nodes, sectionHead("route", tr("panel_groups", "代理分组"), #groups))
    for _, node in ipairs(groups) do
        table.insert(nodes, node)
    end

    table.insert(nodes, ui.spacer({ height = 4 }))
    for _, node in ipairs(connSection(cfg)) do
        table.insert(nodes, node)
    end

    table.insert(nodes, ui.spacer({ height = 4 }))
    table.insert(nodes, ui.row({ gap = 8, align = "center" }, {
        ui.label({
            text = version ~= nil and version.version ~= nil and ("mihomo " .. tostring(version.version)) or "",
            color = "on_surface_variant",
            fontSize = 10,
        }),
        ui.spacer({ flexGrow = 1 }),
        ui.button({
            text = tr("flush_fakeip", "清除 fake-ip"),
            glyph = "trash",
            glyphSize = 13,
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
                flushFakeip()
            end,
        }),
    }))
    return nodes
end

-- ── 渲染 ───────────────────────────────────────────────────────────────────

draw = function()
    local role = lastOk == false and "error" or "primary"

    local head = {
        ui.glyph({ name = "world", size = 15, color = role }),
        ui.label({ text = "FlClash", fontWeight = "bold", fontSize = 15 }),
        ui.label({
            text = f.modeText(mode()),
            color = role,
            fontSize = 11,
        }),
        ui.spacer({ flexGrow = 1 }),
        ui.label({
            text = lastAt > 0
                    and string.format(tr("panel_updated", "更新于 %s"), os.date("%H:%M:%S", lastAt))
                or string.format("%s --:--:--", tr("panel_updated_short", "更新于")),
            color = "on_surface_variant",
            fontSize = 11,
        }),
        ui.button({
            glyph = inflightConns and "loader" or "refresh",
            glyphSize = 14,
            variant = "ghost",
            controlSize = "sm",
            tooltip = tr("panel_refresh", "重新读取"),
            onClick = function()
                refreshAll()
            end,
        }),
    }

    local content = body(f.cfg())
    table.insert(content, 1, ui.row({ gap = 8, align = "center" }, head))

    panel.render(ui.scroll({ flexGrow = 1, gap = 10, paddingH = 14, paddingV = 12 }, content))
end

-- ── 生命周期 ───────────────────────────────────────────────────────────────

function onOpen(_context)
    open = true
    noctalia.setUpdateInterval(1000)
    startStream()
    refreshAll()
    fetchVersion()
    dirty = true
    draw() -- 首次渲染：数据未到时只是 loading，开销很小
end

function onClose()
    open = false
    stopStream()
end

function update()
    if not open then
        return
    end
    local cfg = f.cfg()
    startStream()
    local now = os.time()
    if not inflightConns and now - lastConnsAt >= cfg.refresh then
        lastConnsAt = now
        requestConns()
    end
    if not inflightCfg and now - lastCfgAt >= cfg.refresh then
        lastCfgAt = now
        requestCfg()
    end
    if not inflightProxies and now - lastProxiesAt >= 10 then
        lastProxiesAt = now
        requestProxies()
    end
    -- 重活（大快照差分 + 整棵树）放在 tick 里，且一秒最多一次
    if dirty then
        dirty = false
        if snap ~= nil and connNowMs > 0 then
            rows, prevConn = f.connRows(snap, prevConn, connNowMs, cfg.maxConns + 8)
        end
        draw()
    end
end

function onIpc(event, _payload)
    if event == "refresh" then
        refreshAll()
        fetchVersion()
    end
end

draw()
