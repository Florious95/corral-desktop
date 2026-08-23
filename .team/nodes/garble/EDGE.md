# EDGE.md — t.edge：用 `#{cursor_x}` 量整行

账本 `ledger.garble-truthsource-r8` / `t.edge` r1。本格只裁定边界，**不修** `detectGarble`。
量具：`.team/nodes/garble/run-edge.mjs` → `edge-run.json`（码点、列号、cursor、计数；无 pane 正文、无 token）。

**派单 vs 简报：** 派单写不 commit。简报 §6 以简报为准。本格 **commit + push + `gh pr create`**，不 merge。

方法：独立 socket `/tmp/tmux-501/ame`，114×8 pane（进程 `sleep 3600`），`printf` 等价于对 `#{pane_tty}` 写字节（CSI home+erase 后写行，不经 bash）。写完读 `#{cursor_x}` `#{cursor_y}`。现场行只在内存：订 39×114、等 snapshot、且 `#{pane_width}=114` 后才 `capture-pane -p`，只重放 **our_w=115** 的行。

## 1. 量具自检（两个边界形状）

lab `pane_width=114`。

| 形状 | 夹具 | our_w | cursor_x | cursor_y | 裁定 |
|---|---|---:|---:|---:|---|
| 宽字符跨最后一列 | 113×`U+0078` + `U+4E2D` | 115 | 2 | **1** | tmux 换行（把宽字符整颗移到下一行，x=2） |
| 恰好填满 ASCII | 114×`U+0078` | 114 | **114** | 0 | 双方都认为刚好 |
| 恰好填满 CJK | 57×`U+4E2D` | 114 | **114** | 0 | 双方都认为刚好 |
| 差一格 | 113×`U+0078` | 113 | 113 | 0 | 双方一致 |

跨列夹具的第一换行点：前缀 still `cursor_x=113` `cursor_y=0` `our_w=113`；下一个 `U+4E2D` 后 `our_w=115` 且 `cursor_y=1`。**坏态红、好态绿，量具有分辨力。**

`displayWidth`（`garbleDetect.js:9-18`，`isWide` `:21-30`）在填满两条上与 tmux 一致，不是「永远多 1」。

## 2. 现场 4 条真 115

订宽后 pane=114、`capture-pane -p`、our_w 恰为 115：**4 条**（与 LINES 一致）。重放到 114 列 lab pane：

| # | n_chars | 整行 cursor | 裁定 | 第一换行码点 | 换行前 tmux 列 | 换行前 our_w | our_delta |
|---|---:|---|---|---|---:|---:|---:|
| 1 | 77 | x=2 y=1 | tmux_overflow | U+6B65 CJK | 113 | 113 | 2 |
| 2 | 61 | x=2 y=1 | tmux_overflow | U+7684 CJK | 113 | 113 | 2 |
| 3 | 61 | x=2 y=1 | tmux_overflow | U+5F80 CJK | 113 | 113 | 2 |
| 4 | 71 | x=2 y=1 | tmux_overflow | U+5047 CJK | 113 | 113 | 2 |

`we_overcount=0`。四条都是 **113 列已占用、再写一个宽=2 的汉字 → tmux 换行**，与 §1 跨列夹具同一形状。换行前 `cursor_x === our_w === 113`，没有「我们先多算 1、tmux 还停在同一行」。

## 3. 裁定

**tmux 也认为超宽。** 不是 `displayWidth` 在上下文里把 114 当成 115。

简报 §1.2：`cursor_y` 换行 ⇒ 115 是真超宽。4/4 换行。若是「我们多算」，写完整行后应仍 `cursor_y=0` 且 `cursor_x≤114` —— **未发生**。

因此判据 c 不适用（不指 `garbleDetect.js` 某行当根因）。

## 4. 下一刀该查谁写的

应用（pane 里的 Agent TUI）往 **114 列网格**里画了一行「113 个单元格 + 一个宽字符」。孤立码点占格双方都是 2（WCWIDTH）；切行也不是粘出来的（LINES）。本格证明：**按字节重放，tmux 会把那颗汉字折到下一行**；但现场 `capture-pane -p` 仍给出**单行 115**（LINES）。那是「网格上已经有一颗卡在最后一列的宽字符，capture 把整颗码点留在同一行」的序列化，不是客户端累加器单独发疯。

下一格查：**谁在 114 列下写出「最后只剩 1 格却仍写宽字符」**（Agent CLI 画框/折行），而不是改 `detectGarble` 的阈值。本格不修。

## 5. 判据表

| # | 判据 | 态 |
|---|---|---|
| a | 本文件含两个边界形状读数 | 通过 |
| b | 裁定：tmux 也认为超宽 | 通过 |
| c | 我们多算 | 不适用 |
| d | 下一刀：谁在 114 下列尾写宽字符 | 通过 |
| e | `npm test` 129 pass / 0 fail | 通过 |

verdict: pass
