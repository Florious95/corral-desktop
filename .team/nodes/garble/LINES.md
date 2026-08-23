# LINES.md — t.lines：`-e` / `-p` / `-J` 切行对照

账本 `ledger.garble-truthsource-r7` / `t.lines` r1。本格只裁定切行，**不修**。
量具：`.team/nodes/garble/run-lines.mjs` → `lines-run.json`（结构统计，无 pane 正文、无 token）。

样本：现场 WS listing **55** 个 session，各订 **39×114** 后同一瞬间三种 `capture-pane`；另起独立 socket `/tmp/tmux-501/aml` 做折行对照（非用户 pane）。

## 1. 三取法并排（现场，n=55）

剥 ANSI 后用现有 `detectGarble` 只取 `maxLineWidth` / 超宽计数。**同一瞬间**三种 tmux 取法：

| 取法 | 命令 | 超宽行合计（宽>114） | 备注 |
|---|---|---:|---|
| `-e` | `capture-pane -e -p` | **4** | 与 `-p` 同行数：55/55 `raw_nl` 相等 |
| `-p` | `capture-pane -p` | **4** | 网格行，不拼折行 |
| `-J` | `capture-pane -J -p` | **16** | 已知会把折行拼回 |

daemon 首帧 snapshot（协议 kind=1，上游 `bridge.go:62` 也是 `capture-pane -e -p`）在**同一次 subscribe 里先于**上面三次 capture 到达：超宽合计 **16**。这与「同一瞬间 `-e` vs `-p`」不是同一时刻：订 114 后 TUI 会重绘，首帧可仍含旧 115。

剥 ANSI 量具自检（现场 55）：`strip_dotall_joins=0`，`e_fewer_nl_than_p=0`，`strip_ate_lines` 全 false。`garbleDetect.js:6` 的 `CSI_OR_ESC` 带 `s`（dotAll）**本批没有把 `\n` 吃掉**。

## 2. 关键判据：`-e` 超宽行在 `-p` 里是什么

对每条 `-e` 宽>114 的逻辑行，在同一次 `-p` 输出里做结构匹配（只比字符串相等 / 相邻两行拼接，**不落正文**）：

| 分类 | 计数 | 含义 |
|---|---:|---|
| glued（`-p` 两行各 ≤114，拼接等于该 `-e` 行） | **0** | 粘行 |
| real115（`-p` 里也有同一条超宽行） | **4** | 网格上就是一行 |
| unmatched | **0** | |

`glue_how.concat = 0`，`glue_how.prefix_suffix = 0`。

4 条 real115 落在 2 个 session：一个 `-e/-p/-J` 都是 3 条宽=115；另一个都是 1 条宽=115。这 2 个 pane 上 `-J` **没有**比 `-p` 多出超宽行（`raw_nl` 也相同），说明它们不是「折行被 `-J` 拼出来」的那种 115。

## 3. 隔离折行对照（已知会折的一行）

夹具：114 列自建 pane，写入 `113` 个 ASCII `x` + `U+4E2D`（显示宽 115，网格必然折）。

| 取法 | 行数(dotAll) | 超宽 | max_w |
|---|---:|---:|---:|
| `-e -p` | 9 | **0** | 114 |
| `-p` | 9 | **0** | 114 |
| `-J -p` | 7 | **2** | 140 |

折行在 `-e`/`-p` 里**不会**变成 115；只有 `-J` 拼回后才超宽。这是粘行假说的**阳性对照**（坏态在 `-J` 上红、好态在 `-e/-p` 上绿）。

## 4. 裁定

**115 是真的（就 `-e` vs `-p` 切行而言）。粘行不成立。**

上一格「daemon snapshot 超宽 11、直接 `-p` 超宽 4」的差，**不能**解释成「`-e` 把两行粘成一行」：同一瞬间的 `-e` 与 `-p` 超宽都是 4，且那 4 条在 `-p` 里也是单行 115。snapshot 超宽 16 对齐的是「订宽后尚未重绘的首帧 + 全场 `-J` 合计 16」这类**时刻/拼折**差，不是 `stripAnsi` 吃换行。

「谁在粘」三选一：本格对 `-e` vs `-p` **没有粘行可指**。对照锚点（不是猜）：

1. daemon 快照源：`/Volumes/nvme/Projects/远程Agent安卓/server/internal/bridge/bridge.go:62` — `capture-pane -e -p`，**无** `-J`。现场同一瞬间 `-e` 不比 `-p` 多超宽行。
2. 客户端剥 ANSI / 切行：`src/term/garbleDetect.js:6`（`CSI_OR_ESC` `/gs`）、`:32-34` `stripAnsi`、随后按 `\n` 分行。本批 `n_lines` 与 `raw_nl+1` 一致，dotAll 与 `/g` 行数一致 ⇒ **不是本批 115 的原因**。
3. `-e` 行尾 SGR 搞坏切行：若成立，`-e` 应比 `-p` 少 `\n` 或 dotAll 吃行。观测 `e_fewer_nl_than_p=0`、`strip_dotall_joins=0` ⇒ **本批未发生**。

真正会粘行的是 tmux **`capture-pane -J`**（隔离夹具 + 现场若干 pane `j.raw_nl << p.raw_nl`、max_w 到 977）。标注器走的是 snapshot/`-e`，不是 `-J`。

本格不改 `detectGarble` 阈值。余下问题：那 4 条网格真 115 从哪来（应用写超宽 / 别的），不是切行假阳。

## 5. 判据表

| # | 判据 | 态 |
|---|---|---|
| a | 本文件 + 三取法表 + n=55 | 通过 |
| b | 裁定：115 为真行，粘行不成立 | 通过 |
| c | 粘行未坐实 ⇒ 无「谁粘」文件:行可定罪；对照锚点已写 | 不适用 |
| d | `npm test` 129 pass / 0 fail（棘轮 ≥129） | 通过 |
| e | 未改 detectGarble | 通过 |

verdict: pass
