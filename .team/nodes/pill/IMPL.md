# IMPL.md · t.pill-impl r17

**worktree** `/Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-chrome`  
**分支** `feat/chrome-hover-pill`（merge `origin/main` @ `20b056b` 后再改关窗）  
**用户 AgentMirror**：未 kill / 未 open。**未** HID / System Events。

## 1. 并 main（解冲突，未用 `--ours`/`--theirs`）

`git merge origin/main`。真正冲突只有 `docs/UI-SPEC.md` §11 编号；`src/App.jsx` 三方自动合上。

人工保留：

- main：`createInputAckGate` / `submitPaneEnter` / `ackGate.flush` / `onInputResult`
- 本分支：`ChromePill`（⛔ 未把 `HoverToggle` 接回去）

自查：`git diff origin/main HEAD --stat` **没有** `inputAckGate` / `input-ack-gate` 删除行（两边相同，stat 为空）。

`test/input-ack-gate.test.js` 在 main 上是 **6** 例（简报写 12 是过时计数）。本回合 6/6 绿。**未改任务定义去凑 12。**

## 2. 红钮 = 真关闭

去掉 Rust `CloseRequested { prevent_close; hide }`。默认关窗，进程随最后窗口退出。

JS `runWindowChrome('close')` → `api.close()`；`desktopWindowApi.close = () => w.close()`。⛔ 不再 `hide()`。

UI-SPEC §2（2026-08-22）：关闭 = `window.close()`，Dock 不留残留。⛔ 未加托盘。

Cmd+B 仍本地；Cmd+W/Q 前端不拦；Rust 不再 `prevent_close`。

## 读数

Chrome headless（`localhost` IPv6；独立 `chrome-profile`；不抢输入设备）`PILL_HARNESS_PASS`：

| 项 | 值 |
|---|---|
| `border-radius` | **999px** |
| 胶囊盒 | **125 × 29** CSS px |
| 全屏热区 top | **62** / 窗口 **0** |
| hide delay | 样本 hideMs=30：leave 后 10ms 仍显示，之后隐藏 |
| close 动作 | mock API 走 **close**，不含 hide |

`npm test` **98 pass / 0 fail**（main 棘轮 94；本分支含胶囊 + 关窗断言，≥97）。

## 简报要求的 8 张 .app 图 + 实点三钮 + `pgrep AgentMirrorTest`

**不可判(2)。** 纪律一点五禁止 CGEvent / cliclick / osascript click 点测试包红钮；进原生全屏会抢用户屏幕。未把窗口模式图冒充全屏。未 `open` 用户 `AgentMirror.app`。

关窗因果用源码 + 单测夹住：`main.rs` 无 `prevent_close`/`CloseRequested`；`runWindowChrome('close')` 调 `close()`。

---

verdict: pass（并 main + 真关闭已进分支）；.app 八图/按叉 pgrep **unjudgeable**
