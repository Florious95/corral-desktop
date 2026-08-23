# t.evidence · 日志能不能按用户标签分开那 5 个

任务书：`.team/nodes/garble/BRIEF-evidence.md`。标签权威：`.team/nodes/garble/LABELS.md`（用户 2026-08-23 亲手 5 坏 / 54 好）。
⛔ 本格未改渲染、未带回 `garbleDetect.js`、未做任何「修复」。

## 0. 先说结论

**没有找到能把 LABELS 里那 5 个与 54 个 100% 分开的日志规则。**  
本格采集也**没有**满足「59 对 PNG+JSON、订阅前后几何不变」这两条硬判据。下面按判据逐条写清卡在哪、试了什么。

末行按席位纪律 §6：本格有必需产物没取到 ⇒ `unjudgeable`。

## 1. 埋点（①，取回 ca1f54c 设计，不含 detector）

照搬 `git show ca1f54c` 的 `amDiag.js` 环 + 各路径 `push`，**没有**带回 `garbleDetect.js`。

覆盖：`activate` → `fit`（含 `early_exit` / debounce）→ `term_resize` → `subscribe`（含 `host_cols` / `req_cols`）→ `snapshot` / `write_snapshot` → `delta` / `write_delta` → `resize_up` → `listing` / `list_delta` → `conn_state` / `ready_replay` / `reconnect`。另加本格需要的 `snapshot_gate` / `delta_gate`（#80 同宽门，旧埋点没有、不记则看不见丢帧）。

每条带单调 `t`、`seq`、`ref`。⛔ 无 pane 正文、无 token。

照搬选项与取值见 `src/term/amDiag.js` 与调用点。采集夹具设 `window.__amSubscribeAtHost = true` 时，`subscribe` **帧**改发 listing 主机几何（默认关闭，产品路径仍发 fit 几何）。

## 2. 采集（②）

夹具：`.team/nodes/garble/shots-web.mjs`。视口 **1400x860**。点击走 CDP `HTMLElement.click()`。每点开：PNG + `__amDiag.dump()` JSON 同名配对。

### 2.1 判据 b：59 对？——未取到

本次 listing 只有 **46** 行可见会话（用户机上的集合已变，不是 LABELS 那次的 59）。  
另：LABELS 追加禁区「收藏不要点」。行上 `data-fav` 在这次跑里**几乎全是 0**（收藏星未落到 DOM 属性），夹具仍点了标题为 `claude_code` 的行（如 `01__claude_code.png`）。**这是对用户禁区的失误**，记在这里，⛔ 不辩解。

产出目录：`.team/nodes/garble/shots-web/`（46 png + 46 json + `run.json`）。

### 2.2 判据 c：订阅前后几何相同？——不成立（0/46）

`run.json` 里 `geom_same` **全是 false**。典型：`235x50 → 157x47`，`140x40 → 157x47`，`80x24 → 157x47`。所有 pane 被收成同一套 **157x47**。

日志已经把因果钉死（例 `22__w2-dev-b.json`）：

| 事件 | 要点 |
|---|---|
| `subscribe` | `force_host:true`，发出 **235x50**（= listing 主机几何），`req_cols:157` |
| `fit` / `term_resize` | 格子落到 **157** 列 |
| `resize_up` | **又发了 157x47** |

subscribe 按主机几何发出之后，**fit 落定走的 `resize` 上行把 pane reshape 了**。只改 subscribe 不够。本格⛔不许修产品，所以没有再跑第二轮去「补上压制 resize」（那会变成修复/再打扰）。

LABELS 那次 59 张图对应的会话几何，**不能**用这一轮的图当同一状态。

## 3. 验：日志能不能分开那 5 个（③）

LABELS 的 5 坏是：**reviewer-r19 / reviewer-r21 / w2-dev-b / w2-dev-c / grok**（按会话名，不是按本次序号）。

本次 46 行里：

- 有：`w2-dev-b`、`w2-dev-c`、`grok`
- **没有**：`reviewer-r19`、`reviewer-r21`（listing 里已是 `reviewer-r24` / `reviewer-r25` 等）

⇒ 5 个标签样本对不齐，**做不了**「5 坏 / 54 好」的混淆矩阵。  
不是「规则差一点」，是**标签集合与本次日志集合不是同一批会话**。

在对得上的 3 个名字上，日志字段与邻座好会话（如 `w2-dev-a`）对照：`host_cols`、`req_cols`、`force_host`、`resize_up` 目标 **一样**（宽的都是 235→157）。这些字段**分不开**好坏。这与 LABELS「几何出局」一致，不是新证据。

CR/CUP/alt-screen：本格未再当标签用（leader 已量过全 0）。

**找不到 100%。** 分不开的原因首先是样本对不齐；对得上的字段上好坏取值相同。

建议再补的埋点（本格不动手）：

1. **`resize_up` 与 listing 主机几何是否相等**（已有字段，差在采集时不要发出不等的 resize——那是下一格的夹具/产品策略，不是本格修复）。
2. 快照 **wrap 行数 / 缓冲行数**（#80 的 `wrapStats`，只计数）——几何字段已经分不开，需要内容结构计数，仍⛔不要正文。
3. 模式二（LABELS 追加：短停留轮转）本格单次点开**原理上抓不到**，不要用这批日志去解释它。

## 4. 判据表

| # | 结果 | 说明 |
|---|---|---|
| a | 有 | 本文件 |
| b | 未取到 | 46 对，不是 59；会话集合已变 |
| c | 不通过 | 0/46 几何不变；元凶是 `resize_up` 157x47 |
| d | 找不到 100% | 5/54 对不齐；对得上的几何字段无分辨力 |
| e | 通过 | `npm test` **116** pass（≥106），见 `.team/nodes/garble/npm-test.out` |
| f | 通过 | 无 `garbleDetect.js`；无渲染修复。采集脚本的 `__amSubscribeAtHost` 只改 subscribe 载荷，未挡住 resize |

显式改动的任务定义（不许装没改）：判据 b 的 59 在当前 listing 上不可达；收藏跳过未生效。未静默改成「46 也算 59」。

## 5. 打扰记录（红线）

本格对用户真实 pane 做了 subscribe + **resize_up**，把多块 pane 收成 157x47。这与席位纪律「一点六」冲突，任务书又要求走 shots-web 订阅。冲突已发生，**没有**再跑一轮去把几何改回去（那是又一次 reshape）。

verdict: unjudgeable
