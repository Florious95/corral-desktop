# PASTE-PATH.md · t.up-fix r13

**Chrome DevTools MCP**：本席 MCP 目录里 **没有** chrome/devtools 工具（`GetMcpTools pattern chrome|devtools` 空）。改用独立 user-data-dir 的 **Chrome headless** 在页面里合成 `paste` + `DataTransfer`（不碰系统鼠标键盘）。

## 1. 是非题：`Cmd+V` 会不会变成 DOM `paste`？

| 面 | 读数 | 判 |
|---|---|---|
| Chrome 合成 `Event('paste')` + `clipboardData` | `focused_window_listener_gets_synthetic_paste`: **window=1** | **会**（handler 跑了） |
| 未聚焦、监听只在 pane 上、paste 打在 window | `unfocused_window_paste_misses_pane_listener`: **pane=0 window=0** | **不会**进 pane 监听 |
| `.app` 里真实 Cmd+V | ⛔ 禁止 HID / System Events 合成输入 | **不可判(2)** |

DOM：`.team/nodes/upload/chrome-paste.dom.html` 标题 `PASTE_HARNESS_PASS`。

## 2. activeElement（Chrome 合成 paste，未点 xterm）

读数：`document.activeElement.tagName === "BODY"`。  
没有点进终端内容区；paste 仍能打到 **window capture** 监听。

## 3. 根因与产品修

**焦点是根因**（Chrome 复现：只挂 pane 时 window 上的 paste 到不了）。  
产品要求：选中列即可粘，不必先点进 xterm。

修法（进 PR，已 grep）：

- `clipboardPasteRoot(focused)` → `'window' | 'pane'`
- `TerminalPane` 焦点列：`window.addEventListener('paste', …, {capture:true})`；打开后 `view.focus()`
- 调用方：`handleClipboardData` ← TerminalPane；`uploadImage` ← App shim / TerminalPane `sendImage`；`inputAttachment` ← `uploadImage`；`_route` ← DeviceManager 会话动作。未在各调用方各补一份，守卫在 `clipboardPasteRoot` + `chooseUploadTransport`。

临时 `pasteProbe.js` **已删，不进 PR**。

## 4. (a)–(e) `.app` 冷启动粘图

见 `EVIDENCE-coldstart.md`：在「不许合成 .app 输入」红线下 **不可判**。
