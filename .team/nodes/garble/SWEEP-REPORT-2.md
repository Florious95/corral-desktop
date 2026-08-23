# SWEEP-REPORT-2 · 全部真实会话 × 10 轮（t.sweep2，带 t.deepen 新埋点）

只采数据。点击走 Chrome CDP `HTMLElement.click()`，未驱动系统键鼠。未改 `src/`。
原始行：`.team/nodes/garble/sweep-full-2.jsonl`（每行含完整 `dump` + 汇总列）。

## 任务定义改动（显式）

1. **产物文件名**按本回合账本/派单：`SWEEP-REPORT-2.md` / `sweep-full-2.jsonl`（不是简报里的 `SWEEP-REPORT.md` / `sweep-full.jsonl`，以免覆盖 r1）。
2. **`origin/main` = `48a62b9`（#67）不含新埋点**。#68 `feat/garble-deepen-r1` 仍 OPEN。Vite `--app-root` 指向 `.worktrees/wt-deepen`（含 `host_cols` 缓存、`SETTLE_QUIET_MS=100`、`max_line_chars`）。本树 write_paths 没有 `src/`，不能把 #68 合进来。
3. 夹具 `probeOne` 在看到 snapshot+`garble_label` 后 **多等 120ms 再 dump**（只改本目录 `_sweep2-patched.mjs`，未改仓内 `scripts/`）。否则 `t_stable` 仍会在静默窗填上之前被采走。
4. 派单「不跑 git commit / push」与简报「收工必须留下 PR」打架：本格 **按派单：不 commit、不开 PR**。产物只在 `wt-r2scan/.team/nodes/garble/`。

跑法：`node .team/nodes/garble/run-full-sweep-2.mjs`。`--rounds 10 --timeout-ms 5000 --skip-self-check`，headless，端口偏好 1457 / CDP 9353（占用则换）。墙钟 **185s**。55 会话 × 10 轮 = **550 行**。dump 缺失 0。token 字段命中 0。

配对：tauri store `set`-式读入脚本，未打印。

---

## ① 哪些会话错乱？

标签来自 `garble_label`。本地网格本轮稳定 **114×39**。
主机几何来自 subscribe 上的 `host_rows`/`host_cols`（listing 缓存，活过 `reset()`），**550/550 有值**。错乱行的 `max_line_width` **全部 = 115**，`max_line_has_wide` **75/75 true**，`max_line_chars` 61–96。

| 会话 | garbled/10 | reasons | 错乱时本地 | host listing |
|---|---|---|---|---|
| default %1 | **10/10** | overwide_line×10 | 114×39 | 235×50 |
| default %4 | **10/10** | overwide_line×10 | 114×39 | 235×50 |
| ta-a0afa5f9c7f6 %0 | 6/10 | overwide_line×6 | 114×39 | 235×50 |
| ta-a9fd5b7defbd %93 | 6/10 | overwide_line×6 | 114×39 | 235×50 |
| ta-b7cc1c640ccf %0 | 6/10 | overwide_line×6 | 114×39 | 235×50 |
| ta-105089ea391b %0 | 5/10 | overwide_line×5 | 114×39 | 235×50 |
| ta-a9fd5b7defbd %92 | 5/10 | overwide_line×5 | 114×39 | 235×50 |
| ta-a9fd5b7defbd %99 | 5/10 | overwide_line×5 | 114×39 | 235×50 |
| ta-a9fd5b7defbd %90 | 4/10 | overwide_line×4 | 114×39 | 235×50 |
| ta-a9fd5b7defbd %95 | 4/10 | overwide_line×4 | 114×39 | 235×50 |
| ta-a9fd5b7defbd %98 | 4/10 | overwide_line×4 | 114×39 | 235×50 |
| ta-a9fd5b7defbd %94 | 3/10 | overwide_line×3 | 114×39 | 235×50 |
| ta-26fb88f58006 %0 | 2/10 | overwide_line×2 | 114×39 | 235×50 |
| ta-a9fd5b7defbd %96 | 2/10 | overwide_line×2 | 114×39 | 235×50 |
| ta-eb63cbe5b286 %0 | 2/10 | overwide_line×2 | 114×39 | 235×50 |
| ta-a9fd5b7defbd %97 | 1/10 | overwide_line×1 | 114×39 | 235×50 |
| 其余 39 个会话 | **0/10** | — | 114×39 | 见下（不全是 235） |

0/10：default %0 %2；ta-5674137b752d %0；ta-a0afa5f9c7f6 %2 %4–%11；ta-a9fd5b7defbd %0 %1 %2 %72–%77 %80 %85 %100–%103；ta-b7cc1c640ccf %1 %3 %88–%90 %94–%96 %102；ta-eb63cbe5b286 %17 %21；ta-ffdc525c5f83 %0。

行级：`garbled:true` **75** / `false` **475** / 无标签 **0**。`timed_out` **0/550**（与 r1 口径不同：r1 把 `t_stable==null` 算超时）。

host_cols 全局：235×480 行，80×40，137/140/142 各 10。⛔ 本格不做「235 是否分开错乱组」的结论。

---

## ② 排布要多久？50ms 达到了吗？

`settle_ms = t_stable − t0`。新口径：一次 `garble_label` 后 100ms 无 `term_resize`/`write_snapshot`。本轮夹具在 label 后再等 120ms 再 dump。**550/550 有值**。

| 范围 | n | 均值 | 中位 | p95 | 最小 | 最大 |
|---|---:|---:|---:|---:|---:|---:|
| 全部 55 × 10 | 550 | **245.9** | 240.8 | 290.5 | 211.5 | 385.0 |

逐会话（10 次）：

| 会话 | garbled/10 | 均值 | 中位 | p95 | 最大 | host |
|---|---:|---:|---:|---:|---:|---|
| default %1 | 10/10 | 271.8 | 268.2 | 332.5 | 332.5 | 235×50 |
| default %4 | 10/10 | 257.7 | 257.2 | 284.3 | 284.3 | 235×50 |
| ta-a0afa5f9c7f6 %0 | 6/10 | 256.7 | 254.9 | 298.6 | 298.6 | 235×50 |
| ta-a9fd5b7defbd %93 | 6/10 | 269.7 | 263.0 | 327.7 | 327.7 | 235×50 |
| ta-b7cc1c640ccf %0 | 6/10 | 253.8 | 263.3 | 277.8 | 277.8 | 235×50 |
| ta-105089ea391b %0 | 5/10 | 248.8 | 246.8 | 288.4 | 288.4 | 235×50 |
| ta-a9fd5b7defbd %92 | 5/10 | 240.4 | 240.8 | 257.1 | 257.1 | 235×50 |
| ta-a9fd5b7defbd %99 | 5/10 | 250.3 | 251.7 | 277.0 | 277.0 | 235×50 |
| ta-a9fd5b7defbd %90 | 4/10 | 264.7 | 262.7 | 298.5 | 298.5 | 235×50 |
| ta-a9fd5b7defbd %95 | 4/10 | 248.8 | 250.2 | 308.0 | 308.0 | 235×50 |
| ta-a9fd5b7defbd %98 | 4/10 | 231.0 | 228.2 | 252.9 | 252.9 | 235×50 |
| ta-a9fd5b7defbd %94 | 3/10 | 265.5 | 258.2 | 311.8 | 311.8 | 235×50 |
| ta-26fb88f58006 %0 | 2/10 | 243.3 | 248.3 | 270.8 | 270.8 | 235×50 |
| ta-a9fd5b7defbd %96 | 2/10 | 244.7 | 255.7 | 264.8 | 264.8 | 235×50 |
| ta-eb63cbe5b286 %0 | 2/10 | 250.2 | 249.9 | 261.4 | 261.4 | 235×50 |
| ta-a9fd5b7defbd %97 | 1/10 | 240.1 | 236.2 | 268.2 | 268.2 | 235×50 |
| default %0 | 0/10 | 233.4 | 231.7 | 251.0 | 251.0 | 235×48 |
| default %2 | 0/10 | 243.1 | 230.3 | 350.8 | 350.8 | 80×24 |
| ta-5674137b752d %0 | 0/10 | 236.4 | 242.6 | 259.1 | 259.1 | 140×40 |
| ta-a0afa5f9c7f6 %10 | 0/10 | 250.5 | 249.1 | 281.4 | 281.4 | 235×50 |
| ta-a0afa5f9c7f6 %11 | 0/10 | 232.9 | 229.3 | 261.3 | 261.3 | 80×24 |
| ta-a0afa5f9c7f6 %2 | 0/10 | 243.0 | 241.3 | 264.4 | 264.4 | 235×50 |
| ta-a0afa5f9c7f6 %4 | 0/10 | 252.6 | 241.8 | 318.5 | 318.5 | 235×50 |
| ta-a0afa5f9c7f6 %5 | 0/10 | 322.2 | 325.5 | 385.0 | 385.0 | 235×50 |
| ta-a0afa5f9c7f6 %6 | 0/10 | 252.5 | 248.0 | 279.5 | 279.5 | 235×50 |
| ta-a0afa5f9c7f6 %7 | 0/10 | 231.5 | 224.4 | 263.2 | 263.2 | 235×50 |
| ta-a0afa5f9c7f6 %8 | 0/10 | 230.7 | 232.8 | 240.8 | 240.8 | 235×50 |
| ta-a0afa5f9c7f6 %9 | 0/10 | 242.6 | 238.6 | 304.8 | 304.8 | 235×50 |
| ta-a9fd5b7defbd %0 | 0/10 | 248.8 | 237.7 | 356.7 | 356.7 | 142×42 |
| ta-a9fd5b7defbd %1 | 0/10 | 229.3 | 231.7 | 241.1 | 241.1 | 235×50 |
| ta-a9fd5b7defbd %100 | 0/10 | 249.3 | 246.1 | 290.5 | 290.5 | 235×50 |
| ta-a9fd5b7defbd %101 | 0/10 | 242.5 | 243.9 | 261.4 | 261.4 | 235×50 |
| ta-a9fd5b7defbd %102 | 0/10 | 239.9 | 243.4 | 275.2 | 275.2 | 235×50 |
| ta-a9fd5b7defbd %103 | 0/10 | 244.3 | 241.8 | 274.0 | 274.0 | 235×50 |
| ta-a9fd5b7defbd %2 | 0/10 | 237.7 | 241.5 | 257.6 | 257.6 | 235×50 |
| ta-a9fd5b7defbd %72 | 0/10 | 227.0 | 224.6 | 246.8 | 246.8 | 235×50 |
| ta-a9fd5b7defbd %73 | 0/10 | 233.9 | 231.1 | 263.5 | 263.5 | 235×50 |
| ta-a9fd5b7defbd %74 | 0/10 | 236.2 | 236.2 | 251.6 | 251.6 | 235×50 |
| ta-a9fd5b7defbd %75 | 0/10 | 228.1 | 232.2 | 238.8 | 238.8 | 137×42 |
| ta-a9fd5b7defbd %76 | 0/10 | 235.9 | 234.7 | 257.6 | 257.6 | 235×50 |
| ta-a9fd5b7defbd %77 | 0/10 | 239.9 | 238.3 | 255.5 | 255.5 | 235×50 |
| ta-a9fd5b7defbd %80 | 0/10 | 230.8 | 231.3 | 240.6 | 240.6 | 235×50 |
| ta-a9fd5b7defbd %85 | 0/10 | 242.2 | 240.7 | 267.7 | 267.7 | 235×50 |
| ta-b7cc1c640ccf %1 | 0/10 | 248.9 | 248.6 | 285.1 | 285.1 | 80×24 |
| ta-b7cc1c640ccf %102 | 0/10 | 241.7 | 243.3 | 261.2 | 261.2 | 235×50 |
| ta-b7cc1c640ccf %3 | 0/10 | 242.6 | 244.2 | 249.8 | 249.8 | 235×50 |
| ta-b7cc1c640ccf %88 | 0/10 | 253.0 | 253.9 | 268.2 | 268.2 | 235×50 |
| ta-b7cc1c640ccf %89 | 0/10 | 233.0 | 237.3 | 250.1 | 250.1 | 235×50 |
| ta-b7cc1c640ccf %90 | 0/10 | 241.3 | 238.1 | 275.1 | 275.1 | 235×50 |
| ta-b7cc1c640ccf %94 | 0/10 | 245.8 | 241.7 | 310.2 | 310.2 | 235×50 |
| ta-b7cc1c640ccf %95 | 0/10 | 228.9 | 224.0 | 257.1 | 257.1 | 235×50 |
| ta-b7cc1c640ccf %96 | 0/10 | 232.5 | 233.1 | 248.8 | 248.8 | 235×50 |
| ta-eb63cbe5b286 %17 | 0/10 | 250.1 | 248.2 | 272.9 | 272.9 | 235×50 |
| ta-eb63cbe5b286 %21 | 0/10 | 241.8 | 239.2 | 277.1 | 277.1 | 80×24 |
| ta-ffdc525c5f83 %0 | 0/10 | 289.2 | 290.5 | 370.0 | 370.0 | 235×50 |

**结论：不达标。** 最小 `settle_ms` **211.5ms > 50ms**。口径未改成「去掉静默窗」——100ms 是定义的一部分；即便扣掉这 100ms，均值仍约 146ms，仍大于 50。

---

## ③ 时间花在哪一段？

单调时钟差值，单位 ms。n=有限数字的条数。

| 段 | n | 缺失 | 均值 | 中位 | p95 | 最小 | 最大 |
|---|---:|---:|---:|---:|---:|---:|---:|
| `click_to_sub` | 550 | 0 | **42.6** | 42.3 | 48.0 | 35.6 | 85.8 |
| `sub_to_snap` | 550 | 0 | **102.9** | 97.4 | 146.5 | **73.9** | 232.8 |
| `snap_to_last_resize` | 550 | 0 | **−102.9** | −97.4 | −80.3 | −232.9 | −73.9 |
| `last_resize_to_stable` | 550 | 0 | **203.3** | 197.8 | 246.8 | 174.4 | 333.4 |
| `settle_ms` | 550 | 0 | **245.9** | 240.8 | 290.5 | 211.5 | 385.0 |

`snap_to_last_resize` 仍为负：末次 `term_resize` 在 snapshot **之前**（打开时 fit）。因此 `last_resize_to_stable` 含「resize → 订阅往返 → 快照 → 100ms 静默」，不是「画完后再排」的纯客户端段。

**对 leader 假设「subscribe 往返让 50ms 物理做不到」：** 本 10 轮再次坐实。`sub_to_snap` **最小 73.9ms > 50ms**，均值 102.9ms。加上 `click_to_sub` ~43ms，到首帧已 ~146ms，再加定义上的 100ms 静默 → settle ~246ms。本格不断后续怎么改目标。

对照 r1（settle 全 null）：当时 `sub_to_snap` 均值 191.6 / 最小 84.7。本轮往返短一些，量级仍是百毫秒，不是 50。

---

## ④ 原始日志是否采全？

每行 `dump.{seq,dropped,length,events,settle}`。550 行 dump 齐。`garble_label` 550；`subscribe` 550 且 **550 带 `host_rows/cols/listing_seq`**；`max_line_chars`/`max_line_has_wide` 550。

本轮事件计数（全 550 次探针合计）：

| type | 次数 |
|---|---:|
| activate | 550 |
| subscribe | 550 |
| unsubscribe | 1099 |
| snapshot | 550 |
| write_snapshot | 550 |
| garble_label | 550 |
| fit | 2200 |
| term_resize | 1650 |
| resize_up | 1100 |
| delta | 37229 |
| write_delta | 34341 |
| list_delta | 56 |
| listing | **0** |
| scrollback | 0 |
| conn_state | 0 |
| ready_replay | 0 |
| reconnect | 0 |

---

## ⑤ 仍缺 / 新埋点是否打上

| 埋点 | 本轮 | 怎么确认 |
|---|---|---|
| `subscribe.host_cols` | **550/550** | 每行 dump 里 sent subscribe 都有 `host_cols`（例：本地订 114，host 80 或 235） |
| `listing` 事件 | **0** | `reset()` 仍清环；探针窗口内没再来全量 listing。被 host 缓存替代 |
| `list_delta` | 56 | 少数探针窗口内扫到增量，不是每行都有 |
| `garble_label.max_line_chars/has_wide` | **550/550** | 错乱 75 条 has_wide=true、mlw=115 |
| `t_stable` / `settle_ms` | **550/550** | 新静默窗 + 夹具多等 120ms |
| `conn_state` / `ready_replay` / `reconnect` | 0 | 本轮连接未掉 |
| `scrollback` | 0 | 未滚到顶拉历史 |

建议（只记账，本格不改码）：`listing` 全量帧仍进不了探针窗口的话，分析应优先用 `subscribe.host_*`，不要再等环里的 `listing` 事件。

副作用：网页 subscribe 会偷桌面端 pipe（WHY-STUCK）。点了 55 会话 × 10 轮。未 kill/open 用户 AgentMirror。若某列冻住：桌面里切走再点开。

verdict: pass
