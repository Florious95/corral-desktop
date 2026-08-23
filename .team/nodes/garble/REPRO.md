# REPRO · t.repro（ledger.garble-truthsource-r3 t.repro r1）

工作树：`.worktrees/wt-repro`（`feat/garble-repro-r1`）。基线 `origin/main` = `11cdff3`（#70 ROOTCAUSE-2）。

**派单 vs 简报：** 派单写「不跑 git commit / push」。简报 §5 与席位纪律 §3 写明那是编排缺口、以简报为准。本格 **按简报 commit + push + `gh pr create`**，不 merge。

**本格未改任务定义的部分：** 2×2 全跑了；未修错乱；未碰用户 tmux / :9900；token 未入产物。

**必须显式报的缺口：** 简报判据 b 要 **A 红且 B 绿**。受控台上 **B 绿、A 不红**（见 §3）。按简报 §3d 这是合法终态，末行 `unjudgeable`，⛔ 未把标注器改严来硬凑 A 红。

---

## 一行复现命令

```
cd /Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-repro && node .team/nodes/garble/run-repro.mjs
```

（worktree 需能 `import` 到仓根 `node_modules/ws`。独立 socket `/tmp/tmux-501/amr`，listen 从 19971 起找空闲口，⛔ 不杀占用者。daemon 从只读上游 `go build` 到本格 `bin/agentmirrord-repro`，token 一次性、只走 env。）

夹具（可一字不差复现，不是用户 pane 正文）：

| 名 | 字节定义 | displayWidth @ 标注器 |
|---|---|---:|
| CJK | 113 个 ASCII `x` + U+4E2D `中` | **115**（宽字符跨 114/115 列） |
| ASCII | 114 个 ASCII `x` | **114** |

Pane 进程是本格 `grok-stub.c` 编出来的名为 `grok` 的 echo 进程（macOS 上 `cp /bin/bash` 会因签名立刻退出；`exec -a grok` 的 `ps comm=` 仍是 bash，过不了白名单）。不是真 Agent CLI。

---

## 2×2 读数（WS 订阅 39×114 + `detectGarble`）

源：`.team/nodes/garble/repro-run.json`（无 token、无 pane 正文）。

| # | 设定主机宽 | 内容 | 订前 tmux `#{pane_width}` | capture-pane 订前 mlw（标注器 @114） | WS snapshot mlw | overwide_lines | garbled | host_cols（订前 listing） | host_cols_live | host_cols_at_snap | 订后 `#{pane_width}` |
|---|---:|---|---:|---:|---:|---:|---|---:|---:|---:|---:|
| A | 235 | CJK | 235 | **115**（若按 114 标会红） | **113** | 0 | **false** | 235 | null | null | **114** |
| B | 235 | ASCII | 235 | 114（绿） | **114** | 0 | **false** | 235 | 235 | 235 | **114** |
| C | 114 | CJK | 114 | 115（`-J` 把折行拼回） | **113** | 0 | **false** | 114 | 114 | 114 | 114 |
| D | 137 | CJK | 137 | 115 | **113** | 0 | **false** | 137 | 137 | 137 | **114** |

`n_lines_width_eq_cols` / `n_lines_width_cols_plus_1`：A/C/D 订后快照均为 0/0；B 为 2/0。

---

## 因果（A 为什么不红）

1. **订前**，A 在 235 列主机上，CJK 行就是 115 宽（capture mlw=115）。这证明夹具打到了「宽字符跨 114/115」。
2. **一订阅 114**，本格 daemon 把四格 pane **都拉到 114**（`#{pane_width}` 证据）。快照里的 CJK 行变成 mlw=113（折行后首行 113 个 `x`，`中` 落到下一行）。标注器 @114 ⇒ 不 overwide ⇒ **绿**。
3. 因此：**在真实 subscribe 路径上，A 的「mlw=115 快照」复现不出来。** 不是夹具没灌进去，是 overlay 先 reshape 再出 snapshot。这与 r2「巡检 114 订阅读不到用户那种没被改窄的主机」同构，只是这次自变量是我们自己的 pane。
4. **B 绿成立**（ASCII 114，订后 snapshot mlw=114，`garbled=false`）。缺的是 A 红，构不成「宽字符跨边界 ⇒ 错乱」的 2×2 因果。
5. **C/D：** 订后快照与 A 一样 mlw=113、绿。宽度效应在 WS 路径上被 reshape **抹平**。C 的订前 capture mlw=115 来自 `capture-pane -J` 拼接，不能当成「114 列主机仍发出 115 宽单行」。

`host_cols_live`：单测证明「订阅后 listing 若带新 cols，stamp 用新值不用点击前缓存」。真 daemon 上 **listing 仍报订前宽**（B live=235 而 pane 已 114；D live=137 而 pane 已 114）。A 这一格甚至没等到含该 ref 的 post-sub listing（live=null）。**tmux 已经 114，listing 没跟上** —— 这正是 r2 要的那一问，答案是：reshape 发生了，但 listing 字段在订阅后 800ms 内仍是旧值。

---

## 埋点（判据 c）

| 项 | 状态 |
|---|---|
| `amDiag.recordLiveHostGeom` / `stampHostAtSnap` → `host_cols_live` `host_cols_at_snap` | 落地；只在 `markSubscribed` 之后的 listing/list_delta 写入 |
| `garble_label` 增加 `n_lines_width_eq_cols` `n_lines_width_cols_plus_1` `host_cols_live` | 落地 |
| `npm test` | **123** 绿（棘轮 ≥120） |

⛔ 未改 `detectGarble` 阈值、未修错乱。

---

## 判据对账

| # | 结果 |
|---|---|
| a | REPRO.md 四格都有 mlw / overwide_lines / host_cols_live |
| b | **未满足**（A 不红；B 绿；一行命令见上） |
| c | 埋点 + `npm test` 123 |
| d | A 在 WS 路径上复现不出 mlw=115，按本节如实记录 |

verdict: unjudgeable
