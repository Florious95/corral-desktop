# ROOTCAUSE-2 · t.analyze2（ledger.garble-truthsource-r2 r3）

只读 `sweep-full-2.jsonl`（550 行，t.sweep2，带 t.deepen 埋点）。⛔ 未改 `src/`。

输入路径（本树 write_paths 不含巡检产物原件）：  
`/Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-r2scan/.team/nodes/garble/sweep-full-2.jsonl`  
对照报告：同目录 `SWEEP-REPORT-2.md`。埋点契约：`INSTRUMENT.md`（本树仍是 r1 表；活数据里 subscribe 已有 `host_*`，label 已有 `max_line_chars` / `max_line_has_wide`）。

**任务定义改动（显式）：** 账本/派单产物名 `ROOTCAUSE-2.md`，输入 `sweep-full-2.jsonl`（不是简报里的 `ROOTCAUSE.md` / `sweep-full.jsonl`）。派单「不跑 git commit / push」与简报「收工必须留下 PR」打架：本格 **按派单：不 commit、不开 PR**。`wt-r2diag` HEAD 仍为 `48a62b9`；`origin/main` 已到 `82ca1ad`。本格不写产品码，未 `checkout` 去追 main。

标签：`garbled:true` **75** / `false` **475**。N = **550**。

---

## ① 分开：没有合法的 100% 判别规则

宪法：规则必须是**交付 A 日志字段组合**，假阳 0、假阴 0。`garble_label` **只打标签**；`max_line_width > term_cols` / `overwide_lines > 0` 与标签同构，r1 已拒用，本轮复查仍完美，**仍不算通过**。

### 混淆矩阵 A — 拒用的循环规则

规则：`garbled ⇔ (max_line_width > write_snapshot.term_cols)`  
本轮三者同构：`garbled`、`overwide_lines > 0`、`mlw === 115`（错乱行 mlw **全部 115**，正常行 mlw **∈ [0, 114]**）。

|  | 标签 garbled | 标签 正常 |
|---|---:|---:|
| 规则说错乱 | **75** | **0** |
| 规则说正常 | **0** | **475** |

N = **550**。tautology。**不进入第②步。**

### 混淆矩阵 B — 新埋点 + 其余非标注器字段：达不到 100%

新字段本轮 **550/550 有值**：`subscribe.host_cols/host_rows/listing_seq`、`max_line_chars`、`max_line_has_wide`、`settle_ms`。

关键事实：

- 本地订阅 **550/550 = 114×39**；`write_snapshot.term_*` **550/550 = 114×39**；fit 末步 **114×39**（路径 `first 102 → first 102 → unchanged 102 → immediate 114`）。
- **`host_cols !== subscribe.cols` 在 550/550 成立**（headless 永远订 114；listing 缓存从来不是 114：235×480 行，另有 80/137/140/142）。宪法示例 `listing.cols ≠ subscribe.cols` 在这套量具上是**常数真**，零分辨力。
- 错乱 75 条 `host_cols` **全部 235**；但正常里也有 **405** 条 235。规则 `host_cols === 235`：

|  | 标签 garbled | 标签 正常 |
|---|---:|---:|
| 规则说错乱 | **75** | **405** |
| 规则说正常 | **0** | **70** |

假阳 405。`host_minus_sub === 121` 同构。

- `max_line_has_wide`：错乱 75/75 true；正常 **148** 条也 true（含下面那对样本）。`host_cols===235 ∧ mwide`：tp 75、**fp 138**。
- `max_line_chars`：错乱 61–96，正常 0–114，区间重叠。`mchars > 114` 一次都未命中（码点数 ≠ 显示宽）。
- `snapshot.bytes`：错乱 1973–5005，正常 6–13011，重叠。单阈值扫描最好的合法字段仍是「几乎全假阴」（例如 `snap_bytes === 3799`：tp 10、fp 0、fn 65）。
- 时序：`snap_before_last_resize` 550/550 为假（末次 resize 都在 snapshot 前）。`sub_to_snap` / `settle_ms` 两组区间重叠。

代表失败（恒预测正常 = 零假阳、全假阴）：

|  | 标签 garbled | 标签 正常 |
|---|---:|---:|
| 规则说错乱 | **0** | **0** |
| 规则说正常 | **75** | **475** |

N = **550**。假阳 0、假阴 75。没有任何非循环组合达到 0/0。

同一套几何签名（host 235×50、订 114×39、fit 四步、3 次 term_resize）盖住 **75 条错乱 + 395 条正常**。

**第一步未达 100%。不做第②步。**

---

## 1b. 哪些样本分不开

14 个会话 10 轮里有的错有的不错。对照：`ta-a9fd5b7defbd %90`（round 1 错 / round 3 正常）。完整 dump 见 `pair2-pos.json` / `pair2-neg.json`。

| 字段 | 错乱 round 1 | 正常 round 3 |
|---|---|---|
| `garbled` | true | false |
| `subscribe` | 39×114 sent | 39×114 sent |
| **`host_cols/rows`** | **235×50** | **235×50** |
| **`listing_seq`** | **2319** | **2319** |
| 末次 `term_resize` | →114×39 | →114×39 |
| `write_snapshot.term_*` | 114×39 | 114×39 |
| `fit` 序列 | first 102 → first 102 → unchanged 102 → immediate 114 | 同形 |
| `snapshot.bytes` | 3985 | 4105 |
| `max_line_width` | 115 | 114 |
| `overwide_lines` | 2 | 0 |
| `max_line_chars` | 87 | 83 |
| `max_line_has_wide` | **true** | **true** |
| `max_box_run` | 114 | 114 |
| `cup_clamped` | 0 | 0 |
| `settle_ms` | 263.9 | （该 round 有值；两组全局重叠） |

**r2 新埋点在这一对上完全相同（host 235、listing_seq 2319、has_wide true）。** 分开它们的仍是标注器从正文算出的行宽（115 vs 114）和快照字节——正文不进日志。

永远错乱的 `default %1` 仍是 mlw=115、盒线 114、host 缓存 235，不是 231 列盒线的 235 整屏砸进窄格。

---

## 1c. 现有字段为什么不够（含「补完的埋点回答了什么」）

1. **`host_cols` 回答的是点击前 listing 缓存，不是这帧 snapshot 的主机网格。** 同一 `listing_seq=2319` 出现在错/对两轮：订阅 114 之后 pane 理应被 reshape，但缓存不会因为这次 subscribe 更新，探针窗口里 `listing` 事件仍是 0（`list_delta` 仅 56/550）。所以「host 235」多半是空闲基线（与 WHY-STUCK 退订回 235×50 同形），**不能**读成「这帧字节按 235 列编码」。
2. **几何通道仍是常数。** 客户端申报/写入仍全是 114×39。`host ≠ sub` 恒真。
3. **`max_line_has_wide` 不是分界。** 错乱 75 条都有宽字符，但正常 148 条也有；对照对两侧都是 true。`max_line_chars` 与 mlw 不是同一量纲，且区间重叠。
4. **快照仍只记长度。** 决定 115 vs 114 的是正文；字段里没有逐行宽直方图。
5. **唯一 100% 分界仍在标注器派生量上**，不能当判别规则。

t.deepen 的解释 A（xterm 承认 115 会折）与本格不冲突：那是对标注器尺子的鉴定，不是「非标签字段 100% 分开两组」。

---

## 1d. 建议再补的埋点

目标：能回答「订阅 114 之后、写 snapshot 那一瞬，主机 pane 是 114、115 还是仍 235」。现在的 `host_cols` 回答不了。

| 位置 | 记什么 | 回答什么 |
|---|---|---|
| `client.js` `handleFrame` `list_delta`（以及若有订阅后的 listing） | 该 `ref` 在 **subscribe 之后** 的 `rows,cols` → `host_cols_live` / `host_cols_at_snap`（不要用点击前缓存顶替） | reshape 有没有发生；错乱轮是不是活几何仍 >114 |
| `TerminalPane` 打 `garble_label` 时 | `n_lines_overwide` 已有；加 **`n_lines_width_eq_cols`**、**`n_lines_width_cols_plus_1`**（整数，仍不要正文） | 是「整整一屏超宽」还是「1 行刚好 +1」（本批标签形态） |
| 若协议/daemon 快照头带网格 | 把 snapshot 帧上的主机 cols 打进 `snapshot` 事件 | 不依赖 listing 时序 |

**下一格仍不该是 t.fix。** 合法路径：补「订阅后的活几何」→ 再巡检 → 再 analyze。

---

## ② 反推（跳过）

第一步不是 100%，不写根因文件:行、不写事前预测、不列调用方白名单。

日志对旧推断的态度（不是根因裁定）：

- WHY-STUCK 偷管 / 退订回 235×50：`host_cols=235` **大量出现在正常行（405/475）**，不能把「缓存 235」等同于错乱。机制本身：本 jsonl 仍几乎没有订阅后的 listing，**既不能证实也不能证伪「偷管正在发生」**。
- 「错乱 = 235 列快照进 114」：75 条 mlw 全是 115、盒线 114，**仍不支持**。
- 「另一个 tmux 客户端钉 235」：简报已证伪；本 jsonl 无新证据翻案。
- 横向滚动：无 100% 规则，**不排除也不推荐**。

---

## ③ 性能裁决：10 次均值 < 50ms 做得到吗？

**做不到。** 口径不改。数字来自 `SWEEP-REPORT-2.md`（新 `t_stable` = label 后 100ms 静默；550/550 有 `settle_ms`）。

| 段 | n | 均值 | 中位 | p95 | 最小 | 最大 |
|---|---:|---:|---:|---:|---:|---:|
| `click_to_sub` | 550 | 42.6 | 42.3 | 48.0 | 35.6 | 85.8 |
| `sub_to_snap` | 550 | **102.9** | 97.4 | 146.5 | **73.9** | 232.8 |
| `snap_to_last_resize` | 550 | −102.9 | −97.4 | −80.3 | −232.9 | −73.9 |
| `last_resize_to_stable` | 550 | 203.3 | 197.8 | 246.8 | 174.4 | 333.4 |
| `settle_ms` | 550 | **245.9** | 240.8 | 290.5 | **211.5** | 385.0 |

硬底：`sub_to_snap` **最小 73.9ms > 50ms**（daemon 捕获+编码+WS）。到首帧已是 `click_to_sub`+`sub_to_snap` ≈ 145ms。`settle_ms` 还含定义上的 100ms 静默；扣掉后均值仍约 146ms，仍大于 50。

去掉硬底之后，客户端自己的 `click_to_sub` 均值 **42.6ms**（中位 42.3，p95 48.0，已有样本 >50）。`snap_to_last_resize` 为负：末次 `term_resize` 在 snapshot 之前。

---

## 附录 · 对照对的 subscribe / label（正文见 pair2-*.json）

错乱 round 1 subscribe：`{ rows:39, cols:114, host_rows:50, host_cols:235, listing_seq:2319, sent:true }`  
label：`{ garbled:true, reasons:['overwide_line'], overwide_lines:2, max_line_width:115, max_line_chars:87, max_line_has_wide:true, max_box_run:114, geom:'39x114' }`

正常 round 3 subscribe：字段同上（含 **同一 listing_seq 2319**）。  
label：`{ garbled:false, reasons:[], overwide_lines:0, max_line_width:114, max_line_chars:83, max_line_has_wide:true, max_box_run:114, geom:'39x114' }`

verdict: unjudgeable
