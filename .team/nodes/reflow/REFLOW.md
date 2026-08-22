# REFLOW.md · t.reflow-fix r26

**worktree** `/Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-reflow`  
**分支** `feat/reflow-defer-grid`  
未 HID；未碰上游；未放宽 CSP。未并入 PR #51 像素锁（本格只推迟本地 `term.resize`，两件事分开）。

## 假说（读数二选一）

脚本：`test/reflow-switch.test.js`，n=**30** 次 `clientWidth` 800↔400（间隔 40ms，&lt;120ms 与落定档都有）。FakeTerminal：缩列再拉回则 `torn=true`。cell 探针与 `term.cols*8` 同步。

| 假说 | 结论 | 读数 |
|---|---|---|
| **H1** `_cell()` 过渡第三档 cols | **不成立** | 算出的 cols 只有 100 或 50，`midCols=0` |
| **H2** 本地立刻 reflow + 回到原几何不上报/daemon no-op | **成立** | `fit({immediate:true})`（修前 ResizeObserver 同拍）：`torn=true`（30/30 路径都会缩再涨）；落定后上报 `25×100` = 打开时的几何 ⇒ daemon `resize no-op` 不补 snapshot。与用户「切走再订回才好」（重新 subscribe 才有新快照）一致 |

## 坏态 / 好态

| | n | torn | 本地 `term.resize` 次数 | 落定后 `onResize` |
|---|---|---|---|---|
| 坏：immediate fit（修前） | 30 | **30 次路径会撕**（`torn=true`） | 往返多次 | `[25,100]`（对主机是 no-op） |
| 好：默认 `fit()`（修后） | 30 | **0** | **0** | **[]** |

真正改宽并稳住：400px 停住 → 120ms 后一次 `50` 列 + 一次 `onResize [25,50]`（会走真 resize，主机补快照）。

## 修法

首帧立刻 `term.resize`。之后目标格子 **120ms 落定**再 `term.resize`；若抖回当前格子则**取消**，本地从不 reflow。

不能只靠原来的 `_report` debounce：它合并后仍可能上报**原来的** rows×cols，主机 no-op，快照不来，错乱钉死。本地也不先 resize，旧内容就不会按过渡宽度折行。

## 任务定义

简报写 Chrome 里点列切换。切列的有效刺激是 **列宽变 → `fit()`**。本格用同一刺激的脚本夹具（不抢鼠标、不起用户 `.app`）。未静默改判据：n=30、失败次数、修后 0 都在表里。

`npm test` **106/0**（棘轮 103）。UI-SPEC §6.2 + §11.17，裁定 2026-08-23。

verdict: pass
