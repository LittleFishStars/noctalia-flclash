--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- bar.luau —— 状态栏上的 FlClash / mihomo 实时流量
--
-- 默认显示 ↓/↑ 实时速率，可切换成仅下行、仅上行、累计流量、连接数或模式。
-- 图标与文字按状态分级变色：控制器可达 → 主题色；失联/鉴权失败 → error。
--
-- 速率来源：
--   首选 /traffic 的 chunked JSON 流（httpStream，每秒一条，瞬时值）；
--   流不可用时回落到 /connections 累计量的相邻差分。
--
-- 交互（可在设置里的组件手势中改绑）：
--   左键：打开控制面板（plugin.toml 的 [widget.actions] 默认绑定）
--   右键：重连流量流并立刻刷新一轮
--
-- 数据来自 mihomo 外部控制器（见 lib/flclash.luau），只读、不落盘。
-- ══════════════════════════════════════════════════════════════════════════

local f = require("./lib/flclash.luau")

-- ── 运行状态 ───────────────────────────────────────────────────────────────

local conn = nil -- /connections 快照
local cfgSnap = nil -- /configs 快照（mode / tun / allow-lan）
local proxies = nil -- /proxies map
local version = nil -- /version

local inflight = false
local lastPollAt = 0
local lastOk = nil -- 最近一轮轮询是否有任一接口失败；nil = 还没轮询过

local stream = nil -- /traffic 流句柄
local streamBroken = false -- 流失败后改用差分，右键才重试
local streamSpeed = { down = 0, up = 0 }
local diffSpeed = { down = 0, up = 0 }
local prevTotals = nil -- 差分基线 { at, dl, ul }
local dirty = false -- 数据到了但还没重绘；http 回调只标脏

-- ── 设置 ───────────────────────────────────────────────────────────────────

local function settings()
    return {
        display = f.text("display", "speed"),
        glyph = f.text("glyph", "world"),
        showGlyph = f.flag("show_glyph", true),
        hideWhenOff = f.flag("hide_when_off", false),
    }
end

-- ── 抓取 ───────────────────────────────────────────────────────────────────

local render -- 前向声明；流回调与轮询回调都要用

--- /connections 累计量差分，仅在 /traffic 流不可用时作为兜底
local function applyDiff(snap, nowMs)
    local dl = snap.downloadTotal or 0
    local ul = snap.uploadTotal or 0
    if prevTotals ~= nil then
        local dt = (nowMs - prevTotals.at) / 1000
        if dt > 0.2 then
            diffSpeed.down = math.max(0, (dl - prevTotals.dl) / dt)
            diffSpeed.up = math.max(0, (ul - prevTotals.ul) / dt)
        end
    end
    prevTotals = { at = nowMs, dl = dl, ul = ul }
end

local function markFail()
    lastOk = false
    prevTotals = nil
    streamSpeed.down = 0
    streamSpeed.up = 0
    diffSpeed.down = 0
    diffSpeed.up = 0
end

--- 当前生效的速率：流活着就用流，否则用差分
local function speeds()
    if stream ~= nil then
        return streamSpeed.down, streamSpeed.up
    end
    return diffSpeed.down, diffSpeed.up
end

local function request()
    if inflight then
        return
    end
    inflight = true
    local pending = 4
    local nowMs = noctalia.nowMs()
    local allOk = true
    local function settle(ok)
        if not ok then
            allOk = false
        end
        pending -= 1
        if pending == 0 then
            inflight = false
            lastPollAt = nowMs
            if allOk then
                lastOk = true
            else
                markFail()
            end
            render() -- 一轮结束统一重绘（此时四个回调都已返回）
        end
    end
    f.connections(function(ok, _status, data)
        if ok and type(data) == "table" then
            conn = data
            applyDiff(data, noctalia.nowMs())
        end
        dirty = true
        settle(ok)
    end)
    f.configs(function(ok, _status, data)
        if ok and type(data) == "table" then
            cfgSnap = data
        end
        dirty = true
        settle(ok)
    end)
    f.proxies(function(ok, _status, data)
        if ok and type(data) == "table" then
            proxies = data.proxies
        end
        dirty = true
        settle(ok)
    end)
    if version == nil then
        f.version(function(ok, _status, data)
            if ok and type(data) == "table" then
                version = data
            end
            settle(ok)
        end)
    else
        settle(true)
    end
end

-- ── /traffic 流 ────────────────────────────────────────────────────────────

local function startStream()
    if stream ~= nil or streamBroken then
        return
    end
    local alive = true
    stream = f.startTraffic(function(sample)
        if not alive then
            return
        end
        streamSpeed.down = sample.down or 0
        streamSpeed.up = sample.up or 0
        dirty = true -- 由 update() 统一重绘，回调里不构建渲染树
    end, function()
        alive = false
        -- 流断开：回落到差分；右键可重试
        stream = nil
        streamBroken = true
        prevTotals = nil
    end)
    -- httpStream 立刻启动失败时返回 nil，标记成回落
    if stream == nil then
        streamBroken = true
    end
end

-- ── 派生 ───────────────────────────────────────────────────────────────────

--- 当前模式（/configs 没到手前按 mihomo 默认 rule）
local function mode()
    if cfgSnap ~= nil and cfgSnap.mode ~= nil then
        return tostring(cfgSnap.mode)
    end
    return "rule"
end

--- 主出口：全局模式取 GLOBAL 的 now，规则模式取第一个可见选择器组的 now
local function mainExit()
    if proxies == nil then
        return nil
    end
    if mode() == "global" then
        local g = proxies["GLOBAL"]
        if g ~= nil then
            return g.now
        end
        return nil
    end
    local groups = f.orderedGroups(proxies, false)
    for _, group in ipairs(groups) do
        if group.type == "Selector" and group.name ~= "GLOBAL" then
            return group.now
        end
    end
    return nil
end

local function level()
    if lastOk == false then
        return "off"
    end
    return "ok"
end

-- ── 文案 ───────────────────────────────────────────────────────────────────

local function barText(w)
    local levelNow = level()
    if levelNow == "off" then
        return f.tr("bar_off", "未连接")
    end
    local down, up = speeds()
    if w.display == "speed" then
        return string.format("↓%s ↑%s", f.compact(down), f.compact(up))
    end
    if w.display == "down" then
        return "↓" .. f.compact(down)
    end
    if w.display == "up" then
        return "↑" .. f.compact(up)
    end
    if w.display == "total" then
        local dl = conn and conn.downloadTotal or 0
        local ul = conn and conn.uploadTotal or 0
        return string.format("↓%s ↑%s", f.compact(dl), f.compact(ul))
    end
    if w.display == "conns" then
        local n = conn and conn.connections and #conn.connections or 0
        return tostring(n)
    end
    if w.display == "mode" then
        return f.modeText(mode())
    end
    return string.format("↓%s ↑%s", f.compact(down), f.compact(up))
end

local function tooltipRows()
    local rows = {}
    local levelNow = level()
    table.insert(rows, {
        key = f.tr("tt_status", "状态"),
        value = levelNow == "off" and f.tr("level_off", "未连接") or f.tr("level_ok", "运行中"),
    })
    if version ~= nil and version.version ~= nil then
        table.insert(rows, { key = "mihomo", value = tostring(version.version) })
    end
    if levelNow ~= "off" then
        local dSpeed, uSpeed = speeds()
        table.insert(rows, {
            key = f.tr("tt_speed", "速率"),
            value = string.format("↓%s ↑%s", f.speed(dSpeed), f.speed(uSpeed)),
        })
        if conn ~= nil then
            table.insert(rows, {
                key = f.tr("tt_total", "累计"),
                value = string.format(
                    "↓%s ↑%s",
                    f.bytes(conn.downloadTotal or 0),
                    f.bytes(conn.uploadTotal or 0)
                ),
            })
            local conns = conn.connections or {}
            table.insert(rows, { key = f.tr("tt_conns", "连接"), value = tostring(#conns) })
            if conn.memory ~= nil then
                table.insert(rows, { key = f.tr("tt_memory", "内存"), value = f.bytes(conn.memory) })
            end
        end
        local exitNode = mainExit()
        if exitNode ~= nil then
            table.insert(rows, { key = f.tr("tt_exit", "主出口"), value = tostring(exitNode) })
        end
        table.insert(rows, {
            key = f.tr("tt_mode", "模式"),
            value = string.format(
                "%s · TUN %s",
                f.modeText(mode()),
                (cfgSnap and cfgSnap.tun and cfgSnap.tun.enable) and "✓" or "✗"
            ),
        })
    end
    table.insert(rows, {
        key = f.tr("tt_hint_key", "提示"),
        value = f.tr("tt_hint", "左键：控制面板 · 右键：重连流量流"),
    })
    return rows
end

-- ── 渲染 ───────────────────────────────────────────────────────────────────

render = function()
    local w = settings()
    local levelNow = level()

    if w.hideWhenOff and levelNow == "off" then
        barWidget.setVisible(false)
        return
    end
    barWidget.setVisible(true)

    if w.showGlyph then
        barWidget.setGlyph(levelNow == "off" and "world-off" or w.glyph)
        barWidget.setGlyphColor(levelNow == "off" and "error" or "on_surface")
    else
        barWidget.setGlyph("")
    end

    barWidget.setText(barText(w))
    -- 正常时回落到组件自己的文字颜色，失联时才接管成 error
    if levelNow == "off" then
        barWidget.setColor("error")
    else
        barWidget.setColor("on_surface")
    end

    barWidget.setTooltip(tooltipRows())
end

-- ── 指针回调 ───────────────────────────────────────────────────────────────

--- 左键：清单里默认绑成了 panel-toggle；用户改成 none 时这里兜底
function onClick()
    noctalia.togglePanel("ylxc/flclash:panel")
end

--- 右键：重连流量流并立刻刷新一轮（忽略刷新间隔）
function onRightClick()
    streamBroken = false
    prevTotals = nil
    startStream()
    request()
    noctalia.log("[flclash] 手动刷新")
end

function onIpc(event, _payload)
    if event == "refresh" then
        streamBroken = false
        startStream()
        request()
    elseif event == "panel" then
        noctalia.togglePanel("ylxc/flclash:panel")
    end
end

-- ── 生命周期 ───────────────────────────────────────────────────────────────

function update()
    local cfg = f.cfg()
    noctalia.setUpdateInterval(cfg.refresh * 1000)
    startStream()
    if not inflight and os.time() - lastPollAt >= cfg.refresh then
        request()
    elseif dirty then
        dirty = false
        render()
    end
end

render()
update()
