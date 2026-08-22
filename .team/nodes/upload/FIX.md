# t.up-fix r13 · 粘贴焦点 + Chrome 后台取证

**worktree**：`/Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-upfix`  
**分支**：`feat/upload-native-http`  
**PR**：https://github.com/Florious95/corral-desktop/pull/47  
**用户 AgentMirror**：未 kill / 未 open；**未驱动鼠标键盘**。

## 产品

焦点列 DOM `paste` 挂在 `window`（`clipboardPasteRoot`）。选中列即可粘，不必点进 xterm。图片仍走 Rust `POST /upload`，无 loopback `connect-src`。

`rg -i token src/term/uploadLog.js src-tauri/src/main.rs`：无匹配。

## 是非题

见 `PASTE-PATH.md`。Chrome：合成 paste **能**进 window 监听；只挂 pane 时 **不能**。`.app` 真 Cmd+V **不可判(2)**。

## 棘轮

`npm test` **101 pass / 0 fail**（基线 88）。TAP：`npm-test-r13.tap.txt`。

Chrome harness：`PASTE_HARNESS_PASS`（MCP 无 DevTools 工具，改 headless；任务定义此项已写明）。

## (a)–(e)

`EVIDENCE-coldstart.md`：**不可判(2)**（禁止在 .app 上合成输入）。未把单测 101 写成「第 1 次粘图成功」。

临时探针未进 PR。

---

verdict: 产品修已交 PR；Chrome 复现焦点根因；`.app` 冷启动粘图不可判(2)
