# GEOM-FIX.md · t.geom-fix r32 + r34

**worktree** `/Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-geom`  
未读 `.env`。一次性 token 只进子进程。未 HID。未改上游。未 kill 用户 `:9900`。未往 `%88` 注入 input / keys / Ctrl+L / send-keys / paste。

Chrome DevTools MCP：**本席只有 `team_orchestrator`，不可用**。真机判据用自建 `agentmirrord`（空闲端口）+ 协议 subscribe + listing 快照折行量具（与网页打开同一 pane 的格子语义一致）。

派单写了「不跑 git commit/push」；席位纪律 §三与 BRIEF 授权在本 worktree 分支上 `commit`/`push`/`gh pr create`。按纪律做 PR，不 merge。

---

## r32（已 merge #54 `1e31ebf`）

`fit()` 首次正视口 seed 一次；此后窗口变化只 `_squeeze`。坏态 n=30 上抛 31 次 / 好态 1 次。自建台主机 unique 几何锁死。**这些只证明不再掰主机，不证明 `tester-t146` 画对。**

---

## r34 回炉

### 1. 现在错不错乱（修前，真机 `%88` / `tester-t146`）

量具：去 ANSI 后含 badge `tester-t146` 的**最长一行**，按 `paintCols` 折；`torn` = badge 不在视觉行 0 或该行视觉行数 > 1。

`live-t146-pre.json`（subscribe 匹配现场 235×50，**本地格子仍是窗口 seed 100**，#54 行为）：

| 量 | 值 |
|---|---|
| 主机 `#{pane_width}x#{pane_height}` | **235×50**（subscribe 前后不变） |
| listing / subscribe cols | **235** / 50 |
| 我方 `term.cols`（seed） | **100** |
| 顶栏行宽 | **235** cells；badge 起始列 **221** |
| wrap@100 | visualRows **3**，badge 视觉行 **2**，**torn: true** |
| wrap@235 | visualRows **1**，badge 视觉行 **0**，torn: false |

坏态红：235 字顶栏喂进 100 列画布必撕。

### 2. 同刻三个数（修前）

`pane_width=235`，`subscribe.cols=235`，`term.cols=100`。三者不一致就是错乱原因。

### 3. A/B/C（#54 vs 父提交）

未 checkout 父提交连真机（主树禁切；本 worktree 在 #54 提交上）。用同一帧快照做反事实：

| 画布 | 会得到的 cols | wrap torn |
|---|---|---|
| 典型 ~800px（cell 8px） | **100**（#54 锁死 seed；父提交 fit 也会到 ~100） | **true**（A：这幅画布两边都撕） |
| ~1880px | 父提交 fit ≈ **235** 可自愈；#54 **永远 100** | #54 **true** / 跟随 235 **false** |

⇒ **B 成立于「窗口不够宽、无法 fit 到主机宽度」**：#54 锁死 seed，**失去自愈**。A 在窄窗口上同时成立（父提交也会撕）。**未整条退 #54**：退掉会把窗口 `resize` 帧还给 daemon，又会嚼主机（r32 已证）。保留「窗口 fit 不发协议 resize」，改「本地格子跟随主机」。

### 4. 修法

- `subscribe(listing.rows, listing.cols)`，立刻 `followHostGrid`（本地 `term.resize`，**不上抛** `onResize` / **不发** `Client.resize`）。
- snapshot `inferHostCols`：仅当行宽 **大于** 当前 `term.cols` 时放大格子（短快照不得缩小）。
- `App` 不再把 pane `onResize` 接到 `dm.resize`（本来就没接）。`fit()` 仍只 seed/挤压。
- 未退 #54 测试。棘轮 **110**（基线 108；+`inferHostCols` / `writeSnapshot` 跟随）。

可行性读数：listing 已带 235；只读 `#{pane_width}` 同为 235；snapshot 最长行 235。三条同源。

### 5. 修后再连真机（同一组量具）

`live-t146-post.json`，`GEOM_FOLLOW=1`：

| 量 | 值 |
|---|---|
| 主机 | **235×50**（subscribe 后仍 235×50） |
| subscribe | **50×235** |
| `term.cols` | **235** |
| wrap@term.cols | hostLineCells **235**，badge 221，visualRow **0**，**torn: false** |
| wrap@100（对照） | 仍 **torn: true**（量具仍能检出坏态） |

探针：`.team/nodes/geom/probe-live-t146.mjs`。

文档同 PR：`docs/UI-SPEC.md` §6.2 / §11.17、`docs/CLIENT-CONTRACT.md` §1.3 / §3.4。裁定 2026-08-23 回炉。

verdict: pass
