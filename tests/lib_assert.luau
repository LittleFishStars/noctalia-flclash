--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- tests/lib_assert.luau —— lib/flclash.luau 的纯逻辑断言
-- 由 tests/run.sh 拼在 env.luau + lib 源码之后执行。
-- ══════════════════════════════════════════════════════════════════════════

-- 设置兜底
eq(f.VERSION, "1.0.0", "版本")
eq(f.text("controller_url", "x"), "http://127.0.0.1:9090", "字符串设置")
eq(f.text("not_exist", "fallback"), "fallback", "字符串设置缺省")
eq(f.flag("not_exist", true), true, "布尔设置缺省")
eq(f.number("not_exist", 42), 42, "数字设置缺省")
eq(f.clamp(999, 1, 30), 30, "clamp 上界")
eq(f.clamp(-1, 1, 30), 1, "clamp 下界")
eq(f.base(f.cfg()), "http://127.0.0.1:9090", "base 去尾斜杠")
eq(f.base({ url = "127.0.0.1:9090/" }), "http://127.0.0.1:9090", "base 补协议")
eq(f.trafficUrl(f.cfg()), "http://127.0.0.1:9090/traffic", "traffic 流地址")

-- 单位换算
eq(f.bytes(0), "0 B", "bytes 0")
eq(f.bytes(1023), "1023 B", "bytes B 上界")
eq(f.bytes(1024), "1.0 KB", "bytes KB")
eq(f.bytes(1024 * 1024), "1.0 MB", "bytes MB")
eq(f.bytes(1024 * 1024 * 1024), "1.0 GB", "bytes GB")
eq(f.speed(2048), "2.0 KB/s", "speed")
eq(f.compact(0), "0B", "compact 0")
eq(f.compact(1536), "1.5K", "compact K")
eq(f.compact(1024 * 1024 * 3), "3.0M", "compact M")
eq(f.ms(nil), "--", "ms nil")
eq(f.ms(0), "超时", "ms 超时")
eq(f.ms(233), "233ms", "ms 正常")
eq(f.delayRole(100), "primary", "延迟角色 快")
eq(f.delayRole(300), "tertiary", "延迟角色 中")
eq(f.delayRole(800), "error", "延迟角色 慢")
eq(f.delayRole(0), "error", "延迟角色 超时")

-- 模式 / 类型文案
eq(f.modeText("rule"), "规则", "模式 规则")
eq(f.modeText("global"), "全局", "模式 全局")
eq(f.modeText("direct"), "直连", "模式 直连")
eq(f.groupGlyph("Selector"), "switch-horizontal", "分组图标 Selector")
eq(f.groupGlyph("URLTest"), "activity", "分组图标 URLTest")
eq(f.groupTypeText("Fallback"), "回退", "分组类型 回退")

-- 环形缓冲
local ring = {}
for i = 1, 10 do
    f.ringPush(ring, i, 3)
end
eq(#ring, 3, "ring 上限")
eq(ring[1], 8, "ring 丢最旧")
local dn, up, peak = f.ringNormalize({ 1024, 2048 }, { 512 })
eq(peak, 2048, "ring 归一化峰值")
eq(dn[1], 0.5, "ring 归一化 down[1]")
eq(dn[2], 1, "ring 归一化 down[2]")
eq(up[1], 0.25, "ring 归一化 up 共享轴")
local _, _, floorPeak = f.ringNormalize({}, {})
eq(floorPeak, 1024, "ring 归一化最小满刻度")

-- HTTP 封装：鉴权头、路径编码、写请求 body
local got = nil
f.proxies(function(ok_, status, data)
    got = { ok_, status, data }
end)
eq(got[1], true, "GET /proxies 成功")
eq(got[2], 200, "GET /proxies 状态")
ok(type(got[3]) == "table", "GET /proxies 解析出表")
local req = lastRequest()
eq(req.method, "GET", "GET /proxies 方法")
eq(req.url, "/proxies", "GET /proxies 路径")
ok(req.body == nil, "GET /proxies 无 body")

f.selectProxy("主代理", "日本01", function() end)
req = lastRequest()
eq(req.method, "PUT", "切换节点方法")
ok(req.url:find("%%"), "切换节点组名 URL 编码")
eq(jsonDecode(req.body).name, "日本01", "切换节点 body")

f.patchConfigs({ mode = "global" }, function() end)
req = lastRequest()
eq(req.method, "PATCH", "PATCH configs 方法")
eq(jsonDecode(req.body).mode, "global", "PATCH configs body")

f.groupDelay("主代理", f.cfg(), function() end)
req = lastRequest()
ok(req.url:find("/group/", 1, true) == 1, "整组测速路径")
ok(req.url:find("generate_204", 1, true) ~= nil, "整组测速带 url")
ok(req.url:find("&timeout=5000", 1, true) ~= nil, "整组测速带 timeout")
ok(req.url:find("http://", 11, true) == nil, "整组测速 url 已编码（无裸冒号斜杠）")

f.closeConn("conn-a", function() end)
eq(lastRequest().method, "DELETE", "断开单连接方法")
f.closeAllConns(function() end)
eq(lastRequest().url, "/connections", "断开全部连接路径")
f.flushFakeip(function() end)
eq(lastRequest().url, "/cache/fakeip/flush", "清除 fake-ip 路径")

-- 失败路径
FAIL_MODE = true
local failed = nil
f.configs(function(ok_, _status, _data, errMsg)
    failed = { ok_, errMsg }
end)
eq(failed[1], false, "传输失败应报错")
eq(failed[2], "transport", "传输失败原因")
FAIL_MODE = false

-- 分组排序：按 GLOBAL.all、hidden 过滤、GLOBAL 排最后
local decoded = jsonDecode(CANNED_PROXIES).proxies
local visible = f.orderedGroups(decoded, false)
eq(#visible, 3, "可见分组数：主代理 / 自动选择 / GLOBAL")
eq(visible[1].name, "主代理", "分组顺序 1")
eq(visible[2].name, "自动选择", "分组顺序 2")
eq(visible[3].name, "GLOBAL", "GLOBAL 排最后")
eq(visible[1].type, "Selector", "分组类型")
eq(visible[1].now, "香港01", "分组当前节点")
eq(#visible[1].all, 4, "分组节点数")
local all = f.orderedGroups(decoded, true)
eq(#all, 4, "显示隐藏分组")
eq(all[3].name, "隐藏组", "隐藏分组按配置顺序出现")

-- 节点延迟
eq(f.delayOf(decoded["香港01"], f.cfg().testUrl), 233, "节点历史延迟")
eq(f.delayOf(decoded["日本01"], f.cfg().testUrl), 0, "节点超时延迟")
eq(f.delayOf(decoded["DIRECT"], f.cfg().testUrl), nil, "无历史节点延迟")
eq(f.delayOf({
    extra = { ["http://www.gstatic.com/generate_204"] = { history = { { delay = 88 } } } },
    history = { { delay = 999 } },
}, "http://www.gstatic.com/generate_204"), 88, "extra 分 URL 延迟优先")

-- 连接差分：两次快照按 id 算速率
local connSnap = jsonDecode(CANNED_CONNS)
local prev = {
    at = 1000,
    map = {
        ["conn-a"] = { d = 100, u = 50 },
        ["conn-b"] = { d = 224, u = 300 },
        ["gone"] = { d = 1, u = 1 },
    },
}
local connRows, nextPrev = f.connRows(connSnap, prev, 2000)
eq(#connRows, 2, "连接行数")
eq(connRows[1].id, "conn-a", "按速率排序")
near(connRows[1].dSpd, 700, 0.001, "下行速率差分")
near(connRows[1].uSpd, 150, 0.001, "上行速率差分")
eq(connRows[1].host, "example.com", "连接 host")
eq(connRows[1].port, "443", "连接端口")
eq(connRows[1].process, "curl", "连接进程")
eq(connRows[2].host, "9.9.9.9", "无 host 回落 IP")
eq(connRows[2].rule, "GeoIP", "连接规则")
eq(connRows[2].rulePayload, "CN", "规则 payload")
eq(f.exitNode(connRows[1].chains), "香港01", "出口节点")
eq(nextPrev.map["conn-a"].d, 800, "下一轮基线")
ok(nextPrev.map["gone"] == nil, "消失的连接从基线移除")
local baseline = 0
for _ in pairs(nextPrev.map) do
    baseline += 1
end
eq(baseline, 2, "基线只保留当前连接")

print(string.format("[lib] %d 项断言通过", CHECKS))
