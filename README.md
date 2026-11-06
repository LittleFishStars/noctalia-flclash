# ylxc/flclash —— FlClash 流量显示与控制面板

Noctalia 桌面插件：在状态栏显示 FlClash / mihomo（Clash Meta 内核）的实时流量，
并提供一个控制面板——速率曲线、模式切换、分组选节点、整组测速与连接管理。

数据全部来自 FlClash 的**外部控制器 REST API**（mihomo 内核）：

| 通道 | 用途 |
| --- | --- |
| `GET /traffic`（chunked 流） | 每秒一条的瞬时上下行速率（首选，`httpStream` 长连接） |
| `GET /connections` | 累计总量、内存、活动连接快照；相邻快照差分兜底速率与逐连接速率 |
| `GET /configs` / `PATCH /configs` | 读取与切换 `mode`、`tun.enable`、`allow-lan` |
| `GET /proxies` | 分组与节点（顺序取自 `GLOBAL.all`，隐藏分组默认过滤） |
| `PUT /proxies/{组}` | 手动切换选择器节点（组名 / 节点名 URL 编码） |
| `GET /group/{组}/delay` | 整组测速 |
| `DELETE /connections[/{id}]` | 断开单条 / 全部连接 |
| `POST /cache/fakeip/flush` | 清除 fake-ip 缓存 |

只读为主；所有写操作（切节点、切模式、TUN、断开连接、清 fake-ip）仅由用户点击触发。

## 界面

遵循 FlClash 的界面体系：**用填充色阶画层级、不用边框，颜色只给状态，大圆角，
多用图标代替文字**（图标统一取自宿主内置的 Tabler 字体）。

- **栏组件**（默认）：`↓1.2M ↑340K` 实时速率，可切换为仅下行 / 仅上行 /
  累计流量 / 连接数 / 当前模式。控制器失联时整块变 error 色并显示「未连接」，
  可设置失联时自动隐藏。左键打开面板，右键重连流量流并刷新。
- **控制面板**：
  - 流量卡：大字号实时速率 + 60 秒速率曲线（上行 / 下行双色共享纵轴）+
    累计流量、连接数、内核内存；
  - 控制卡：规则 / 全局 / 直连分段按钮，TUN 与允许局域网开关；
  - 代理分组：按配置顺序排列，展开后逐节点点选（当前节点高亮），支持整组测速，
    延迟按 <200ms / <500ms / 更高分三级配色；
  - 活动连接：按瞬时速率排序，单条断开或一键清空；
  - 工具行：清除 fake-ip 缓存。

速率优先走 `/traffic` 流（每秒一条）；流不可用时自动回落到 `/connections`
累计量差分，栏组件与曲线都不会因此空白。

## 安装与配置

1. 把本目录放进 Noctalia 插件目录（本地开发即
   `~/.local/share/noctalia/plugins/ylxc-flclash`）；
2. 在 Noctalia 设置 → 插件里启用 **FlClash**，并从「添加栏组件」里添加它；
3. 在插件设置里填：
   - **控制器地址**：默认 `http://127.0.0.1:9090`（FlClash 外部控制器）；
   - **外部控制器密钥**：FlClash「设置 → 入站 → 外部控制器密钥」，留空则不带鉴权头。
4. 其余设置：刷新间隔、曲线窗口、测速地址与超时、连接列表条数、显示隐藏分组等。

密钥只保存在本机的 Noctalia 设置里（`~/.local/state/noctalia/settings.toml` 的
`plugin_settings` 段），不写入本仓库。

## 校验与测试

```bash
# 官方清单校验（设置项与代码交叉核对）
noctalia plugins lint ~/.local/share/noctalia/plugins/ylxc-flclash

# 离线测试：假宿主同步回调 canned 快照，不连接真实控制器
bash tests/run.sh
```

`tests/run.sh` 共三组：`lib`（API 客户端与派生逻辑，86 项断言）、
`panel`（面板渲染链与交互冒烟，36 项）、`bar`（栏文本与状态，5 项）。
拼接执行的原因见 `tests/env.luau` 顶部注释（luau CLI 的 require 与 io 限制）。

## 已知边界

- FlClash 自身的「系统代理 / TUN 开关」由 FlClash 管理，面板里的 TUN 开关改的是
  mihomo 运行时配置，FlClash 重载配置时可能覆盖回来；
- 自动分组（URLTest / Fallback / LoadBalance）点击节点会收到 mihomo 的提示通知，
  不发起无效的切换请求；
- 面板里「GLOBAL」分组固定排在最后，只在全局模式下才有实际意义。
