# OSC-FIX.md · t.osc-fix r23

**worktree** `/Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-osc`  
**分支** `feat/osc-reply-filter`  
未 HID；未碰上游；未放宽 CSP。

## 根因

远端 OSC 11 查询进我方 xterm → 自动应答 `ESC ]11;rgb:fbfb/fafa/f8f8 BEL`（`#fbfaf8` = 我方主题）。  
`TerminalView` 把 `term.onData` 原样交给 `NativeInputPump` → `parseOnData`：

| 修前（`parseOnData(OSC11)`，坏态红） | 读数 |
|---|---|
| 可打印段 | 含 `11;rgb:fbfb/fafa/f8f8` → 会 `input.text` |
| 单独 `ESC` 一截 | `{ type:'key', value:'esc' }` |

`ESC ]` 在同一截里会先被当成 Alt/Meta 吃掉，剩下 `11;rgb:…` 进输入行——与用户截图一致。

调用方：`parseOnData` 只被 `NativeInputPump.onData` 用；`term.onData` 只在 `TerminalView.open`。两边都走 `consumeTerminalReplies`（共享函数，不是每个调用点各写一遍）。

## 修法

丢掉：OSC `ESC ] … BEL|ST`、DCS `ESC P … ST`、CSI 终字节 `c`（DA）/`n`（DSR）/`R`（CPR）。  
保留：方向键 `ESC [ A/B/C/D`（终字节大写 C ≠ DA 的 c）、SGR 鼠标 `ESC [ < … M`。  
不完整序列进 hold，凑齐再丢；满 8192 丢弃，⛔ 不当文本 flush。

取舍：远端拿不到颜色应答会超时、回落默认主题。与「不支持该查询的终端」一致，可接受。

## 好态 / 不倒退（`NativeInputPump`）

| 输入 | 上行 |
|---|---|
| OSC 11 整段 | 零帧 |
| OSC 11 拆两截 | 零帧 |
| `hi` + 四方向 + Ctrl-C + Enter | text=`hi`；keys=up,down,right,left,ctrl_c；enter=1 |

`npm test` **103/0**（棘轮 98）。UI-SPEC §6.2 + §11.16、CLIENT-CONTRACT §3.5，裁定 2026-08-23。

verdict: pass
