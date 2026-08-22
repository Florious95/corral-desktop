# GEOM-FIX.md · t.geom-fix r32

**worktree** `/Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-geom`  
未碰 `tester-t146` / `多agent协作`。未读 `.env`。一次性 token 只进子进程。未 HID。未改上游。未 `kill-server`（只 `kill-session -t amgeom`）。

派单写了「不跑 git commit/push」；席位纪律 §三与 BRIEF 授权在本 worktree 分支上 `commit`/`push`/`gh pr create`。按纪律做 PR，不 merge。

## 改了什么

`TerminalView.fit()`：正宽高才算真实视口；**第一次**换算 rows/cols、`term.resize`、上抛 `onResize`。0×0 不算。此后只 `_squeeze`（`overflow:auto`、滚到底行），格子锁死。

`Client.resize` 若该 ref 已订阅，写入 `activeSubscriptions`，重连 `replaySubscriptions` 带**最新** cols，不是第一次 subscribe。

## 与 PR #51 / #53

#51 像素锁、#53 延迟本地 `term.resize`：方向是「少发」，本格是「不发」。debounce 网格提交路径已删。`GRID_DEBOUNCE_MS` 只还管**首次** `_report()` 的 120ms。未删测试：改写了

- `terminal.test.js`：「连续 fit 合并成最终几何」→「n=30 之后仍恰好 1 次上抛、窄了不折列」
- `reflow-switch.test.js`：immediate 撕开 / 落定后仍 resize → 锁格后不撕、落定变窄也不 resize

新增：0×0 不算 seed；reconnect 重放 latest cols。棘轮 **108**（基线 106）。

## 两头夹住（n=30）

探针 `.team/nodes/geom/probe-geom.mjs` → `geom-probe.json`。

| 态 | 上抛 resize 次数 |
|---|---|
| **坏（legacy 每次 fit 重算）** | **31**（>1） |
| **好（现 TerminalView）** | **1**（恰好首次） |

不倒退（DOM/假容器读数）：修后 `term.cols` 锁 100；窄到 640px `overflow:auto`、`overflowX:true`；`visibleRows` 仍按像素算，格子行数不变。

## 主机不被扰动

自建 `amgeom` + 本机 `agentmirrord:19924`。`subscribe` 一次：pane **80×24 → 100×25**。随后 n=30 `fit` 切 400↔800：`#{pane_width}×#{pane_height}` **unique = [100x25]**。协议 `resize` 帧 **0**。

## 文档

同 PR：`docs/UI-SPEC.md` §6.2 / §11.17、`docs/CLIENT-CONTRACT.md` §1.3 / §3.4。裁定 2026-08-23。

verdict: pass
