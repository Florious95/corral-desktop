# RESIZE-FIX.md · t.resize-fix r18

**worktree** `/Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-resize`  
**分支** `feat/resize-reannounce`  
未 kill/open 用户 AgentMirror；未 HID。

## 第一件事：attach 决定权

只读核过 `/Volumes/nvme/Projects/远程Agent安卓/server/internal/`：

| 层 | 事实 |
|---|---|
| 桌面端 | 只发 WS `subscribe` / `resize`。**没有** `tmux attach` / `new-session -t`。 |
| daemon `handleSubscribe` | `br.Resize`（`set-option window-size latest` + `resize-window`）再 `pipe-pane`。 |
| 框架队首选 grouped `new-session -t` | **落在 daemon**，客户端改不了。 |

⚠ **账本 write_paths 不含** `.team/nodes/_night/BACKLOG-UPSTREAM.md`，本席 **没写那份文件**（否则越权）。请 leader 把下面两条抄进 BACKLOG：

1. **根治**：订阅时 `tmux new-session -t <目标>` 分组会话，各客户端独立尺寸。  
2. **息屏仍挂着**：对方没断开时 tmux 仍跟 latest/小客户端；桌面端 ⛔ 不许伪造 detach。

本格做的是客户端**缓解**：DOM 不变也要能重发 `resize`；并堵住写屏抖动打出的多余 `resize` 帧（daemon 每帧都会 `window-size latest` + `resize-window`，夹在 paste 与 Enter 之间）。**不是根治。**

## 调用方（动手前 grep）

- `dm.resize` ← `App` shim `client.resize` ← `TerminalPane` announcer（**已去掉 App 第二帧 `onResize`**）
- `TerminalView._report` / `fit` / `reassertResize`
- `DeviceManager.resize` → `Client.resize`

## 改了什么

1. `fit`：host **像素没变直接返回**（WebGL 首次仍 `fit({force:true})`）。  
2. `createResizeAnnouncer`：focus / `visibility=visible` / snapshot 捕获列宽明显小于本列网格 → 去抖 250ms 重发同一 rows/cols。⛔ 无定时轮询。  
3. UI-SPEC §6.2 + §11.15（2026-08-22）。

## 注入判据（自建 tmux socket `.team/nodes/resize/ts`）

TUI：`tui-reader.py`（cbreak；**SIGWINCH 清空输入行**，模拟会重绘输入行的 TUI）。注入：`load-buffer` + `paste-buffer -d` + `send-keys Enter`。n=20。量具：进程写 `got.log`（不靠 24 行 capture 窗口）。

| 态 | submitted / 20 | failRate | 缺 |
|---|---|---|---|
| **对照** 无 attach、无中途 resize | **20** | **0** | [] |
| 同 session 再挂一个 40×12 attach | 20 | 0 | [] （python TUI ≠ team-agent；此路未复现） |
| **坏** paste 与 Enter 之间 `resize-window`（= daemon 处理 resize 帧） | **17** | **0.15** | 8, 17, 19 |

对照绿、坏态红（本轮 15%；上一轮同脚本 10%）。修好后「不要在注入窗口打 resize」对应对照档 **failRate 0**。

**我方 WS `subscribe` 真客户端**：需要自建 daemon + 一次性 token。本机有上游目录里的 `agentmirrord` 二进制，但 **pairing token 在 .env，红线不读**。⇒ **subscribe 本体不可判(2)**。未把 tmux 机制实验写成「桌面 subscribe 已解决」。

## 交付面 a/b/c

| # | 读数 |
|---|---|
| a 修前语义 | 缩到小尺寸后 **DOM 不变则窗口停在小的**：`afterPhone=40x12`，`stillSmall=40x12` |
| b 重发后 | `afterReassert=80x24`（回到桌面 `desktop=80x24`） |
| c 过渡态图 | `geom-small.capture.txt` 是缩窗后的 pane 文本，**不是** tmux 给大客户端填的 `·` 边（那是 attach 端绘制）。真 · 边 **不可判(2)**（禁止抢用户屏截图）。 |

## 棘轮

`npm test` **101 pass / 0 fail**（基线 94；新增 resize-announce + TerminalView 像素锁/reassert）。

---

verdict: pass（客户端缓解 + 机制坏/好夹住）；grouped attach 与真 WS subscribe **unjudgeable / 待 BACKLOG**
