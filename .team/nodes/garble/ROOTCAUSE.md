# ROOTCAUSE · t.analyze（ledger.garble-truthsource r4）

只读 `sweep-full.jsonl`（550 行）+ 交付 A 埋点清单（`INSTRUMENT.md`）。⛔ 未改 `src/`。

**派单 vs 简报（任务定义冲突，显式）：** 本回合 leader 硬约束「不跑 git commit / push；不发 team-agent send」。简报 §6 / 「收工前必做」要求产物进 PR。本格 **按本回合派单：不 commit、不开 PR**。产物只在 worktree `.worktrees/wt-analyze/.team/nodes/garble/`。

基线：`HEAD == origin/main == 4751872`（已含 #64 埋点、#65 夹具、#66 巡检数据）。

---

## ① 分开：没有合法的 100% 判别规则

宪法要求规则是**交付 A 日志字段组合**，假阳 0、假阴 0。`INSTRUMENT.md` 写明 `garble_label` **只打标签**，分析禁止只用这一条。

### 混淆矩阵 A — 拒用的循环规则（不算通过）

规则（标注器原话）：`garbled ⇔ garble_label.garbled`  
等价式：`max_line_width > write_snapshot.term_cols` 以及 `overwide_lines > 0`（本数据集三者同构）。

|  | 标签 garbled | 标签 正常 |
|---|---:|---:|
| 规则说错乱 | **79** | **0** |
| 规则说正常 | **0** | **471** |

N = **550**。这是标注器自己，不是真相源。用它反推代码只会得到「`detectGarble` 在 `TerminalPane.jsx` 里把标签写进了日志」—— tautology。**不进入第②步。**

本轮所有错乱行还有一个更窄的标注器事实（仍是标签，不是规则）：`max_line_width` **全部等于 115**，`overwide_lines` **全部等于 1**，本地网格 **全部 39×114**。正常行 `max_line_width ∈ [0, 114]`。即标签定义的「超宽」在这 79 条上是 **刚好超 1 列**，不是夹具里那种 235 列主机快照。

### 混淆矩阵 B — 交付 A 非标注器字段：达不到 100%

对 `subscribe/fit/term_resize/resize_up/snapshot.bytes/write_snapshot/delta 计数/时间段` 做了单阈值扫描与若干合取。几何字段本轮是常数，无法当判别器：

- `subscribe.cols/rows`：**550/550 = 114×39**
- `write_snapshot.term_cols/rows`：**550/550 = 114×39**
- 末次 `fit` 算出 **114×39**（容器 800×705；路径 `80×24 → 102×39 → 114×39`）
- `listing` 事件 **0/550**（探针每次 `__amDiag.reset()` 清环，汇总 `listing_cols/rows` 几乎全 null）

`snapshot.bytes` 两组区间重叠：错乱 **1973–5005**，正常 **6–13011**。任何阈值都会同时产生假阳和/或假阴。

`resize_up` 相对 `snapshot` 的先后也不是分类器（错乱 77 条 resize 在快照前、2 条在后；正常 431 前 / 40 后）。

代表失败规则（恒预测「正常」= 零假阳、全假阴）：

|  | 标签 garbled | 标签 正常 |
|---|---:|---:|
| 规则说错乱 | **0** | **0** |
| 规则说正常 | **79** | **471** |

N = **550**。假阳 0、假阴 79。其它非标注器组合最好也不过「有假阳也有假阴」，没有 0/0。

**故：第一步未达 100%。不做第②步根因（文件:行）与事前预测。** 下面是分不开的样本 + 缺的埋点。

---

## 1b. 哪些样本分不开（几何日志相同、标签不同）

12 个会话 10 轮里有的错有的不错。它们的 **订阅/本地网格/fit/term_resize 目标** 与永远不错的会话相同（都是 114×39）。差别落在快照字节内容和标注器从正文算出的行宽上——而 **正文本身按埋点设计不进日志**。

对照会话：`/tmp/tmux-501/ta-a9fd5b7defbd%0`（JSON 里 ref 分隔符为 `\u001f`）。

| 字段 | 错乱 round 2 | 正常 round 1 |
|---|---|---|
| `garbled` | true | false |
| `subscribe` | 39×114 sent | 39×114 sent |
| 末次 `term_resize` | →114×39 | →114×39 |
| `write_snapshot.term_*` | 114×39 | 114×39 |
| `listing_*` | null | null |
| `fit` 序列 | first 102 → first 102 → unchanged 102 → immediate 114 | 同形 |
| `snapshot.bytes` | 3168 | 4282 |
| `garble_label.max_line_width` | 115 | 114 |
| `overwide_lines` | 1 | 0 |
| `max_box_run` | 114 | 114 |
| `cup_clamped` | 0 | 0 |
| `resize_up` vs `snapshot` | 快照之后才 resize_up | 快照之前已 resize_up |
| `settle_ms` | null | null |

`snapshot.bytes` 在这一对上不同，但不能当全局规则（见上：区间重叠）。**在所有已埋的几何/订阅字段上这两条一样；标签不同。** 决定对错的变量是快照正文行宽（或主机此刻真实列数），二者都没记。

永远错乱的 `default %1` 十轮同样是 **mlw=115、overwide_lines=1、bytes=4083**，不是 235 列整屏。与 `WHY-STUCK.md`「退订后 pane 回到 235×50」**对不上这批标签**。本 jsonl 里没有 `listing`，无法用主机几何支持或推翻偷管假说；能推翻的是「这 79 条等于把 235 列 TUI 塞进 114 列」——标注器读到的超宽只有 1 列、盒线跑长也是 114 不是 231。

完整记录（含 `dump.events` + `settle`）落在同目录：

- `.team/nodes/garble/pair-pos.json`（错乱）
- `.team/nodes/garble/pair-neg.json`（正常）

正文附录贴同一对的 `events` 数组。

---

## 1c. 现有字段为什么不够

1. **几何通道是常数。** 550 行客户端申报与写入网格都是 114×39。分组信息 100% 不在 `subscribe`/`fit`/`term_resize`/`resize_up.cols`。
2. **主机几何被量具清掉。** `scripts/garble-sweep.mjs` 每次点击前 `window.__amDiag.reset()`，环里进探针窗口的 `listing` 为 0。没有 `listing.cols ≠ subscribe.cols` 这种宪法示例规则的左值。
3. **快照只记长度。** `snapshot.bytes` 与行宽不是单调关系（错乱对 3168 小于正常对 4282；永远错乱的 `%1` 却是稳定的 4083）。没有 payload、没有逐行宽。
4. **唯一 100% 分界在标注器派生量上**，按任务书不能当判别规则。

---

## 1d. 建议补的埋点（函数 + 值 + 能回答什么）

补完后应能回答两句互斥的话之一：「主机 listing 就是 115」或「主机也是 114，是 `displayWidth` / 剥 ANSI 与 xterm 差 1 列」。

| 位置 | 记什么 | 回答什么 |
|---|---|---|
| `src/vendor/agentmirror/client.js` `subscribe` | 发送时该 `ref` 在**最近一次** `listing`/`list_delta` 里的 `rows,cols`（`host_rows`,`host_cols`,`listing_seq`）。缓存必须活过 `__amDiag.reset()`（环可清，这张表不可清）。 | `host_cols` 是 114 还是 115/235？与 `subscribe.cols` 差 1 还是差 121？ |
| `src/vendor/agentmirror/client.js` `handleFrame` listing | 同上缓存；探针 reset 后仍能挂到随后的 subscribe 上。 | 解决「listing 事件 0 行」的量具缺口，而不是让分析去猜主机。 |
| `src/term/garbleDetect.js` `detectGarble` 的 metrics（仍只打点、不当标签） | `max_line_width` 已有；加 **该超宽行剥 ANSI 后的码点长度** `max_line_chars`、以及是否含宽字符 `max_line_has_wide`。⛔ 不要把 pane 正文写进环。 | 1 列误差是宽字符计数还是真的多一个 cell。 |
| `src/term/amDiag.js` `touchSettle` | `t_stable`：一次 `garble_label` 之后 N ms 无 `term_resize`/`write_snapshot`（N=50 或 100）。 | 与错乱分组无关，但 `settle_ms` 550/550 null 使第③节只能用 `sub_to_snap` 下物理裁决。 |

**下一格不该是 t.fix。** 真相源未成立。授权路径是补埋点 → 重跑巡检 → 再 t.analyze。

---

## ② 反推（跳过）

第一步不是 100%，不写根因文件:行、不写「改完字段从 A 变 B」、不列调用方当修白名单。

只记录 **日志对上一轮推断的态度**（不是根因裁定）：

- `WHY-STUCK` 的 235×50 偷管：**这 550 行不支持「错乱 = 235 列快照进窄格」**（79 条 mlw 全是 115）。偷管机制本身本格既不能证实也不能证伪（无 listing）。
- 「另一个 tmux 客户端钉 235」：简报已证伪；本 jsonl 无新证据去翻案。
- 横向滚动：本格无 100% 规则，**不排除也不推荐**。

---

## ③ 性能裁决：10 次均值 < 50ms 做得到吗？

**做不到**（在当前 settle 定义下甚至 **测不到 settle_ms**）。口径不改。

来源：`SWEEP-REPORT.md`，550 行。

| 段 | n | 均值 | 中位 | p95 | 最小 | 最大 |
|---|---:|---:|---:|---:|---:|---:|
| `click_to_sub` | 550 | 45.4 ms | 45.0 | 52.1 | 36.5 | 81.1 |
| `sub_to_snap` | 550 | 191.6 ms | 180.7 | 302.7 | **84.7** | 456.7 |
| `snap_to_last_resize` | 550 | −191.7 | — | — | — | — |
| `settle_ms` | 0 | — | — | — | — | — |

硬底：`sub_to_snap` **最小 84.7ms > 50ms**（本机 loopback 上的 daemon 捕获+编码+WS）。总预算在「订阅出门 → 首帧 snapshot」已经不够。

去掉这段硬底之后，客户端自己的 `click_to_sub` 均值 **45.4ms**（中位 45.0，p95 52.1，已经有样本 >50）。`snap_to_last_resize` 为负：末次 `term_resize` 在 snapshot **之前**（打开时的 fit），不是「画完再排」。

`settle_ms` 恒空：`t_stable` 要连续 2 次 `garble_label && !garbled`；每探针恰好 1 次 label。这是量具定义问题，不是「已经稳定在 50ms 内」。

---

## 附录 · 并排完整 dump.events

### 错乱 · ta-a9fd5b7defbd %0 · round 2

见 `pair-pos.json`。events：

```json
[
  {"seq":1,"type":"activate","ref":"local::/tmp/tmux-501/ta-a9fd5b7defbd\u001f%0"},
  {"seq":2,"type":"unsubscribe","ref":"/tmp/tmux-501/default\u001f%2","sent":true,"reason":null},
  {"seq":3,"type":"fit","ref":"/tmp/tmux-501/ta-a9fd5b7defbd\u001f%0","early_exit":null,"path":"first","container_w":800,"container_h":705,"cols":102,"rows":39,"term_cols":80,"term_rows":24,"will_resize":true,"debounce_armed":false},
  {"seq":4,"type":"term_resize","ref":"/tmp/tmux-501/ta-a9fd5b7defbd\u001f%0","from_cols":80,"from_rows":24,"to_cols":102,"to_rows":39},
  {"seq":5,"type":"unsubscribe","ref":"/tmp/tmux-501/ta-a9fd5b7defbd\u001f%0","sent":true,"reason":null},
  {"seq":6,"type":"fit","ref":"/tmp/tmux-501/ta-a9fd5b7defbd\u001f%0","early_exit":null,"path":"first","container_w":800,"container_h":705,"cols":102,"rows":39,"term_cols":80,"term_rows":24,"will_resize":true,"debounce_armed":false},
  {"seq":7,"type":"term_resize","ref":"/tmp/tmux-501/ta-a9fd5b7defbd\u001f%0","from_cols":80,"from_rows":24,"to_cols":102,"to_rows":39},
  {"seq":8,"type":"fit","ref":"/tmp/tmux-501/ta-a9fd5b7defbd\u001f%0","early_exit":"grid_unchanged","container_w":800,"container_h":705,"cols":102,"rows":39,"term_cols":102,"term_rows":39,"will_resize":false,"debounce_armed":false},
  {"seq":9,"type":"fit","ref":"/tmp/tmux-501/ta-a9fd5b7defbd\u001f%0","early_exit":null,"path":"immediate","container_w":800,"container_h":705,"cols":114,"rows":39,"term_cols":102,"term_rows":39,"will_resize":true,"debounce_armed":false},
  {"seq":10,"type":"term_resize","ref":"/tmp/tmux-501/ta-a9fd5b7defbd\u001f%0","from_cols":102,"from_rows":39,"to_cols":114,"to_rows":39},
  {"seq":11,"type":"subscribe","ref":"/tmp/tmux-501/ta-a9fd5b7defbd\u001f%0","rows":39,"cols":114,"sent":true,"reason":null},
  {"seq":12,"type":"snapshot","ref":"/tmp/tmux-501/ta-a9fd5b7defbd\u001f%0","kind":1,"bytes":3168},
  {"seq":13,"type":"write_snapshot","ref":"/tmp/tmux-501/ta-a9fd5b7defbd\u001f%0","term_cols":114,"term_rows":39,"bytes":3168},
  {"seq":14,"type":"garble_label","ref":"/tmp/tmux-501/ta-a9fd5b7defbd\u001f%0","garbled":true,"reasons":["overwide_line"],"overwide_lines":1,"max_line_width":115,"max_box_run":114,"cup_clamped":0,"geom":"39x114"},
  {"seq":15,"type":"delta","kind":2,"bytes":1024},
  {"seq":16,"type":"write_delta","term_cols":114,"bytes":1024},
  {"seq":17,"type":"delta","kind":2,"bytes":2048},
  {"seq":18,"type":"write_delta","term_cols":114,"bytes":2048},
  {"seq":19,"type":"delta","kind":2,"bytes":2166},
  {"seq":20,"type":"write_delta","term_cols":114,"bytes":2166},
  {"seq":21,"type":"resize_up","rows":39,"cols":114,"sent":true,"reason":null},
  {"seq":22,"type":"resize_up","rows":39,"cols":114,"sent":true,"reason":null}
]
```

### 正常 · 同一会话 · round 1

见 `pair-neg.json`。events：

```json
[
  {"seq":1,"type":"activate","ref":"local::/tmp/tmux-501/ta-a9fd5b7defbd\u001f%0"},
  {"seq":2,"type":"unsubscribe","ref":"/tmp/tmux-501/default\u001f%2","sent":true,"reason":null},
  {"seq":3,"type":"fit","early_exit":null,"path":"first","container_w":800,"container_h":705,"cols":102,"rows":39,"term_cols":80,"term_rows":24,"will_resize":true},
  {"seq":4,"type":"term_resize","from_cols":80,"from_rows":24,"to_cols":102,"to_rows":39},
  {"seq":5,"type":"unsubscribe","ref":"/tmp/tmux-501/ta-a9fd5b7defbd\u001f%0","sent":true},
  {"seq":6,"type":"fit","path":"first","cols":102,"rows":39,"term_cols":80,"term_rows":24,"will_resize":true},
  {"seq":7,"type":"term_resize","from_cols":80,"from_rows":24,"to_cols":102,"to_rows":39},
  {"seq":8,"type":"fit","early_exit":"grid_unchanged","cols":102,"rows":39,"term_cols":102,"term_rows":39,"will_resize":false},
  {"seq":9,"type":"fit","path":"immediate","cols":114,"rows":39,"term_cols":102,"term_rows":39,"will_resize":true},
  {"seq":10,"type":"term_resize","from_cols":102,"from_rows":39,"to_cols":114,"to_rows":39},
  {"seq":11,"type":"subscribe","rows":39,"cols":114,"sent":true,"reason":null},
  {"seq":12,"type":"resize_up","rows":39,"cols":114,"sent":true},
  {"seq":13,"type":"resize_up","rows":39,"cols":114,"sent":true},
  {"seq":14,"type":"snapshot","kind":1,"bytes":4282},
  {"seq":15,"type":"write_snapshot","term_cols":114,"term_rows":39,"bytes":4282},
  {"seq":16,"type":"garble_label","garbled":false,"reasons":[],"overwide_lines":0,"max_line_width":114,"max_box_run":114,"cup_clamped":0,"geom":"39x114"},
  {"seq":17,"type":"delta","kind":2,"bytes":2048},
  {"seq":18,"type":"write_delta","term_cols":114,"bytes":2048},
  {"seq":19,"type":"delta","kind":2,"bytes":1024},
  {"seq":20,"type":"write_delta","term_cols":114,"bytes":1024},
  {"seq":21,"type":"delta","kind":2,"bytes":2048},
  {"seq":22,"type":"write_delta","term_cols":114,"bytes":2048},
  {"seq":23,"type":"delta","kind":2,"bytes":118},
  {"seq":24,"type":"write_delta","term_cols":114,"bytes":118}
]
```

---

verdict: unjudgeable
