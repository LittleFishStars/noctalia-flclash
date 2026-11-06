--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- tests/env.luau —— 测试用的假宿主与断言辅助
--
-- 由 tests/run.sh 把它、被测源码、tests/*.luau 断言拼成同一个文件后交给
-- luau 执行。原因：luau CLI 的 require 会把模块放进隔离的全局环境（模块
-- 里看不到这里定义的假宿主），CLI 也没有 io 库，所以只能「拼接 + 同一环境」。
--
-- 假宿主实现：
--   noctalia.http       —— 按 URL 前缀分发 canned 快照（同步回调），
--                          并把 method/path/body 记进 requests 供断言
--   noctalia.httpStream —— 返回 nil（模拟流不可用，逼出 /connections 差分兜底）
--   noctalia.json       —— 自带的 mini JSON 编解码（luau CLI 没有内置 json）
--   ui.* / panel / barWidget —— 记录渲染树与文本
-- ══════════════════════════════════════════════════════════════════════════

-- ── mini JSON ──────────────────────────────────────────────────────────────

-- JSON null 用哨兵表示，避免 table 里丢键（真实 mihomo 响应含 null）
local JSON_NULL = setmetatable({}, { __tostring = function()
    return "null"
end })

local function jsonDecode(text)
    local pos = 1
    local function skip()
        while pos <= #text and text:sub(pos, pos):match("%s") do
            pos += 1
        end
    end
    local parseValue -- 前向声明
    local function parseString()
        pos += 1 -- 跳过开头的 "
        local out = {}
        while pos <= #text do
            local ch = text:sub(pos, pos)
            if ch == '"' then
                pos += 1
                return table.concat(out)
            end
            if ch == "\\" then
                pos += 1
                local esc = text:sub(pos, pos)
                local map = { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\" }
                table.insert(out, map[esc] or esc)
                pos += 1
            else
                table.insert(out, ch)
                pos += 1
            end
        end
        error("json: 未闭合字符串")
    end
    local function parseNumber()
        local head = text:match("^%-?%d+%.?%d*[eE]?%+?-?%d*", pos)
        pos += #head
        return tonumber(head)
    end
    parseValue = function()
        skip()
        local ch = text:sub(pos, pos)
        if ch == "{" then
            pos += 1
            local obj = {}
            skip()
            if text:sub(pos, pos) == "}" then
                pos += 1
                return obj
            end
            while true do
                skip()
                local key = parseString()
                skip()
                assert(text:sub(pos, pos) == ":", "json: 缺少冒号")
                pos += 1
                obj[key] = parseValue()
                skip()
                local sep = text:sub(pos, pos)
                pos += 1
                if sep == "}" then
                    return obj
                end
                assert(sep == ",", "json: 缺少逗号")
            end
        end
        if ch == "[" then
            pos += 1
            local arr = {}
            skip()
            if text:sub(pos, pos) == "]" then
                pos += 1
                return arr
            end
            while true do
                table.insert(arr, parseValue())
                skip()
                local sep = text:sub(pos, pos)
                pos += 1
                if sep == "]" then
                    return arr
                end
                assert(sep == ",", "json: 缺少逗号")
            end
        end
        if ch == '"' then
            return parseString()
        end
        if text:sub(pos, pos + 3) == "true" then
            pos += 4
            return true
        end
        if text:sub(pos, pos + 4) == "false" then
            pos += 5
            return false
        end
        if text:sub(pos, pos + 3) == "null" then
            pos += 4
            return JSON_NULL
        end
        return parseNumber()
    end
    local value = parseValue()
    return value
end

local function jsonEncode(value)
    if value == nil then
        return "null"
    end
    if type(value) == "boolean" then
        return value and "true" or "false"
    end
    if type(value) == "number" then
        return string.format("%.14g", value)
    end
    if type(value) == "string" then
        return '"' .. value:gsub('[\\"]', function(c)
            return "\\" .. c
        end) .. '"'
    end
    if type(value) == "table" then
        local isArr = value[1] ~= nil
        local parts = {}
        if isArr then
            for _, v in ipairs(value) do
                table.insert(parts, jsonEncode(v))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        for k, v in pairs(value) do
            table.insert(parts, jsonEncode(k) .. ":" .. jsonEncode(v))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    error("jsonEncode: 不支持的类型 " .. type(value))
end

-- ── canned 数据 ────────────────────────────────────────────────────────────

local CANNED_PROXIES = jsonEncode({
    proxies = {
        GLOBAL = {
            all = { "主代理", "自动选择", "隐藏组", "DIRECT", "香港01", "日本01" },
            now = "香港01",
            type = "Selector",
            hidden = false,
        },
        ["主代理"] = {
            all = { "自动选择", "DIRECT", "香港01", "日本01" },
            now = "香港01",
            type = "Selector",
            hidden = false,
        },
        ["自动选择"] = {
            all = { "香港01", "日本01" },
            now = "香港01",
            type = "URLTest",
            hidden = false,
        },
        ["隐藏组"] = {
            all = { "DIRECT" },
            now = "DIRECT",
            type = "Selector",
            hidden = true,
        },
        DIRECT = { type = "Direct", history = {} },
        ["香港01"] = {
            type = "Hysteria2",
            history = { { time = "t1", delay = 233 } },
        },
        ["日本01"] = {
            type = "Vless",
            history = { { time = "t1", delay = 0 } },
        },
    },
})

local CANNED_CONNS = jsonEncode({
    downloadTotal = 1024,
    uploadTotal = 512,
    memory = 4096,
    connections = {
        {
            id = "conn-a",
            download = 800,
            upload = 200,
            start = "2026-11-06T02:00:00+08:00",
            chains = { "香港01", "主代理" },
            rule = "Match",
            rulePayload = "",
            metadata = {
                network = "tcp",
                type = "Tun",
                host = "example.com",
                destinationIP = "1.2.3.4",
                destinationPort = "443",
                process = "curl",
            },
        },
        {
            id = "conn-b",
            download = 224,
            upload = 312,
            start = "2026-11-06T02:00:01+08:00",
            chains = { "DIRECT" },
            rule = "GeoIP",
            rulePayload = "CN",
            metadata = {
                network = "udp",
                type = "Mixed",
                host = "",
                destinationIP = "9.9.9.9",
                destinationPort = "53",
                process = "",
            },
        },
    },
})

local CANNED_CONFIGS = jsonEncode({
    mode = "rule",
    ["allow-lan"] = true,
    ["mixed-port"] = 7890,
    tun = { enable = true, device = "FlClash" },
})

local CANNED_VERSION = jsonEncode({ meta = true, version = "v1.19.33-test" })

-- ── 假宿主状态 ─────────────────────────────────────────────────────────────

REQUESTS = {} -- { { method, url, body } }
RENDERED = nil -- panel.render 收到的树
BAR_TEXT = nil
FAIL_MODE = false -- 置 true 后所有请求返回传输失败
FAKE_NOW = 1762387200000 -- 固定的 nowMs 基准（毫秒）

local function requestPath(url)
    return (url:gsub("^https?://[^/]+", ""))
end

noctalia = {
    getConfig = function(key)
        local table_ = {
            controller_url = "http://127.0.0.1:9090",
            controller_secret = "s3cret",
        }
        return table_[key]
    end,
    tr = function(key)
        return key -- 返回键名本身，让 lib 回落到内置中文兜底
    end,
    json = {
        decode = function(text_)
            return jsonDecode(text_), nil
        end,
        encode = function(value, _pretty)
            return jsonEncode(value), nil
        end,
    },
    string = {
        urlEncode = function(s)
            return (tostring(s):gsub("[^%w%-_%.~]", function(c)
                return string.format("%%%02X", string.byte(c))
            end))
        end,
    },
    http = function(req, onResponse)
        table.insert(REQUESTS, { method = req.method or "GET", url = requestPath(req.url), body = req.body })
        if FAIL_MODE then
            onResponse({ ok = false, status = 0, body = "" })
            return true
        end
        local path = requestPath(req.url)
        local canned
        if path:find("/proxies", 1, true) == 1 then
            canned = CANNED_PROXIES
        elseif path == "/connections" then
            canned = CANNED_CONNS
        elseif path == "/configs" then
            canned = CANNED_CONFIGS
        elseif path == "/version" then
            canned = CANNED_VERSION
        elseif path:find("/group/", 1, true) == 1 then
            canned = jsonEncode({ ["香港01"] = 233, ["日本01"] = 0 })
        elseif path == "/cache/fakeip/flush" then
            canned = ""
        else
            canned = ""
        end
        onResponse({ ok = true, status = 200, body = canned })
        return true
    end,
    httpStream = function(_req, _onLine, _onClose)
        return nil -- 模拟流不可用，逼出差分兜底
    end,
    nowMs = function()
        FAKE_NOW += 1000 -- 每次调用推进 1 秒，差分速率是确定的
        return FAKE_NOW
    end,
    setUpdateInterval = function(_ms) end,
    togglePanel = function(_id) end,
    notify = function(_title, _body) end,
    notifyError = function(_title, _body) end,
    log = function(_msg) end,
}

-- ── ui.* 假构造器 ──────────────────────────────────────────────────────────

local function node(kind)
    return function(props, children)
        return { type = kind, props = props or {}, children = children or {} }
    end
end

ui = {
    column = node("column"),
    row = node("row"),
    scroll = node("scroll"),
    box = node("box"),
    label = node("label"),
    markdown = node("markdown"),
    glyph = node("glyph"),
    image = node("image"),
    separator = node("separator"),
    spacer = node("spacer"),
    progress = node("progress"),
    button = node("button"),
    graph = node("graph"),
    input = node("input"),
    select = node("select"),
    slider = node("slider"),
    toggle = node("toggle"),
}

panel = {
    render = function(tree)
        RENDERED = tree
    end,
    close = function() end,
    setWantsSecondTicks = function(_v) end,
    setNeedsFrameTick = function(_v) end,
}

barWidget = {
    setText = function(text_)
        BAR_TEXT = text_
    end,
    setGlyph = function(_name) end,
    setGlyphColor = function(_role) end,
    setColor = function(_role) end,
    setTooltip = function(_rows) end,
    setVisible = function(_v) end,
    isVertical = function()
        return false
    end,
    outputName = function()
        return nil
    end,
    render = function(_tree) end,
}

-- ── 断言工具 ───────────────────────────────────────────────────────────────

CHECKS = 0

function eq(actual, expected, what)
    CHECKS += 1
    if actual ~= expected then
        error(string.format("[FAIL] %s：期望 %s，实际 %s", what, tostring(expected), tostring(actual)), 2)
    end
end

function near(actual, expected, eps, what)
    CHECKS += 1
    if math.abs(actual - expected) > eps then
        error(string.format("[FAIL] %s：期望 ≈%s，实际 %s", what, tostring(expected), tostring(actual)), 2)
    end
end

function ok(condition, what)
    CHECKS += 1
    if not condition then
        error("[FAIL] " .. tostring(what), 2)
    end
end

--- 在渲染树里按类型与谓词找节点（深度优先），返回第一个命中的节点或 nil
function findNode(tree, kind, predicate)
    if tree == nil or type(tree) ~= "table" then
        return nil
    end
    if tree.type == kind and (predicate == nil or predicate(tree)) then
        return tree
    end
    for _, child in ipairs(tree.children or {}) do
        local hit = findNode(child, kind, predicate)
        if hit ~= nil then
            return hit
        end
    end
    return nil
end

function countNodes(tree, kind, predicate)
    local n = 0
    local function walk(t)
        if t == nil or type(t) ~= "table" then
            return
        end
        if t.type == kind and (predicate == nil or predicate(t)) then
            n += 1
        end
        for _, child in ipairs(t.children or {}) do
            walk(child)
        end
    end
    walk(tree)
    return n
end

function lastRequest()
    return REQUESTS[#REQUESTS]
end

--- 当前标题图标颜色（供「回调内不重绘」断言）
function role_before_tick()
    local glyphNode = findNode(RENDERED, "glyph", function(n)
        return n.props.name == "world"
    end)
    return glyphNode ~= nil and glyphNode.props.color or nil
end
