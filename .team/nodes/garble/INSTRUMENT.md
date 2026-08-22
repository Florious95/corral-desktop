# INSTRUMENT · 几何/订阅真相源（t.inst）

默认开启。Chrome：`window.__amDiag.dump()`（`Runtime.evaluate`）。
环形缓冲容量 `16384`。事件含单调时钟 `t`、全局 `seq`、`ref`。⛔ 无 pane 正文、无 token。

---

## 1. 埋点清单

| 事件名 | 位置 | 字段 | 用来回答什么 |
|---|---|---|---|
| `activate` | `App.jsx` `openAgent` / `splitAgent` | `ref`, `t` | t0：用户点开会话。settle 的起点。 |
| `subscribe` | `client.js` `subscribe` / `replaySubscriptions` | `ref`, `rows`, `cols`, `sent`, `reason`（`not_ready_bookkept` / `replay` / `send_failed`） | 申报了什么几何？帧真的上路了吗？重连重放是否把旧尺寸又订回去？ |
| `unsubscribe` | `client.js` `unsubscribe` | `ref`, `sent`, `reason` | 订阅生命周期是否成对；退订后还在收 snapshot 就是偷管/死订阅。 |
| `listing` | `client.js` `handleFrame` listing | `listing_seq`, `panes[{ref,rows,cols}]` | 主机此刻报的几何。与最近 `subscribe.cols` 持续不一致 = 争用/死订阅。 |
| `list_delta` | `client.js` list_delta 成功应用后 | `listing_seq`, `panes[{ref,rows,cols}]`, `removed` | 几何是突变还是扫到的；removed 对上 unsubscribe 时间线。 |
| `snapshot` | `client.js` `handleMessage` 二进制 | `ref`, `kind=1`, `bytes`, `t` | t_snap_first；有没有快照、多重、相对 subscribe 的延迟（网络段）。 |
| `delta` | 同上 | `ref`, `kind=2`, `bytes` | 快照后是否还在流。死订阅 = 无后续帧。 |
| `scrollback` | 同上 | `ref`, `kind=3`, `bytes` | 与活屏几何无关，避免误算进 settle。 |
| `fit` | `TerminalView.fit` | `container_w/h`, `cols/rows`, `term_cols/rows`, `early_exit`（`not_connected`/`zero_px`/`grid_unchanged`/`null`）, `path`（`first`/`immediate`/`debounce`）, `will_resize`, `debounce_armed` | 算出的格子 vs 当前格子；早退是否吞掉了本该 resize 的一次；防抖窗口是否把 term.resize 推迟到 snapshot 之后。 |
| `term_resize` | `TerminalView._commitGrid` 真正调用 `term.resize` 前 | `from_cols/rows`, `to_cols/rows` | t_last_resize。本地网格何时变。snapshot 写在 resize 前还是后是错乱组的候选特征。 |
| `resize_up` | `client.js` `resize`；以及 `TerminalView._report` 的 `geom_unchanged` 早退 | `ref`, `rows`, `cols`, `sent`, `reason`（`not_ready`/`send_failed`/`geom_unchanged`/`null`） | 上行 resize 发了还是本地判未变 no-op。daemon 只在 before≠after 时补快照。 |
| `write_snapshot` | `TerminalView.writeSnapshot` | `t_reset`, `t_write`, `term_cols`, `term_rows`, `bytes` | reset/write 时刻与当时格子。宽字节进窄格子：看 `term_cols` vs 标注器 `max_line_width`。 |
| `write_delta` | `TerminalView.writeDelta` | `term_cols`, `bytes` | 增量是写在已对齐网格还是已折行网格上。 |
| `garble_label` | `TerminalPane` 收到 SNAPSHOT 后 | `garbled`, `reasons[]`, `overwide_lines`, `max_line_width`, `max_box_run`, `cup_clamped`, `geom` | **只打标签**。连续 not-garbled + 几何不变 → t_stable。分析根因禁止只用这一条。 |
| `conn_state` | `client.js` `setState` | `from`, `to` | READY 迁移、重连。replay 是否紧跟 READY。 |
| `ready_replay` | `replaySubscriptions` 入口 | `count` | 重连后重放了几个订阅。 |
| `reconnect` | `handleClose` 非永久关闭 | `reason` | 生命周期：丢连接 → 重放 subscribe。 |

取数：`JSON.stringify(window.__amDiag.dump())` → `{ events, settle, seq, dropped, length }`。
`settle[ref].segments`：`click_to_sub` / `sub_to_snap` / `snap_to_last_resize` / `last_resize_to_stable`。

---

## 2. 标注器判据（`src/term/garbleDetect.js`）

`detectGarble({ snapshot, termCols, termRows? }) → { garbled, reasons, metrics }`。
在内存里看文本，日志只落判定与统计。

| reason | 物理含义 | 假阳 | 假阴 |
|---|---|---|---|
| `overwide_line` | 去 CSI 后某行显示宽度 > `termCols`。主机 235 列行写进 80 列网格必折行。 | 极宽 OSC/未剥净转义把宽度抬高（剥 CSI/OSC 后本夹具未出现）。含尾空格的行已 trim。 | 错乱来自纵向滚行/CUP 钳位但每行都 ≤ 本地列（纯行错位）。 |
| `box_run_exceeds_cols` | 连续 `─` 等盒线长度 > `termCols`。Claude Code 顶栏在错乱时被撕开。 | 盒线本就短于本地宽则不报；本条是 overwide 的子集加强。 | 无盒线的错乱（纯文本折行）靠 `overwide_line`。 |
| `cup_clamped` | 快照尾 CUP 的 row>termRows 或 col>termCols。xterm 会把光标钳到网格边缘。 | 本地 rows 暂时小于主机（容器未 fit 完）会红一下。 | CUP 列常在行首（本夹具 `maxCupCol=6`），**不能**当屏宽。 |
| `missing_term_cols` | 调用方没给本地列数。 | 无。 | — |

**已知坏量具（本器不用）**：`inferSnapshotWidth` = CUP 最大列号。本夹具反证：宽快照 `maxCupCol=6`、`maxLineWidth=235`。

定位：便宜标签。分析只许用 §1 日志字段组合。

---

## 3. settle 分段

定义（单调时钟，与事件 `t` 同一源）：

```
t0            activate（点击 open/split）
t_sub_sent    该 ref 第一条 sent:true 的 subscribe
t_snap_first  该 ref 第一条 snapshot
t_last_resize 该 ref 最后一次 term_resize
t_stable      garble_label 连续 2 次 garbled:false 且 geom 字符串不变
settle_ms     t_stable - t0
```

埋点：`activate`→t0；`subscribe.sent`→t_sub_sent；`snapshot`→t_snap_first；`term_resize`→t_last_resize；`garble_label`→稳定计数。

**对「10 次均值 < 50ms」**：`sub_to_snap` 是 daemon 往返（本机 loopback 也是捕获+编码+WS）。产品路径还要等 WebGL `readyWebgl` 才 subscribe。因此 **50ms 总预算不可能只靠客户端微优化吃掉网络段**；分段就是为了把「卡在 RTT」和「卡在 fit/resize 防抖 120ms」拆开。`GRID_DEBOUNCE_MS=120` 一旦触发，单段就已 >50ms。

本格未做 10 次 UI 巡检（那是 t.harness/t.sweep）。单测只证明分段字段会填。

---

## 4. 真样本 fixture

来源：本机 `agentmirrord`（pid 16330 听 `*:9900`）。脚本 `.team/nodes/garble/capture-fixtures.mjs`，配方同 `probe-why-stuck.mjs`：从 tauri store 读 url/token，**不打印**。`subscribe(listing.rows, listing.cols)` 后收首帧 snapshot payload，立刻 unsubscribe。

| 文件 | pane | listing | 字节 | stripped max line |
|---|---|---|---|---|
| `test/testdata/garble/wide-host.snapshot.bin` | `%1` | 235×50 | 22303 | 235 |
| `test/testdata/garble/matched-host.snapshot.bin` | `%2` | 80×24 | 1694 | 79 |

元数据：`.team/nodes/garble/fixture-source.json`（无 token、无 ref 全文）。

**两头夹住（`npm test` 2026-08-23，exit 0，**112** 条，棘轮 ≥106）**：

| 样本 | 本地网格 | garbled | 读数 |
|---|---|---|---|
| wide-host（坏） | 80×24 | **true** | reasons=`cup_clamped,overwide_line,box_run_exceeds_cols`；overwideLines=28；maxBoxRun=231；maxCupCol=6 |
| wide-host（好） | 235×50 | **false** | 同一字节，网格对齐则绿 |
| matched-host（好） | 80×24 | **false** | maxLineWidth=79 |

说明：daemon 快照本身是主机坐标系的完好字节，不是「已经撕开的乱码」。错乱发生在 **宽字节 × 窄 `term.cols`**。正样本 = 真 235 列快照 + 80 列网格，不是手编字符串。

风险：捕获时对 `%1`/`%2` 短暂 subscribe，可能偷走桌面端已有 pipe（见 WHY-STUCK）。已立即 unsubscribe。若用户这两列画面冻结，切走再点开即可重订。

---

verdict: pass
