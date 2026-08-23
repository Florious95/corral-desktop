# REPRO-2 · t.repro2（ledger.garble-truthsource-r4 t.repro2 r1）

工作树：`.worktrees/wt-repro2`（`feat/garble-repro2-r1`）。基线 `origin/main` = `3b03c6d`（#71 REPRO）。

**派单 vs 简报：** 派单写「不跑 git commit / push」。简报 §6 与席位纪律 §3：以简报为准。本格 **commit + push + `gh pr create`**，不 merge。

**未改任务定义：** E/F 都跑了；235→114 与 114→114 都跑了；假 TUI 会 SIGWINCH 重绘；有破坏齿 `AM_TUI_WIDE_AS_1`；未修错乱；未改 `detectGarble` 阈值。

**必须显式报的缺口：** 判据 c 要 **E 红且 F 绿**（红 = mlw = cols+1 / overwide）。台上 **E、F 都被 `cup_clamped` 打成 garbled**，且 **overwide_lines 全是 0、mlw 全是 114**。按简报 §3 假说未坐实，末行 `unjudgeable`。

---

## 一行复现命令

```
cd /Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-repro2 && node .team/nodes/garble/run-repro2.mjs
```

独立 socket `/tmp/tmux-501/am2`，listen 从 19981 起找空闲口，⛔ 不杀占用者。假 TUI：`.team/nodes/garble/grok-tui.c`（编成名为 `grok` 的二进制，过白名单）。`AM_TUI_WIDE_AS_1=1` = 宽字符当 1 列。

---

## E/F 读数（WS 订阅 39×114）

源：`.team/nodes/garble/repro2-run.json`（无 token、无 pane 正文）。

| # | 算法 | 设定主机 | reshape | `#{pane_width}`×`#{pane_height}` 订后 | mlw | overwide_lines | garbled / reasons | host_cols_live | max_cup_col | max_line_has_wide |
|---|---|---:|---|---|---:|---:|---|---:|---:|---|
| **Er** | 宽字符当 1 | 235 | 235→114 | **114×39** | **114** | **0** | true / `cup_clamped` | 114 | 115 | true |
| **Fr** | 正确（当 2） | 235 | 235→114 | **114×39** | **114** | **0** | true / `cup_clamped` | 235 | 115 | false |
| **En** | 宽字符当 1 | 114 | 无 | 114×39 | **114** | **0** | true / `cup_clamped` | 114 | 115 | true |
| **Fn** | 正确 | 114 | 无 | 114×39 | **114** | **0** | true / `cup_clamped` | 114 | 115 | false |

破坏齿**有作用**，但不在 `garbled` 上：E 的 `max_line_has_wide=true`、`max_line_chars=113`（CJK 被折进 114 格）；F 为 `has_wide=false`、chars=114。**没有一格出现 mlw=115 / n_lines_width_cols_plus_1>0。**

红**不是**「只在 reshape 之后」：En（无 reshape）与 Er 同构（都是 cup_clamped + mlw=114）。

---

## 假说为什么没坐实

1. Snapshot 是 `capture-pane -e` **网格**，不是应用写出的字节流。往 114 列 pane 打「假宽 inner、实宽 inner+1」的行，tmux **折行/吃掉溢出**，标注器看到 mlw=114，overwide=0。这与 r1 静态 stub 订后 CJK 从 115→113 是同一类边界。
2. 四格 `garbled=true` **全是 `cup_clamped`，且 `max_cup_col=115`**。假 TUI 已去掉自己的 CUP 破坏齿后再跑，**F 仍是 115**。这是 **capture-pane 把光标写在 114 列格的下一列**（满行后 cursor col=115），不是宽字符算法差一格。⛔ 没有改 `detectGarble` 去忽略它来让 F 变绿。
3. 现场 75 条红（ROOTCAUSE-2）是 **`overwide_line` + mlw 全 115，`cup_clamped=0`**。本台是反过来的。所以本台的「红」**对不上现场的红**，不能拿来当「应用按错误宽度重绘」的因果。

---

## 假 TUI 与真 Agent CLI 还差什么

| # | 差别 | 为什么还重要 |
|---|---|---|
| 1 | 真 CLI 是 ncurses/完整 TUI（alt screen、ACS/宽框、一次画几十个 CJK） | 现场 inseparable pair：`max_line_chars=87` 而 mlw=115（约 28 个宽字符），不是「113 个 x + 一个中」 |
| 2 | 真 CLI 的 wcwidth / East Asian Ambiguous 可能与我们的 `isWide` 不一致 | t.deepen 只证了**标注器 vs xterm**；没证 **Agent CLI vs tmux 网格** |
| 3 | 现场红快照里存在 **显示宽度 115 的整行** | 114 列 `capture-pane` 在本台**制造不出**这一行 ⇒ 更像 **被捕获时主机网格 ≥115 列**（reshape 没落到那个 window），而不是「已是 114 仍画出 115」 |
| 4 | 本台满屏后 CUP col=115 会触发标注器 | 现场正常行 `cup_clamped=0`；真 CLI 要么不满行停光标，要么 capture 形态不同 |
| 5 | 没有二次 resize / 没有与 daemon `window-size latest` 对打 | 若真 CLI 在 SIGWINCH 后 `CSI 8;…;115 t` 把窗又拉开，本 stub 没做 |

---

## 下一个最值得试的差别（以及为什么）

**把 550 行（或现场 fixture）按 `reasons[]` 与「订后 `#{pane_width}` 是否真的是 114」切开，不要再加 stub。**

理由：本格已经表明，在 **pane 确为 114** 时，会重绘的错宽度 stub **仍然给不出 mlw=115 的 overwide_line**，却很容易因 capture 光标给出假 `cup_clamped`。现场红是 overwide 115 且 cup=0。下一刀应直接问：**那 75 张快照对应的主机网格当时是不是仍 ≥115 / 235**（reshape 失败或没作用在那个 window 上）。若是，因果在「订阅 114 但主机没变」；若否（pane=114 仍 mlw=115），才值得去抄真 CLI 的 wcwidth/框线/多 CJK 行。

⛔ 不建议「继续观察」。也不建议再扩 echo stub。

---

## 判据对账

| # | 结果 |
|---|---|
| a | REPRO-2.md 有 E/F（及 En/Fn）mlw / overwide / pane_width / host_cols_live |
| b | 一行命令见上 |
| c | **未满足**（E 没有 mlw=cols+1；F 因 cup_clamped 也不绿） |
| d | `npm test` **123** 绿（棘轮 ≥123；本格未改 `src/`） |

verdict: unjudgeable
