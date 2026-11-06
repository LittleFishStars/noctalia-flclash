#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# tests/run.sh —— 离线测试（不依赖 Noctalia 宿主，也不连接 mihomo 控制器）
#
# 三个用例（拼接执行，原因见 tests/env.luau 顶部注释）：
#   lib   —— lib/flclash.luau 的纯逻辑：设置兜底、单位换算、HTTP 封装、
#            分组排序、节点延迟、连接差分
#   panel —— panel.luau 的完整渲染链：假宿主同步回调 canned 快照，
#            再驱动展开分组 / 切节点 / 切模式 / TUN / 连接区并检查渲染树
#   bar   —— bar.luau 的文本与状态：正常态、失联态、恢复、差分速率
#
# 用法：tests/run.sh
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(dirname "$here")"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/flclash-tests.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

# 通用前置：假宿主 + lib（以 f 暴露）+ 假 require
build_prelude() {
    cat "$here/env.luau"
    printf '\nf = (function()\n'
    cat "$root/lib/flclash.luau"
    printf '\nend)()\n\n'
    printf 'require = function(path)\n'
    printf '    assert(path:find("flclash", 1, true) ~= nil, "测试只 require lib: " .. path)\n'
    printf '    return f\n'
    printf 'end\n\n'
}

echo "== lib =="
{
    build_prelude
    cat "$here/lib_assert.luau"
} > "$tmpdir/lib.luau"
luau "$tmpdir/lib.luau"

echo "== panel =="
{
    build_prelude
    cat "$root/panel.luau"
    printf '\n'
    cat "$here/panel_assert.luau"
} > "$tmpdir/panel.luau"
luau "$tmpdir/panel.luau"

echo "== bar =="
{
    build_prelude
    cat "$root/bar.luau"
    printf '\n'
    cat "$here/bar_assert.luau"
} > "$tmpdir/bar.luau"
luau "$tmpdir/bar.luau"

echo "全部通过 ✅"
