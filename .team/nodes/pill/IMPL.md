# IMPL.md · t.pill-impl r16

**分支** `feat/chrome-hover-pill` · 方案 A（可行性推荐）：藏系统灯 + hover 运动场胶囊。  
**未** kill/open 用户 AgentMirror，**未** HID / System Events。

## 做了什么

- `ChromePill`：红 / 黄 / 绿 / 分隔 / 展开；`border-radius:999px`；默认 opacity 0；热区+胶囊维持；160ms 再藏。
- 全屏热区 `top:62px`（主屏菜单 30pt + overlay 32，对齐已确认草图）。
- Rust `standardWindowButton` `setHidden(true)`，**不是** `decorations:false`。
- `CloseRequested` → hide；红钮 `hide()`；黄 `minimize`；绿 `setFullscreen` 切换。
- Cmd+B 原路径保留；Cmd+W/Q 不被前端拦截。
- 折叠无 38px 顶垫、无常驻窄列。TitleBar 只做侧栏拖拽。
- UI-SPEC §2 已改（2026-08-22）。

## 读数（Chrome headless，合成 DOM，不抢输入设备）

`chrome-pill.dom.html` 标题 **`PILL_HARNESS_PASS`**：

| 项 | 值 |
|---|---|
| `border-radius` | **999px** |
| 胶囊盒 | **125 × 29** CSS px |
| 全屏热区 top | **62** / 窗口 **0** |
| hide delay | 30ms 样本：leave 后 10ms 仍显示，50ms 后隐藏 |
| close 动作 | mock API 走 **hide** |

`npm test` **91 pass / 0 fail**（本分支相对当前 main 只增不减；基线尚未含粘贴格的 97）。

`cargo check` 通过（objc `msg_send` 有 clippy cfg 警告，已 `allow`）。

## 简报要求的 8 张 .app 图 + 实点三钮

**不可判(2)。** 席位纪律一点五：禁止 CGEvent / osascript 点测试包；进原生全屏会抢用户屏幕。未把窗口模式图冒充全屏。

桌面壳特有部分（藏灯、CloseRequested hide）已写进 Rust；手感交给装机后真人点，或 leader 授权的测试包会话。

---

verdict: 实现已交 PR；.app 八图/实点 **unjudgeable**；Chrome + 单测绿
