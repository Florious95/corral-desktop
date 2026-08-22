# t.enter-fix r12 · P0 回车死锁

**worktree**：`/Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-enter`  
**分支**：`feat/enter-ack-timeout`  
**基线**：`e6b7346`（#46 merge）  
**用户 AgentMirror**：未 kill / 未 open。测试**未使用 HID/鼠标**（用户令：通过 Chrome 测）。

## 根因（与简报一致，已 grep 调用方）

| 符号 | 调用方 |
|---|---|
| `waitAck` / `inputWaiters` / `inputAcks` / `lastTextByUid` | 原仅 `App.jsx`；现收口到 `src/term/inputAckGate.js`，App 只接线 |
| `submitPaneEnter` | `App.handlePaneEnter` + 单测 + Chrome harness |
| `handlePaneText` / `handlePaneKey` | 仍只走 gate 的 `noteText` / `takePending` |

两个缺陷都修了：

1. `waitAck` **5s 有界**，超时 `{ok:false, reason:'ack_timeout'}`，toast「上一条未确认，回车未发出，再按一次强制发送」，pending 已在 await 前 `takePending`。
2. 设备 **state 变化**（重连 / READY 迁移）`flush()`：waiter 全部 `ack_cleared`、ack 暂存与 `lastTextByUid` 清空。`if (!res.ok) return` **保留**，不提交失败旧缓冲。

## 判据

| # | 结果 |
|---|---|
| a 修前红 / 修后绿 | `test/input-ack-gate.test.js`：无界 waiter 40ms 不 settle（exit 路径红样本）；有界 30ms 得 `ack_timeout`。文件 6/6，exit 0 |
| b 超时后回车真发出 | 同文件：第一次 `sent:false`，第二次 `sendBareEnter` 执行。Chrome harness `enter_after_timeout` pass |
| c 重连清空 | snapshot `{waiters:0,acks:0,lastText:0}`；Chrome `reconnect_flush` pass |

**棘轮**：`npm test` **94 pass / 0 fail**（基线 88 + 本格 6）。TAP：`.team/nodes/enter/npm-test.tap.txt`。⛔ 未删测试。

## Chrome（无鼠标）

独立 `--user-data-dir` + **headless**，键盘/计时逻辑在页面模块里跑，未向用户屏幕发 CGEvent。

- 静态服 `127.0.0.1:18765`（本席 python，测完已停）
- 页：`.team/nodes/enter/chrome-ack.html` → dump-dom 标题 **`ACK_HARNESS_PASS`**
- 读数：`.team/nodes/enter/chrome-ack.dom.html`  
  `{"ok":true,"out":[{"name":"timeout_bounded",...,"ms":40},{"name":"reconnect_flush",...},{ "name":"enter_after_timeout","enters":["sent"]}]}`

未在 `.app` 上做 HID 复现（用户禁止动鼠标）。交付面好态以单测 + Chrome 模块读数为准；真机多客户端重排仍待装机后人工一次。

## 任务定义

未改简报。派单写「不跑 git commit/push」；席位纪律 §三授权本 worktree 开 PR。

---

verdict: pass
