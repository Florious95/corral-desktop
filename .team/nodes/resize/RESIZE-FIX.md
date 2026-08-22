# RESIZE-FIX.md · t.resize-fix r19

**worktree** `/Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-resize`  
**分支** `feat/resize-reannounce` · PR #51  
未 kill/open 用户 AgentMirror；未 HID；未读 `.env` 原文。

## r19 补的那一档：真 WS `subscribe`

凭据：进程内 `set -a; AGENTMIRROR_TOKEN=$(openssl rand -hex 16); set +a`（一次性，**不是**用户 `.env`）。只注入子进程。产物只写「已用 env 注入，未打印」。

Daemon：`/Volumes/nvme/Projects/远程Agent安卓/server/agentmirrord`（只执行不写上游）  
`-listen 127.0.0.1:19911` `-state-dir` 在本格目录（已删，不入库）`-qr-listen` 关。stdout 丢弃（避免 QR 落盘）。

客户端：本仓库 `src/vendor/agentmirror/client.js`（`ws` 包），`subscribe` + 产品同款 `createResizeAnnouncer`（snapshot 窄则 reassert）。

TUI：`grok-tui.c` 编成 comm=`grok`（daemon `filterModel` **只列出白名单进程**；python 进不了 listing）。会话名 `amrsz`，结束只 `kill-session -t amrsz`，**从未** `kill-server`。

卡过的路（显式）：

1. 私有 `TMUX_TMPDIR`：本机 **8-21 的 agentmirrord 二进制不扫** 那棵树 → listing 无 amrsz。  
2. 默认目录里另开 socket 文件 `amrsz`：listing 仍只有原 43 个白名单 pane。  
3. python TUI：被 `filterModel` 丢掉。  
4. Node `ws` 的 Buffer 文本帧：已在探针里把 `{` 开头 Buffer 转成 string，否则 `ready` 但解析失败。

## 注入 n=20（paste-buffer -d + Enter）

| 态 | submitted | failRate |
|---|---|---|
| 对照：无 WS subscribe | **20/20** | **0** |
| **真 Client.subscribe 着** | **20/20** | **0** |
| r18 手工 paste↔Enter 夹 `resize-window` | 17/20 | 0.15 |

`resizeCount`（announcer 在注入窗口额外 `resize` 帧）= **0**。`listedRows/Cols` = 24×80。

⇒ 与 r18 一致、且现在有真 subscribe：**不是「subscribe/attach 就会坏」，是「resize 撞进注入窗口才会坏」。** 本 PR 的 fit 像素锁让注入窗口里不再打 resize，subscribe 档与对照同档。

## 仍不是根治

grouped `new-session -t` 在 daemon。write_paths 仍不含 `_night/BACKLOG-UPSTREAM.md`。息屏仍挂着的小客户端同前。

## 棘轮

产品码相对 r18 无新改。`npm test` 仍 **101/0**（本轮未重跑；r18 TAP 仍在）。

---

verdict: pass（真 WS subscribe 20/20 = 对照）；机制坏态仍是 r18 resize-between
