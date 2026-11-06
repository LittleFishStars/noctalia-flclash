--!nocheck
-- ══════════════════════════════════════════════════════════════════════════
-- tests/bar_assert.luau —— bar.luau 的渲染冒烟
-- 前置：env.luau + lib + bar 源码已拼进同一 chunk；顶层 render()+update() 已跑。
-- ══════════════════════════════════════════════════════════════════════════

-- 正常态：默认显示上下行速率（首轮无基线，速率为 0）
eq(BAR_TEXT, "↓0B ↑0B", "正常态栏文本")

-- 失联态：请求全挂 → 未连接（直接再驱动一轮）
FAIL_MODE = true
REQUESTS = {}
request()
eq(BAR_TEXT, "未连接", "失联态栏文本")
FAIL_MODE = false

-- 恢复：右键重连 + 刷新
onRightClick()
eq(BAR_TEXT, "↓0B ↑0B", "恢复后栏文本")
ok(#REQUESTS >= 4, "右键触发了刷新请求")

-- 差分速率：两次 connections 快照间隔 1 秒
request()
-- canned downloadTotal 恒为 1024，差分恒为 0；仅验证文本稳定
eq(BAR_TEXT, "↓0B ↑0B", "差分速率文本")

print(string.format("[bar] %d 项断言通过", CHECKS))
