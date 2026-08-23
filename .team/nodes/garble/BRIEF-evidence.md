# 简报 · t.evidence —— 在「点开会话 → 排布完成」这条路上加日志，**用用户的标签验它**

**先读** `.team/nodes/_driver/席位纪律.md`。
**再读** `.team/nodes/garble/LABELS.md`（🔴 **用户亲手打的 ground truth，唯一权威**）。

## 0. 用户的原话（⛔ 本格的宪法）

> 「加日志，把点开这个会话到**渲染完成**的地方加日志，来确定这个日志**能不能判定它为什么坏、它是否是坏的**。
> **找到确切证据之前，就不要往下一步去走。**」

> 「通过**日志组合**去分析当前错乱的和非错乱的有什么样的特征，并且将它们 **100% 的区分开来**。
> 然后从区别**反推**代码逻辑的问题。**没有真相源就不应该改代码，真相源就是日志。**」

## 1. 与昨天那轮的**根本不同**（⛔ 读懂再动手）

昨天我们也加过日志（PR #64，后随 #79 整条退掉）。**那轮是废的**，因为：
标签是我们自己写的启发式 `detectGarble` 给的，然后拿日志去拟合自己的标签 —— **循环论证**。

**今天不一样**：用户逐张看完 59 张真实截图，亲手指出 **5 张坏、54 张好**（见 `LABELS.md`）。
⇒ **标签是外部的、固定的。** 日志字段组合能不能分开它们，是一个**可证伪**的问题。

🔴 **⛔ 本格不许写任何 detector、不许改标签、不许"修正"用户的判断。**

## 1.5 🔴 有**两种**失效模式，本格**两种都要覆盖**（⛔ 少一种不算做完）

| 模式 | 触发 | 名单（`LABELS.md`） |
|---|---|---|
| **一：一打开就坏** | 首次点开即错排 | `reviewer-r19` %100 / `reviewer-r21` %103 / `w2-dev-b` %7 / `w2-dev-c` %8 / `grok` %0 |
| **二：轮转后坏** | 反复切换、**停留时间短** | `tester-t150` / `reviewer-r16` / `reviewer-r17` / `tester-t151` / `reviewer-r18` |

模式二**已自动复现**（leader 实测，⛔ 不是推断）：
- 均匀轮询 59 个、停留 **2200ms**、跑 3 轮 ⇒ `reviewer-r17` **全好**；
- `reviewer-r17` ↔ `reviewer-r16` 快切、停留 **600ms** ⇒ **第 15 次明显错排**。
- 复现命令：`node .team/nodes/garble/toggle-web.mjs --a reviewer-r17 --b reviewer-r16 --n 16 --dwell 600 --out <目录>`
- 坏态图 `.team/nodes/garble/toggle/k15__reviewer-r17.png`；好态图 `.team/nodes/garble/shots-rounds/r3__25__reviewer-r17.png`。

⇒ **停留时间是自变量。** 日志必须能解释「同一个 pane、同样几何，2200ms 好、600ms 坏」。

## 2. 要做的四件事（按顺序）

### ① 在「点击 → 排布完成」路径上加日志
埋点设计**直接取回**已被回退的那版，⛔ 不要重新发明：

```
git show ca1f54c:src/term/amDiag.js
git show ca1f54c:src/vendor/agentmirror/client.js   # subscribe/listing/list_delta 的埋点
git show ca1f54c:src/term/TerminalView.js           # fit / term_resize / write_snapshot 的埋点
git show ca1f54c:src/components/terminal/TerminalPane.jsx
```

覆盖：`activate`（点击）→ `fit`（含 early_exit / 防抖路径）→ `term_resize` → `subscribe`（含 host_cols）
→ `snapshot` → `write_snapshot` → `delta` / `write_delta` → `resize_up` → `listing` / `list_delta`
→ `conn_state` / `ready_replay` / `reconnect`。每条带**单调时刻**、`ref`、**全局单调序号**。

🔴 **在此之上必须补齐三类字段**（模式二是竞态，缺了就分不开）：

| 类 | 至少要有 |
|---|---|
| **几何三方对账** | 每次 `write_snapshot` 时同时记：`term.cols/rows`（xterm 实际网格）、本次 `subscribe` 申报的 `cols/rows`、帧头里的 `host_cols/host_rows`。三者是否相等是核心怀疑点 |
| **归属与时序** | 每一帧记它**属于哪个 `ref`**、写入时**当前激活的是哪个 `ref`**、距离本次 `activate` 多少 ms、本次 `activate` 的序号。**跨 ref 的帧落到新终端上**是模式二的头号嫌疑 |
| **写入后的缓冲区形状** | `write_snapshot` 完成后读一次 xterm 缓冲区：行数、`isWrapped` 为真的行数、最长行长度、最后一行索引。⛔ 只记形状数字，**不许记正文** |

⛔ **不要带回 `garbleDetect.js`**（启发式标注器，正是循环论证的来源）。
🔴 日志里 ⛔ 不许出现 pane 正文、token。只放几何、时序、计数。

### ② 采集 A（模式一）：图与日志**同一次运行**配对
改 `.team/nodes/garble/shots-web.mjs`（已存在，回路已通，**内置 `EXCLUDE` ⛔ 不许移除**）：
每点开一个会话，**既存 PNG，也存 `window.__amDiag.dump()` 的 JSON**，两者同名配对。
视口仍锁 **1400x860**（与桌面端一致）。⛔ 不驱动系统键鼠。

### ③ 采集 B（模式二）：快切，逐次配对
改 `.team/nodes/garble/toggle-web.mjs` 同样出 PNG + JSON 配对。
至少跑两档做**对照**：`--dwell 600 --n 16`（预期出坏）与 `--dwell 2200 --n 16`（预期全好），
`--a reviewer-r17 --b reviewer-r16`。两档的日志差异就是模式二的证据。

### ④ 验：日志能不能分开
🔴 **方法固定如下，⛔ 不许改**（这是为了避免又一次循环论证）：

1. **只在模式一的固定标签上拟合**：用 `LABELS.md` 的 **5 坏 / 54 好**，在日志字段（及其组合）上找判别规则。
2. **拿模式二做样本外检验**：把第 1 步得到的规则**原封不动**套到 ③ 的快切帧上，
   输出「规则判为坏」的帧号清单，**并把对应 PNG 一并交付**，由 leader/用户看图核对。
   ⛔ 不许为了让模式二好看而回头改规则；要改就重跑第 1 步并说明。

| 结果 | 怎么写 |
|---|---|
| 模式一**假阳 0、假阴 0** | 贴混淆矩阵四个数 + 规则表达式 + 每个字段在坏/好两组的取值分布 |
| 规则在模式二上的表现 | 判为坏的帧号 + 对应 PNG 路径；`600ms` 档与 `2200ms` 档各判出几帧 |
| 找不到 100% 的 | 🔴 **如实写找不到**，并指出「**哪两条记录在所有已埋字段上完全一样但标签相反**」，以及**建议再补哪个埋点**。这**同样是有效交付**，⛔ 不许硬凑一条勉强的规则 |

⛔ **不许用任何我们自己算的"错乱分数"当标签。** 模式一的标签只有一个来源：`LABELS.md`。

## 3. 判据

| # | 判据 |
|---|---|
| a | `.team/nodes/garble/EVIDENCE.md` 存在、非空 |
| b | 模式一：每个被测会话一份 PNG + 一份日志 JSON，同一次运行配对 |
| c | 模式二：`600ms` 与 `2200ms` 两档各 16 帧，每帧 PNG + JSON 配对 |
| d | 🔴 日志含 §2① 表里那三类字段（几何三方对账 / 归属与时序 / 缓冲区形状），逐项举出实际取值 |
| e | 🔴 模式一混淆矩阵（对 5/54），或如实写「未达 100% + 分不开的样本 + 缺哪个埋点」 |
| f | 🔴 模式二样本外检验结果（判坏帧号 + PNG 路径 + 两档对比） |
| g | `npm test` 全绿且 **≥ 113** |
| h | ⛔ 未带回 `garbleDetect.js`；⛔ 未做任何"修复"（`git diff` 里除埋点与夹具外无逻辑改动） |

## 4. 🔴 ⛔ 本格绝不修任何东西

用户明令：**「找到确切证据之前，就不要往下一步去走。」**
哪怕你已经看出该改哪一行——**写进产物的「反推结论」一节，⛔ 不动手**。

## 5. ⛔ 其它红线

- 🔴 **⛔ 收藏会话一律不许点**：5 个 `claude_code` 席位（多agent协作 / tmux桌面端 / 本地部署 /
  讨论team-agent / 远程Agent安卓）。两个夹具已内置 `EXCLUDE`，⛔ 不许移除、不许绕过。
- ✅ **`LABELS.md` 里那 5 个坏会话是可以点的**（用户 2026-08-23：「我截图的那 5 个，你们是可以点的，因为我基本不看」）。
- ⛔ 驱动用户鼠标键盘；⛔ 动用户的 AgentMirror 进程；⛔ 碰上游；⛔ 放宽 CSP。
- ⛔ pane 正文 / token 进日志、产物或截图。
- 端口/socket 被占**换一个**，⛔ 不 kill 占用者；杀进程**按 pid**，⛔ 不 `pkill -f`。

## 6. 收工

独立 worktree；**开工先 `git fetch origin`**，基于 `origin/main`。
🔴 收工 **commit + push + `gh pr create`**。⛔ **你不 merge。**
⛔ 大量 PNG 会让 PR 很大，这是预期的；⛔ 不许因此少截。

**产物 `.team/nodes/garble/EVIDENCE.md`，落盘后 `report_result`。末行格式见席位纪律 §6。**
