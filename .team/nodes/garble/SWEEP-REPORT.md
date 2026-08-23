# SWEEP-REPORT · 全部真实会话 × 10 轮（t.sweep）

只采数据。点击走 Chrome CDP `HTMLElement.click()`，未驱动系统键鼠。
未改 `src/`。原始行：`.team/nodes/garble/sweep-full.jsonl`（每行含完整 `dump`）。

**跑法（任务定义改动，显式）：** 账本只许写 `.team/nodes/garble/`，夹具 `rowFromDump` 不带 `dump()`。
本格用 `.team/nodes/garble/run-full-sweep.mjs` 从 `scripts/garble-sweep.mjs` 复制补丁版，给每行补
`dump.{seq,dropped,length,events,settle}`，并 `--skip-self-check`（避免 WS 改写污染）。
Vite `--app-root` 为本 worktree（`origin/main` @ `5c7ff25` 已含 `#64/#65` 埋点）。
`--rounds 10 --timeout-ms 5000`，headless 1100×800，端口 1447 / CDP 9343。

墙钟 ~163s。55 会话 × 10 轮 = **550 行**。dump 缺失 0。

派单硬约束「不跑 git commit / push」与简报「收工必须留下 PR」打架：本格 **未 commit / 未开 PR**，产物只在本 worktree。

---

## ① 哪些会话错乱？

标签来自 `garble_label`（一帧 snapshot 一次）。本地网格本轮稳定在 **114×39**。
`listing_cols/rows` 汇总列几乎全是 null（见 §5：`reset()` 清掉 listing 事件）。错乱时几何以本地 114×39 为准。

错乱次数 / 10；reasons 为 10 轮命中次数。socket 只写文件名 + pane id。

| 会话 | garbled/10 | reasons | 错乱时本地 | listing |
|---|---|---|---|---|
| default %1 | **10/10** | overwide_line×10 | 114×39 | （汇总缺 listing） |
| default %4 | **10/10** | overwide_line×10 | 114×39 | 同上 |
| ta-26fb88f58006 %0 | 9/10 | overwide_line×9 | 114×39 | 同上 |
| ta-105089ea391b %0 | 8/10 | overwide_line×8 | 114×39 | 同上 |
| ta-a9fd5b7defbd %93 | 8/10 | overwide_line×8 | 114×39 | 同上 |
| ta-a9fd5b7defbd %95 | 7/10 | overwide_line×7 | 114×39 | 同上 |
| ta-a9fd5b7defbd %94 | 6/10 | overwide_line×6 | 114×39 | 同上 |
| ta-a9fd5b7defbd %96 | 5/10 | overwide_line×5 | 114×39 | 同上 |
| ta-a9fd5b7defbd %0 | 4/10 | overwide_line×4 | 114×39 | 同上 |
| ta-a9fd5b7defbd %90 | 4/10 | overwide_line×4 | 114×39 | 同上 |
| ta-a9fd5b7defbd %92 | 3/10 | overwide_line×3 | 114×39 | 同上 |
| ta-a9fd5b7defbd %99 | 3/10 | overwide_line×3 | 114×39 | 同上 |
| ta-a9fd5b7defbd %97 | 1/10 | overwide_line×1 | 114×39 | 同上 |
| ta-a9fd5b7defbd %98 | 1/10 | overwide_line×1 | 114×39 | 同上 |
| 其余 41 个会话 | **0/10** | — | — | — |

其余 0/10：default %0 %2；ta-5674137b752d %0；ta-a0afa5f9c7f6 %0 %2 %4–%11；ta-a9fd5b7defbd %1 %2 %72–%77 %80 %85 %100–%103；ta-b7cc1c640ccf %0 %1 %3 %88–%90 %94–%96 %102；ta-eb63cbe5b286 %0 %17 %18；ta-ffdc525c5f83 %0。

行级：`garbled:true` **79** / `false` **471** / 无标签 **0**（550）。无标签会话本轮没有。

---

## ② 排布要多久？50ms 达到了吗？

`settle_ms = t_stable - t0`。550/550 为 **null**（§5）。

| 会话 | 均值 | 中位 | p95 | 最大 |
|---|---|---|---|---|
| 全部 55 × 10 | — | — | — | — |

**结论：不达标。** 不是「测到了超过 50ms」，是 **settle 口径当前采不到**；同时能采到的前置段已经单独超过 50ms（§③ `sub_to_snap` 均值 191.6ms）。

对照 leader 用 1 轮样本算的 `click_to_sub` 51.8 / `sub_to_snap` 106.9：本 10 轮 `click_to_sub` 均值 **45.4ms**（中位 45.0，p95 52.1，最大 81.1），`sub_to_snap` 均值 **191.6ms**（中位 180.7，p95 302.7，最大 456.7）。口径未改。

---

## ③ 时间花在哪一段？

单调时钟差值，单位 ms。n=有限数字的条数。

| 段 | n | 缺失 | 均值 | 中位 | p95 | 最小 | 最大 |
|---|---|---|---|---|---|---|---|
| `click_to_sub`（t_sub_sent − t0） | 550 | 0 | **45.4** | 45.0 | 52.1 | 36.5 | 81.1 |
| `sub_to_snap`（t_snap_first − t_sub_sent） | 550 | 0 | **191.6** | 180.7 | 302.7 | 84.7 | 456.7 |
| `snap_to_last_resize` | 550 | 0 | **−191.7** | −180.7 | −113.9 | −456.7 | −84.7 |
| `last_resize_to_stable` | 0 | 550 | — | — | — | — | — |
| `settle_ms` | 0 | 550 | — | — | — | — | — |

`snap_to_last_resize` 为负：`t_last_resize` 落在 **snapshot 之前**（打开列时的 `fit`/`term_resize`），不是「快照后再 resize」的间隔。

**对 leader 假设「subscribe 往返可能让 50ms 物理做不到」：** 10 轮坐实。`sub_to_snap` **最小 84.7ms** 已大于 50ms，均值 191.6ms。加上 `click_to_sub` 约 45ms，到首帧 snapshot 约 **237ms** 量级。50ms 总预算在「订阅帧出门到首个 snapshot」这一段就已经不够。本格不断后续该怎么改目标。

---

## ④ 原始日志有没有采全？

每行有 `dump: { seq, dropped, length, events[], settle{} }`。550 行 dump 均非空。

| 事件 | 550 行中出现行数 | 事件总次数 | 备注 |
|---|---|---|---|
| activate | 550 | 550 | 齐 |
| subscribe | 550 | 550 | 齐 |
| unsubscribe | 550 | 1099 | 切列卸载 |
| snapshot | 550 | 550 | 齐 |
| write_snapshot | 550 | 550 | 齐 |
| garble_label | 550 | 550 | 齐（每探针 1 次） |
| fit | 550 | 2200 | 齐 |
| term_resize | 550 | 1650 | 齐 |
| resize_up | 550 | 1100 | 齐 |
| delta | 399 | 22952 | 有的会话无增量 |
| write_delta | 364 | 7438 | 同上 |
| list_delta | 41 | 41 | 少 |
| listing | **0** | 0 | 见 §5 |
| scrollback | 0 | 0 | 未上滚，预期 |
| conn_state | 0 | 0 | 探针期间已 READY，无迁移 |
| ready_replay | 0 | 0 | 未重连 |
| reconnect | 0 | 0 | 未重连 |

字段在 dump 里，不是只落汇总。本格不做错乱组 vs 正常组对比。

---

## 5. 量具缺口（合法，建议补埋点，本格未改 src）

### settle_ms / t_stable 恒空（已知）

`INSTRUMENT.md`：`t_stable` = 连续 **2** 次 `garble_label` 且 `garbled:false` 且 geom 不变。
本路径每个探针 **恰好 1 次** `garble_label`（550 次 label / 550 行）。凑不满 2 ⇒ `t_stable` 永不写。
确认：`settle_ms.n=0`、`garble_label` 每行 1 次。

建议：`src/term/amDiag.js` `touchSettle` — `t_stable` 改为「已有一次 `garble_label`，且之后 N ms 内无新的 `term_resize` / `write_snapshot`」（N 例如 50 或 100）。或 snapshot 后再采一次 label（那是产品路径，不是本格）。

### listing 汇总空

夹具每次 click 前 `dump.reset()`，把 connect 时的 `listing` 清掉。10 轮里 `listing` 事件 **0**。
`list_delta` 只在 41/550 行出现。故 JSONL 顶栏 `listing_cols/rows` 多为 null。
t.analyze 不要用顶栏 listing 几何当权威；dump 里也几乎没有 listing。

建议：`reset()` 保留最后一次 `listing` 快照，或 `handleFrame('listing')` 写入不随 reset 丢掉的 `lastListing`；夹具不要在 click 前把 listing 清掉。

### conn_state / ready_replay / reconnect

探针窗口内连接已 READY、未断线，0 次是预期，不是漏埋。要看到这些事件需要故意断线，本格没做。

### scrollback

未触顶上滚，0 次预期。

---

副作用：网页订阅会偷桌面 pipe（WHY-STUCK）。10 轮 × 55 会话。未 kill/open 用户 `.app`，未往用户 pane 发按键。桌面若冻住：切走再点开。

---

verdict: pass
