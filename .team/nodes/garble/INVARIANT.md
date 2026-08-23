# t.invariant —— 捕获宽度 == 渲染网格宽度

账本 `ledger.garble-invariant-r12` / 任务 `t.invariant`。工作树 `.worktrees/wt-inv`，基线 `main = 7afbed7`。

## 做了什么

根因已由上游实测 + leader 用 `wide-host.snapshot.bin` 复核：235 列捕获画进 114 列网格会 wrap 撕开。本格把它收成不变量，三件一次一条：

| # | 改动 | 实现 | 单独验 |
|---|---|---|---|
| A | 几何落定后再 subscribe | `SameWidthController.settle`；`TerminalPane` 去掉点开即订，首订走 `onResize`（fit/webgl 的 120ms 落定） | `test/same-width.test.js` A |
| B | 网格变了重发 subscribe | `nextAction` 在 sent≠grid 时返回 subscribe；不再用 `resize` 当改宽回执（no-op 不补快照） | 同文件 B |
| C | 错宽帧不画；改宽先 reset | `acceptSnapshot`/`acceptDelta`；`TerminalView._commitGrid` 在已有快照时先 `reset` 再 `resize` | 同文件 C + `terminal.test.js` |

选状态机而不是打开全局 `convertEol` / 裁行：协议 snapshot 没有宽度字段，捕获宽度 = 上一次 `subscribe` 的 cols。只作用于画帧门闩 + 首订时机，不改宽度计算、不裁行、不动 `detectGarble`（该模块已随 #79 退掉）。

## 判据

| # | 结果 | 证据 |
|---|---|---|
| a 坏态红 | 通过 | 235→114：`bufferLen=152` `wrapped=102` ratio=0.671>50%；行 2 = `/ 500K`。`node --test test/same-width.test.js` |
| b 好态绿 | 通过 | 235→235：`bufferLen=99` `wrapped=49` ratio<0.5，与 leader 复核一致 |
| c 不变量 | 通过 | 自建 tmux+daemon（socket `/tmp/tmux-501/aminv`，一次性 token 注入未打印，未碰 `:9900`）。扰动 open 80 / window-width 100 / split 40，三帧均 `accepted && sent.cols==grid`。见 `invariant-bench.json` |
| d 画面 | 通过（fixture 为主） | 真字节 `wide-host`：窄网格行 2 变成 `/ 500K`，同宽不出现该碎片（正文未落盘）。自建台标记 `INVBOX` 三相位均 `firstCol=0` `hasMark`。短标记在 40 列上不够长，不能单独当撕开齿；撕开齿用 fixture |
| e npm test | 通过 | `# tests 113` `# pass 113` `# fail 0` EXIT:0（≥106） |
| f UI-SPEC | 通过 | 裁定日期 2026-08-23，§6.2 写入同宽不变量 |

复核 fixture 命令：

```
git show ca1f54c:test/testdata/garble/wide-host.snapshot.bin
```

字节 22303；本格喂 114 与 235 列 xterm（`convertEol:false`）。

## 自建台画面读数（标记 INVBOX，无用户 pane 正文）

| 扰动 | sent | 画 | wrap | 标记 |
|---|---|---|---|---|
| open | 24×80 | 是 | 0/24 | y=0 col=0 |
| window-width | 24×100 | 是 | 0/24 | y=0 col=0 |
| split | 24×40 | 是 | 0/24 | y=0 col=0 |

## 真 fixture 画面读数（wide-host.snapshot.bin）

| 网格 | buffer 行 | isWrapped | 行 2（已公开碎片才写） |
|---|---:|---:|---|
| 235（同宽） | 99 | 49 | （正文未落盘） |
| 114（错宽） | 152 | 102 | `/ 500K` |

## 未改任务定义

派单写「不跑 git commit/push」；简报 §5 与席位纪律 §3 授权 worktree 内 commit+push+PR。以简报为准。

verdict: pass
