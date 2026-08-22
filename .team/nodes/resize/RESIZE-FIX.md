# RESIZE-FIX.md · t.resize-fix r20

**worktree** `/Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-resize`  
**分支** `feat/resize-reannounce` · PR #51  
未 kill/open 用户 AgentMirror；未 HID；未读 `.env` 原文。

## r20（本轮）

只补「两头夹住」的坏态头。方法与读数见 **`SUBSCRIBE-ARM.md`**（判据按这个文件名找）。

摘要：修前 fit 无像素锁 ⇒ 注入窗口 `resizeCount=20`；修后锁开 ⇒ `resizeCount=0`。两臂 failRate 都是 0（对照也是 0）。产品码相对 r19 **无新改**（锁量完已写回）。

## r19 补的那一档：真 WS `subscribe`

凭据：进程内 `set -a; AGENTMIRROR_TOKEN=$(openssl rand -hex 16); set +a`（一次性，**不是**用户 `.env`）。只注入子进程。产物只写「已用 env 注入，未打印」。

Daemon：`/Volumes/nvme/Projects/远程Agent安卓/server/agentmirrord`（只执行不写上游）  
`-listen` 本机回环、一次性 `-state-dir`（不入库）。stdout 丢弃。

客户端：本仓库 `src/vendor/agentmirror/client.js`（`ws` 包）。

TUI：`grok-tui.c` 编成 comm=`grok`。会话名 `amrsz`，结束只 `kill-session -t amrsz`。

## 注入 n=20（paste-buffer -d + Enter）

r19（探针不调用 `fit`）：对照 20/20 failRate 0；subscribe 20/20 failRate 0；`resizeCount=0`。

r20（`fit`+抖动）：见 SUBSCRIBE-ARM 三行表。

r18 手工 paste↔Enter 夹 `resize-window`：17/20 failRate 0.15（本轮未重跑）。

## 仍不是根治

grouped `new-session -t` 在 daemon。write_paths 仍不含 `_night/BACKLOG-UPSTREAM.md`。

## 棘轮

`npm test` **101/0**。

verdict: pass
