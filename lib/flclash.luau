--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- lib/flclash.luau —— mihomo 外部控制器 API 客户端、解析、派生指标与格式化
--
-- 数据通道（全部走 noctalia.http / noctalia.httpStream，本地控制器）：
--   GET  /traffic            chunked JSON 流，每行 {"up":n,"down":n,...}
--   GET  /connections        快照：累计总量、内存、活跃连接（含每连接字节）
--   GET  /configs            当前配置（mode / tun / allow-lan / 端口…）
--   GET  /proxies            全部分组与节点（now / all / history / hidden）
--   PUT  /proxies/{组}       {"name":"节点"} 切换选择
--   GET  /group/{组}/delay   整组测速 → {"节点":ms}
--   GET  /proxies/{名}/delay 单节点测速 → {"delay":ms}
--   PATCH /configs           {"mode":...} / {"tun":{"enable":...}} 等
--   DELETE /connections/{id} 断开一条连接；DELETE /connections 全部断开
--   POST /cache/fakeip/flush 清除 fake-ip 缓存
--
-- bar.luau（栏组件）与 panel.luau（面板）共用这一份逻辑：
--   * 设置读取：noctalia.getConfig 只收一个参数、没有默认值，统一在这里兜底
--   * 分组排序：mihomo /proxies 返回的是 map，顺序取自 GLOBAL.all
--   * 连接差分：两次快照逐 id 差分得到每连接的瞬时速率
--   * 格式化：字节、速率、延迟、模式名、类型图标
-- ══════════════════════════════════════════════════════════════════════════

local M = {}

M.VERSION = "1.0.0"

-- 单个 HTTP 请求的超时（宿主会把 timeoutMs 夹到 [50, 60000]）
M.HTTP_TIMEOUT_MS = 5000

-- ── 设置读取 ───────────────────────────────────────────────────────────────

local function raw(key)
    local ok, value = pcall(noctalia.getConfig, key)
    if not ok then
        return nil
    end
    return value
end

--- 字符串设置；空串按「未设置」处理，回落到 default
function M.text(key, default)
    local value = raw(key)
    if type(value) ~= "string" or value == "" then
        return default
    end
    return value
end

--- 布尔设置；兼容字符串/数字形式
function M.flag(key, default)
    local value = raw(key)
    if type(value) == "boolean" then
        return value
    end
    if type(value) == "number" then
        return value ~= 0
    end
    if type(value) == "string" then
        if value == "true" or value == "1" then
            return true
        end
        if value == "false" or value == "0" then
            return false
        end
    end
    return default
end

--- 数字设置；兼容字符串形式的数字
function M.number(key, default)
    local value = raw(key)
    if type(value) == "number" then
        return value
    end
    local parsed = tonumber(value)
    if parsed ~= nil then
        return parsed
    end
    return default
end

function M.clamp(value, low, high)
    if value < low then
        return low
    end
    if value > high then
        return high
    end
    return value
end

--- 翻译；键缺失时回落到中文兜底
function M.tr(key, fallback)
    local ok, value = pcall(noctalia.tr, key)
    if ok and type(value) == "string" and value ~= "" and value ~= key then
        return value
    end
    return fallback or key
end

--- 当前设置（每轮重读，改设置后不用重载插件；plugin.toml 的 default 只兜首次）
function M.cfg()
    return {
        url = M.text("controller_url", "http://127.0.0.1:9090"),
        secret = M.text("controller_secret", ""),
        refresh = M.clamp(M.number("refresh_seconds", 3), 1, 30),
        history = M.clamp(M.number("history_seconds", 60), 15, 300),
        testUrl = M.text("test_url", "http://www.gstatic.com/generate_204"),
        testTimeout = M.clamp(M.number("test_timeout_ms", 5000), 1000, 15000),
        maxConns = M.clamp(M.number("max_conns", 24), 4, 200),
        showHidden = M.flag("show_hidden", false),
    }
end

--- 控制器基础地址：去掉结尾的 /，裸 host:port 自动补 http://
function M.base(cfg)
    local url = (cfg.url or ""):gsub("/+$", "")
    if url:match("^https?://") then
        return url
    end
    return "http://" .. url
end

--- /traffic 流的完整地址（httpStream 用）
function M.trafficUrl(cfg)
    return M.base(cfg) .. "/traffic"
end

-- ── HTTP 封装 ──────────────────────────────────────────────────────────────

--- 统一请求。cb(ok, status, data, errMsg)
---   ok = 传输成功且 2xx；data = JSON 解析结果（2xx 但空 body 时为 nil）
function M.request(method, path, body, cb)
    local cfg = M.cfg()
    local headers = { "Accept: application/json", "Content-Type: application/json" }
    if cfg.secret ~= "" then
        table.insert(headers, "Authorization: Bearer " .. cfg.secret)
    end
    local ok = noctalia.http({
        url = M.base(cfg) .. path,
        method = method,
        headers = headers,
        body = (body ~= nil) and body or nil,
    }, function(response)
        if response == nil or not response.ok or response.status < 200 or response.status >= 300 then
            local reason = "transport"
            if response ~= nil and response.ok then
                reason = "HTTP " .. tostring(response.status)
                if response.status == 401 or response.status == 403 then
                    reason = "auth"
                end
            end
            cb(false, response ~= nil and response.status or 0, nil, reason)
            return
        end
        local text = response.body or ""
        if text == "" then
            cb(true, response.status, nil, nil)
            return
        end
        local data, err = noctalia.json.decode(text)
        if data == nil then
            cb(false, response.status, nil, err or "json")
            return
        end
        cb(true, response.status, data, nil)
    end)
    if not ok then
        cb(false, 0, nil, "start")
    end
end

local function encodeBody(tbl)
    local text = noctalia.json.encode(tbl, false)
    if text == nil then
        return nil
    end
    return text
end

--- 订阅 /traffic 的 chunked JSON 流。
---   onLine(sample) 每行一个 { up, down, upTotal, downTotal }（每秒一条）
---   onClose(ok, status) 断开时回调一次
--- 返回 handle：stop() 可取消（幂等，且不会再触发 onClose）；宿主重载脚本时自动取消。
--- 流不可用时会立刻 onClose，调用方应回落到 /connections 的累计量差分。
function M.startTraffic(onLine, onClose)
    local cfg = M.cfg()
    local headers = { "Accept: application/json" }
    if cfg.secret ~= "" then
        table.insert(headers, "Authorization: Bearer " .. cfg.secret)
    end
    return noctalia.httpStream({
        url = M.trafficUrl(cfg),
        method = "GET",
        headers = headers,
    }, function(line)
        local data = noctalia.json.decode(line)
        if type(data) == "table" then
            onLine(data)
        end
    end, function(result)
        onClose(result ~= nil and result.ok, result ~= nil and result.status or 0)
    end)
end

function M.connections(cb)
    M.request("GET", "/connections", nil, cb)
end

function M.proxies(cb)
    M.request("GET", "/proxies", nil, cb)
end

function M.configs(cb)
    M.request("GET", "/configs", nil, cb)
end

function M.version(cb)
    M.request("GET", "/version", nil, cb)
end

function M.rules(cb)
    M.request("GET", "/rules", nil, cb)
end

--- PATCH /configs：fields 如 { mode = "global" } 或 { tun = { enable = true } }
function M.patchConfigs(fields, cb)
    local body = encodeBody(fields)
    if body == nil then
        cb(false, 0, nil, "encode")
        return
    end
    M.request("PATCH", "/configs", body, cb)
end

--- 切换分组节点；组名与节点名都做 URL 编码（中文/空格）
function M.selectProxy(group, name, cb)
    local path = "/proxies/" .. noctalia.string.urlEncode(group)
    M.request("PUT", path, encodeBody({ name = name }), cb)
end

--- 整组测速：返回 map（节点名 → 毫秒，失败的节点为 0）
function M.groupDelay(group, cfg, cb)
    local path = "/group/"
        .. noctalia.string.urlEncode(group)
        .. "/delay?url="
        .. noctalia.string.urlEncode(cfg.testUrl)
        .. "&timeout="
        .. tostring(cfg.testTimeout)
    M.request("GET", path, nil, cb)
end

--- 单节点测速：返回 { delay = 毫秒 } 或错误
function M.nodeDelay(name, cfg, cb)
    local path = "/proxies/"
        .. noctalia.string.urlEncode(name)
        .. "/delay?url="
        .. noctalia.string.urlEncode(cfg.testUrl)
        .. "&timeout="
        .. tostring(cfg.testTimeout)
    M.request("GET", path, nil, cb)
end

function M.closeConn(id, cb)
    M.request("DELETE", "/connections/" .. noctalia.string.urlEncode(id), nil, cb)
end

function M.closeAllConns(cb)
    M.request("DELETE", "/connections", nil, cb)
end

function M.flushFakeip(cb)
    M.request("POST", "/cache/fakeip/flush", nil, cb)
end

-- ── 单位与文案 ─────────────────────────────────────────────────────────────

local BYTE_UNITS = { "B", "KB", "MB", "GB", "TB", "PB" }

function M.bytes(n)
    local value = tonumber(n) or 0
    if value < 0 then
        value = 0
    end
    local unit = 1
    while value >= 1024 and unit < #BYTE_UNITS do
        value = value / 1024
        unit += 1
    end
    if unit == 1 then
        return string.format("%d B", value)
    end
    if value >= 100 then
        return string.format("%.0f %s", value, BYTE_UNITS[unit])
    end
    return string.format("%.1f %s", value, BYTE_UNITS[unit])
end

function M.speed(n)
    return M.bytes(tonumber(n) or 0) .. "/s"
end

--- 延迟展示：nil → "--"，0 → 超时
function M.ms(delay)
    if delay == nil then
        return "--"
    end
    if delay <= 0 then
        return M.tr("delay_timeout", "超时")
    end
    return string.format("%dms", delay)
end

--- 延迟分级配色：颜色只给状态
function M.delayRole(delay)
    if delay == nil then
        return "on_surface_variant"
    end
    if delay <= 0 then
        return "error"
    end
    if delay < 200 then
        return "primary"
    end
    if delay < 500 then
        return "tertiary"
    end
    return "error"
end

local MODE_KEYS = { rule = "mode_rule", global = "mode_global", direct = "mode_direct" }
local MODE_FALLBACK = { rule = "规则", global = "全局", direct = "直连" }

function M.modeText(mode)
    local key = MODE_KEYS[mode]
    if key == nil then
        return tostring(mode)
    end
    return M.tr(key, MODE_FALLBACK[mode] or tostring(mode))
end

local GROUP_GLYPHS = {
    Selector = "switch-horizontal",
    URLTest = "activity",
    Fallback = "arrows-split-2",
    LoadBalance = "topology-star-3",
    Relay = "hierarchy",
}

function M.groupGlyph(gtype)
    return GROUP_GLYPHS[gtype] or "cloud"
end

--- 分组类型的简短文案；未知类型原样返回
local GROUP_TYPE_KEYS = {
    Selector = "type_selector",
    URLTest = "type_urltest",
    Fallback = "type_fallback",
    LoadBalance = "type_loadbalance",
    Relay = "type_relay",
}
local GROUP_TYPE_FALLBACK = {
    Selector = "选择器",
    URLTest = "自动测速",
    Fallback = "回退",
    LoadBalance = "负载均衡",
    Relay = "链式",
}

function M.groupTypeText(gtype)
    local key = GROUP_TYPE_KEYS[gtype]
    if key == nil then
        return tostring(gtype)
    end
    return M.tr(key, GROUP_TYPE_FALLBACK[gtype] or tostring(gtype))
end

--- 连接的入口类型（Tun / Mixed / Socks …）
function M.inboundText(connType)
    if connType == nil or connType == "" then
        return ""
    end
    return tostring(connType)
end

-- ── 分组排序与延迟 ─────────────────────────────────────────────────────────

--- 从 /proxies 的 map 里按 GLOBAL.all 顺序取出分组；
--- GLOBAL 自身放最后（全局模式下它才是选择器）。hidden 分组默认隐藏。
function M.orderedGroups(proxies, showHidden)
    local groups = {}
    if type(proxies) ~= "table" then
        return groups
    end
    local global = proxies["GLOBAL"]
    local order = {}
    local seen = {}
    if type(global) == "table" and type(global.all) == "table" then
        for _, name in ipairs(global.all) do
            if not seen[name] then
                seen[name] = true
                table.insert(order, name)
            end
        end
    end
    -- 兜底：GLOBAL.all 拿不到时按 map 键序（稳定但不保证配置顺序）
    if #order == 0 then
        for name in pairs(proxies) do
            table.insert(order, name)
        end
    end
    local normal, globalGroup = {}, nil
    for _, name in ipairs(order) do
        if name ~= "GLOBAL" then
            local p = proxies[name]
            if type(p) == "table" and type(p.all) == "table" and #p.all > 0 then
                table.insert(normal, {
                    name = name,
                    type = tostring(p.type or ""),
                    now = p.now,
                    all = p.all,
                    fixed = p.fixed,
                    hidden = p.hidden == true,
                    udp = p.udp == true,
                })
            end
        end
    end
    -- GLOBAL 自身不在 GLOBAL.all 里，从 map 直接取；全局模式下它是选择器
    do
        local g = proxies["GLOBAL"]
        if type(g) == "table" and type(g.all) == "table" and #g.all > 0 then
            globalGroup = {
                name = "GLOBAL",
                type = tostring(g.type or ""),
                now = g.now,
                all = g.all,
                fixed = g.fixed,
                hidden = g.hidden == true,
                udp = g.udp == true,
            }
        end
    end
    for _, entry in ipairs(normal) do
        if showHidden or not entry.hidden then
            table.insert(groups, entry)
        end
    end
    if globalGroup ~= nil and (showHidden or not globalGroup.hidden) then
        table.insert(groups, globalGroup)
    end
    return groups
end

--- 节点最新延迟：优先 extra[testUrl]（分 URL 的历史），否则 history 末条
function M.delayOf(proxy, testUrl)
    if type(proxy) ~= "table" then
        return nil
    end
    if type(proxy.extra) == "table" and testUrl ~= nil then
        local per = proxy.extra[testUrl]
        if type(per) == "table" and type(per.history) == "table" and #per.history > 0 then
            local last = per.history[#per.history]
            if type(last) == "table" and last.delay ~= nil then
                return tonumber(last.delay)
            end
        end
    end
    if type(proxy.history) == "table" and #proxy.history > 0 then
        local last = proxy.history[#proxy.history]
        if type(last) == "table" and last.delay ~= nil then
            return tonumber(last.delay)
        end
    end
    return nil
end

-- ── 连接差分 ───────────────────────────────────────────────────────────────

--- 两次 /connections 快照逐 id 差分，得到每连接瞬时速率。
--- 返回 rows（已按速率与累计排序）与下一轮的 prev 状态。
function M.connRows(snap, prev, nowMs, maxRows)
    local conns = (type(snap) == "table" and snap.connections) or {}
    local dtMs = nowMs - (prev.at or nowMs)
    local dt = dtMs > 0 and dtMs / 1000 or 0
    local rows, seen = {}, {}
    for _, conn in ipairs(conns) do
        local meta = conn.metadata or {}
        local p = prev.map and prev.map[conn.id]
        local dSpd, uSpd = 0, 0
        if p ~= nil and dt > 0 then
            dSpd = math.max(0, ((conn.download or 0) - p.d) / dt)
            uSpd = math.max(0, ((conn.upload or 0) - p.u) / dt)
        end
        local host = meta.host
        if host == nil or host == "" then
            host = meta.destinationIP or ""
        end
        table.insert(rows, {
            id = conn.id,
            host = host,
            port = meta.destinationPort,
            network = meta.network,
            inbound = meta.type,
            rule = conn.rule,
            rulePayload = conn.rulePayload,
            chains = conn.chains or {},
            dl = conn.download or 0,
            ul = conn.upload or 0,
            dSpd = dSpd,
            uSpd = uSpd,
            start = conn.start or "",
            process = meta.process or "",
        })
        seen[conn.id] = { d = conn.download or 0, u = conn.upload or 0 }
    end
    table.sort(rows, function(a, b)
        local at = a.dSpd + a.uSpd
        local bt = b.dSpd + b.uSpd
        if at ~= bt then
            return at > bt
        end
        if a.dl ~= b.dl then
            return a.dl > b.dl
        end
        return a.start > b.start
    end)
    -- 只保留要展示的前 N 行；seen（下一轮基线）仍覆盖全部连接
    if maxRows ~= nil and #rows > maxRows then
        for i = #rows, maxRows + 1, -1 do
            rows[i] = nil
        end
    end
    return rows, { at = nowMs, map = seen }
end

--- 连接的出口节点：chains[1] 是实际出口，末位是入口分组
function M.exitNode(chains)
    if type(chains) == "table" and chains[1] ~= nil and chains[1] ~= "" then
        return tostring(chains[1])
    end
    return nil
end

-- ── 紧凑单位与环形缓冲 ─────────────────────────────────────────────────────

--- 紧凑字节/速率后缀：1258291 → "1.2M"（栏组件用，不带单位符号）
function M.compact(n)
    local value = math.max(0, tonumber(n) or 0)
    if value < 1024 then
        return string.format("%dB", value)
    end
    local units = { "K", "M", "G", "T", "P" }
    local u = 1
    value = value / 1024
    while value >= 1024 and u < #units do
        value = value / 1024
        u += 1
    end
    if value >= 100 then
        return string.format("%.0f%s", value, units[u])
    end
    return string.format("%.1f%s", value, units[u])
end

--- 往 ring（数组）尾部压入样本，超过 maxLen 丢最旧；原地修改
function M.ringPush(ring, value, maxLen)
    table.insert(ring, value)
    while #ring > maxLen do
        table.remove(ring, 1)
    end
end

--- 把两组样本归一化成 0..1 的曲线数据（共享纵轴，最小满刻度 1 KB/s）
function M.ringNormalize(down, up)
    local peak = 1024
    for _, v in ipairs(down) do
        if v > peak then
            peak = v
        end
    end
    for _, v in ipairs(up) do
        if v > peak then
            peak = v
        end
    end
    local d, u = {}, {}
    for _, v in ipairs(down) do
        table.insert(d, v / peak)
    end
    for _, v in ipairs(up) do
        table.insert(u, v / peak)
    end
    return d, u, peak
end

return M
