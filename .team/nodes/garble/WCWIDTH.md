# WCWIDTH · t.wcwidth（ledger.garble-truthsource-r6 t.wcwidth r1）

工作树：`.worktrees/wt-wcw`（`feat/garble-wcwidth-r1`）。基线 `origin/main` = `1dc8673`（#74）。

**派单 vs 简报：** 派单写不 commit。简报 §5 以简报为准。本格 **commit + push + `gh pr create`**，不 merge。⛔ 未实施修复。

**隐私：** 只落码点 / Unicode 块 / 占格 / 计数。未落行文、pane 正文、token。

---

## 一行复现

```
cd /Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-wcw && node .team/nodes/garble/run-wcwidth.mjs
```

配方：对 listing 全部会话订 39×114 收 snapshot；同时只读 `capture-pane -p`（无 `-J`）。超宽行只在内存里走。tmux 占格在**自己的** socket `/tmp/tmux-501/amw` 上量（`PS1=` 的 bash，`#{cursor_x}` 减基线），⛔ 不往用户 pane 发键。

xterm 占格：`@xterm/xterm` 6，`write` 回调后 `getCell(0).getWidth()`。

---

## 码点表（溢出点 + 非汉字宽字符）

本轮：55 snapshot，其中 `garbled && mlw=115` **6** 条。剥 ANSI 后 xterm 累加宽度 >114 的行：**snapshot-e 11 条**，**capture-pane -p 4 条**。

对「累加宽度刚超过 114 的那个码点」以及同批行里的全角标点，在独立 20 列 pane 里量 tmux 占格：

| 码点 | Unicode 块 | tmux 占格 | xterm 占格 | 出现次数 | 其中作为溢出点 |
|---|---|---:|---:|---:|---:|
| U+7684 | CJK Unified Ideographs | 2 | 2 | 29 | 3 |
| U+6B65 | CJK Unified Ideographs | 2 | 2 | 9 | 2 |
| U+7ED3 | CJK Unified Ideographs | 2 | 2 | 6 | 2 |
| U+5047 | CJK Unified Ideographs | 2 | 2 | 6 | 2 |
| U+5F80 | CJK Unified Ideographs | 2 | 2 | 4 | 2 |
| U+662F | CJK Unified Ideographs | 2 | 2 | 19 | 1 |
| U+8FDB | CJK Unified Ideographs | 2 | 2 | 4 | 1 |
| U+8A00 | CJK Unified Ideographs | 2 | 2 | 2 | 1 |
| U+7EA6 | CJK Unified Ideographs | 2 | 2 | 2 | 1 |
| U+FF0C | Halfwidth and Fullwidth Forms | 2 | 2 | 13 | 0 |
| U+3002 | CJK Symbols and Punctuation | 2 | 2 | 12 | 0 |
| U+FF08 | Halfwidth and Fullwidth Forms | 2 | 2 | 5 | 0 |
| U+300C | CJK Symbols and Punctuation | 2 | 2 | 5 | 0 |
| U+300D | CJK Symbols and Punctuation | 2 | 2 | 5 | 0 |
| U+3001 | CJK Symbols and Punctuation | 2 | 2 | 5 | 0 |
| U+FF1A | Halfwidth and Fullwidth Forms | 2 | 2 | 4 | 0 |
| U+FF1B | Halfwidth and Fullwidth Forms | 2 | 2 | 2 | 0 |
| U+FF09 | Halfwidth and Fullwidth Forms | 2 | 2 | 2 | 0 |

**mismatch 行数：0。** 量到的每一个码点，tmux 与 xterm 占格相同。溢出点全是汉字（双方都是 2），不是 Ambiguous / emoji / VS16。

量具自检（独立 pane）：`A`→1、`中`→2、`U+FF5E`→2、`─` U+2500→1，与 xterm 一致。

完整 JSON：`.team/nodes/garble/wcwidth-table.json`。

---

## 判据 b（最小复现）

**不适用。** 没有「tmux=1、xterm=2」的码点可拿去单独复现。

---

## 假说被推翻

PANEWIDTH 并上「mlw=115」之后，看起来像 wcwidth 分歧。本格把**现场超宽行里实际出现的码点**逐个放到 tmux 里量占格，**没有找到分歧**。

因此：114 列网格里出现 115 显示宽，**不是**「tmux 把某字当 1 列塞进去、xterm 当 2 列」。

snapshot（daemon `capture-pane -e`）超宽行 **11**，同时刻 `-p` 只有 **4**。更多的 115 来自 **-e 剥 ANSI 之后的「逻辑行」**，不一定等于 tmux 一格一行的网格。

---

## 下一个该查的（假说推翻后的下一刀）

**`capture-pane -e` 的换行 vs 网格行。** 具体做：同一 pane、同一瞬间，只统计 `-e` 与 `-p` 剥 ANSI 后「xterm 宽 >114 的行数」和每行码点数（仍不落正文）。若 `-e` 多出来的超宽行在 `-p` 里是两行 ≤114，则 115 是 **ANSI/折行拼接**，不是占格表。那一刀对得上「pane=114 但 snapshot 文本行=115」。

不建议再扫 Ambiguous 全表当主路径——现场溢出点已经是双方都认 2 的汉字。

---

## 候选修法（本格不实施）

这些是**假如**以后证明是宽度表问题才值得动的；**当前证据不支持做它们**。

| 方案 | 做什么 | 代价 |
|---|---|---|
| `@xterm/addon-unicode11` | 换 xterm 宽度表去贴更新的 Unicode | 与 tmux 仍可能不一致；本格量到的现场码点两边已一致，换表**治不到**这次 115 |
| 客户端按 tmux 表算宽 | 自己维护一份与 tmux `utf8_width` 对齐的表，标注器改用它 | 维护成本高；本格现场码点已对齐，改表不会让 115 变 114 |
| 修 snapshot 源 | 让镜像用与网格一致的切行（或不要在剥 ANSI 后把两行粘成一行） | 碰的是 daemon `capture-pane -e` 语义；上游只读，只能记 BACKLOG 或只在客户端按 CUP/折行重切。未证实前 ⛔ 不要做 |

---

## 判据对账

| # | 结果 |
|---|---|
| a | 本表含具体码点；并写明两边逐字符一致 |
| b | 无不一致码点，最小复现不适用 |
| c | 方案见上，未实施 |
| d | `npm test` 见收工（≥123） |
| e | 假说推翻；下一刀见上节 |

verdict: pass
