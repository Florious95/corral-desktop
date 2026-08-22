# SUBSCRIBE-ARM.md · t.resize-fix r20

**worktree** `/Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-resize`  
未读 `.env` 原文；一次性 token 只进子进程环境，未打印。未 `kill-server`；只 `kill-session -t amrsz`。未 HID。

## 任务定义改动（显式，非静默）

BRIEF 第 3 轮写：还原 fit 像素锁后跑**同一个** r19 探针。

r19 探针的 `resizeCount` 只在 `createResizeAnnouncer.send` 里加，而那条路**从不调用** `TerminalView.fit`（只 `note` + snapshot `reassert`；当时 `snapshots=0`）。  
⇒ 原样还原锁再跑 r19 探针，`resizeCount` **构造上仍是 0**，量不到像素锁。

本轮探针仍是：真 `Client.subscribe` + `paste-buffer` + `Enter`，n=20。  
**补上**产品同款 `TerminalView.fit`：host CSS 不变、`.xterm-screen` 宽每次抖 ±16px（ResizeObserver + 写屏后 cell 探针）。paste 与 Enter 之间 `fit()`×6 再等 140ms（让 120ms `_report` 发出去）。  
修前臂：临时删掉 `TerminalView.js` 里 host 像素早退，量完写回原文件（`git diff src/term/TerminalView.js` 空）。

## 三行齐（n=20）

| 态 | submitted | failRate | resizeCount（注入窗口） |
|---|---|---|---|
| 对照：无 WS subscribe | 20/20 | **0** | — |
| **修后：像素锁开** + subscribe + fit 抖动 | 20/20 | **0** | **0**（fitTicks=1，锁在 `_cell` 前返回） |
| **修前：像素锁关** + subscribe + fit 抖动 | 20/20 | **0** | **20**（fitTicks=121） |

原始 JSON：`.team/nodes/resize/ws-subscribe-probe.json`。

## 读数怎么用（不许往「我方是滞留致因」上圆）

- **resizeCount 修前 20、修后 0**：像素锁确实挡住了「host 没变、cell 探针抖」打出的 `resize` 帧。这一截因果在**我方 `fit()`**。
- **failRate 三臂都是 0**：这些协议 `resize` 帧**没有**把 `paste-buffer`/`Enter` 打丢。框架队「关掉客户端积压即放行」**不能**用这一档钉死在我方客户端上。
- r18 手工 `tmux resize-window` 夹在 paste↔Enter 仍是唯一 failRate>0 的量（0.15）。那是 tmux 窗口尺寸真变，不是本臂这条 WS `resize`。

grouped `new-session -t` 仍在 daemon。write_paths 不含 `_night/BACKLOG-UPSTREAM.md`，上游项只记在本文件：协议 `resize` 未复现注入失败；真钳制/息屏小客户端仍归 daemon。

棘轮：`npm test` **101/0**（基线 94）。

verdict: pass
