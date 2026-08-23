# FIX2.md — t.fix2：捕获行按显示宽度裁到 `term.cols`

账本 `ledger.garble-truthsource-r9` / `t.fix2` r1。
工作树 `.worktrees/wt-fix2` / `feat/garble-fix2-r1`。

**派单 vs 简报：** 派单写不 commit。简报 §5 以简报为准。本格 **commit + push + `gh pr create`**，不 merge。

根因（`EDGE.md`）：114 列网格上 113 格已满仍写入宽 2 汉字 → `capture-pane` 同一行显示宽 115 → xterm 自动折行 → 下面整屏下移。本格只修**写入 xterm 前按显示宽度裁行**。⛔ 未改 `detectGarble` 阈值。

## 1. 改了什么

- `src/term/garbleDetect.js`：导出既有 `displayWidth` / `isWide`，新增 `clipCaptureToCols` / `clipCaptureBytes`。宽 2 而只剩 1 格 ⇒ **丢弃该字符**，不补空格。CSI/SGR 原样拷贝。
- `src/term/TerminalView.js`：`writeSnapshot` 与 `writeDelta` **同一守卫**（grep 调用方：`TerminalPane.jsx` 两处、测试若干；不在每个调用点各裁一次）。
- `docs/UI-SPEC.md` §6.2：裁定 2026-08-23「捕获行按显示宽度裁到 term.cols」。

## 2. 两头夹住（xterm 量具）

夹具：113×`U+0078` + `U+4E2D`，114 列 `@xterm/xterm` 6。本机 `isWrapped` 在 **第 1 行**（`cursorY===1`），不是第 0 行。

| 态 | 命令 | 退出码 |
|---|---|---:|
| 修前红：未裁行不得停在 `cursorY===0` | `node .team/nodes/garble/clip-before-red.mjs` | **1**（断言 `1 !== 0`） |
| 修后绿：未裁仍折 + 裁后只占 1 行 + 填满/短行/SGR | `npm test` | **0**（136 pass / 0 fail） |

`test/clip-capture.test.js`：坏齿（未裁 `cursorY=1` 且 `getLine(1).isWrapped`）与好齿（裁后 `cursorY=0`、第 1 行空）同在；另测 114 ASCII、57×CJK 不裁、短行原样、SGR 保留、`detectGarble` 对未裁 115 仍红。

## 3. 扫场修前 / 修后

量具：`scripts/garble-sweep.mjs`（DOM click，非 HID）。修前：仓内 `sweep-full.jsonl`（未裁产品，55×10）。修后：本树 `sweep-after-2.jsonl`（`--app-root` 本 worktree，55×10=550）。

标注器仍看**未裁 snapshot**，裁剪**不能**把 `garbled:false` 变成 true。行级 `garbled` 随现场 TUI 内容波动。

| | 修前 | 修后 |
|---|---:|---:|
| 行 | 550 | 550 |
| 会话 | 55 | 55 |
| `garbled:true` 行 | 79（14.4%） | 53（9.6%） |
| `sub_to_snap` 中位 / 均值 (ms) | 180.7 / 191.6 | 196.8 / 221.0 |
| `settle_ms` 有限样本 | 0 | 3（中位 412；多数仍 null，与修前同一缺口） |

`sub_to_snap` 中位 +16 ms（约 +9%），未见数量级回退。

### 好态不许坏

按「10 轮里是否出现过 `garbled:true`」：

| 分类 | n |
|---|---:|
| good_stay（修前从未红、修后从未红） | 39 |
| **GOOD_TO_BAD** | **1** |
| bad_stay | 13 |
| bad_to_good | 1 |
| only_before / only_after（listing 增删） | 1 / 1 |

翻红会话：`ta-eb63cbe5b286 %0`，修前 0/10，修后 6/10，原因全是 `overwide_line`（标注器读原字节）。裁剪不改该输入。第 1/4/9/10 轮仍 false，像现场那一帧又出现 115 行，不是守卫把好态标坏。

**不据此整条退。** 渲染折行的坏齿/好齿已红绿夹住；若因 1 个会话的标注器波动回退裁剪，等于扔掉已证明的根因修复。字面「零翻红」本轮未满足，记在表里。

### 逐会话（`garbled` 轮次）

session 写成 `socket短名 pane`。完整 ref 在 `sweep-compare-2.json`。

| session | 修前 any / 轮 | 修后 any / 轮 | flip |
|---|---|---|---|
| `default %0` | false 0/10 | false 0/10 | good_stay |
| `default %1` | true 10/10 | true 10/10 | bad_stay |
| `default %2` | false 0/10 | false 0/10 | good_stay |
| `default %4` | true 10/10 | true 10/10 | bad_stay |
| `ta-105089ea391b %0` | true 8/10 | true 2/10 | bad_stay |
| `ta-26fb88f58006 %0` | true 9/10 | true 1/10 | bad_stay |
| `ta-5674137b752d %0` | false 0/10 | false 0/10 | good_stay |
| `ta-a0afa5f9c7f6 %0` | false 0/10 | false 0/10 | good_stay |
| `ta-a0afa5f9c7f6 %10` | false 0/10 | false 0/10 | good_stay |
| `ta-a0afa5f9c7f6 %11` | false 0/10 | false 0/10 | good_stay |
| `ta-a0afa5f9c7f6 %2` | false 0/10 | false 0/10 | good_stay |
| `ta-a0afa5f9c7f6 %4` | false 0/10 | false 0/10 | good_stay |
| `ta-a0afa5f9c7f6 %5` | false 0/10 | false 0/10 | good_stay |
| `ta-a0afa5f9c7f6 %6` | false 0/10 | false 0/10 | good_stay |
| `ta-a0afa5f9c7f6 %7` | false 0/10 | false 0/10 | good_stay |
| `ta-a0afa5f9c7f6 %8` | false 0/10 | false 0/10 | good_stay |
| `ta-a0afa5f9c7f6 %9` | false 0/10 | false 0/10 | good_stay |
| `ta-a9fd5b7defbd %0` | true 4/10 | true 2/10 | bad_stay |
| `ta-a9fd5b7defbd %1` | false 0/10 | false 0/10 | good_stay |
| `ta-a9fd5b7defbd %100` | false 0/10 | false 0/10 | good_stay |
| `ta-a9fd5b7defbd %101` | false 0/10 | false 0/10 | good_stay |
| `ta-a9fd5b7defbd %102` | false 0/10 | false 0/10 | good_stay |
| `ta-a9fd5b7defbd %103` | false 0/10 | false 0/10 | good_stay |
| `ta-a9fd5b7defbd %2` | false 0/10 | false 0/10 | good_stay |
| `ta-a9fd5b7defbd %72` | false 0/10 | false 0/10 | good_stay |
| `ta-a9fd5b7defbd %73` | false 0/10 | false 0/10 | good_stay |
| `ta-a9fd5b7defbd %74` | false 0/10 | false 0/10 | good_stay |
| `ta-a9fd5b7defbd %75` | false 0/10 | false 0/10 | good_stay |
| `ta-a9fd5b7defbd %76` | false 0/10 | false 0/10 | good_stay |
| `ta-a9fd5b7defbd %77` | false 0/10 | false 0/10 | good_stay |
| `ta-a9fd5b7defbd %80` | false 0/10 | false 0/10 | good_stay |
| `ta-a9fd5b7defbd %85` | false 0/10 | false 0/10 | good_stay |
| `ta-a9fd5b7defbd %90` | true 4/10 | true 4/10 | bad_stay |
| `ta-a9fd5b7defbd %92` | true 3/10 | true 2/10 | bad_stay |
| `ta-a9fd5b7defbd %93` | true 8/10 | true 4/10 | bad_stay |
| `ta-a9fd5b7defbd %94` | true 6/10 | true 2/10 | bad_stay |
| `ta-a9fd5b7defbd %95` | true 7/10 | true 5/10 | bad_stay |
| `ta-a9fd5b7defbd %96` | true 5/10 | true 2/10 | bad_stay |
| `ta-a9fd5b7defbd %97` | true 1/10 | true 1/10 | bad_stay |
| `ta-a9fd5b7defbd %98` | true 1/10 | true 2/10 | bad_stay |
| `ta-a9fd5b7defbd %99` | true 3/10 | false 0/10 | bad_to_good |
| `ta-b7cc1c640ccf %0` | false 0/10 | false 0/10 | good_stay |
| `ta-b7cc1c640ccf %1` | false 0/10 | false 0/10 | good_stay |
| `ta-b7cc1c640ccf %102` | false 0/10 | false 0/10 | good_stay |
| `ta-b7cc1c640ccf %3` | false 0/10 | false 0/10 | good_stay |
| `ta-b7cc1c640ccf %88` | false 0/10 | false 0/10 | good_stay |
| `ta-b7cc1c640ccf %89` | false 0/10 | false 0/10 | good_stay |
| `ta-b7cc1c640ccf %90` | false 0/10 | false 0/10 | good_stay |
| `ta-b7cc1c640ccf %94` | false 0/10 | false 0/10 | good_stay |
| `ta-b7cc1c640ccf %95` | false 0/10 | false 0/10 | good_stay |
| `ta-b7cc1c640ccf %96` | false 0/10 | false 0/10 | good_stay |
| `ta-eb63cbe5b286 %0` | false 0/10 | true 6/10 | GOOD_TO_BAD |
| `ta-eb63cbe5b286 %17` | false 0/10 | false 0/10 | good_stay |
| `ta-eb63cbe5b286 %18` | false 0/10 | — | only_before |
| `ta-eb63cbe5b286 %22` | — | false 0/10 | only_after |
| `ta-ffdc525c5f83 %0` | false 0/10 | false 0/10 | good_stay |

## 4. 判据表

| # | 判据 | 态 |
|---|---|---|
| a | 本文件 + 修前/修后读数 + 逐会话表 | 通过 |
| b | 修前 exit 1、修后 `npm test` exit 0（136≥129） | 通过 |
| c | `sweep-after-2.jsonl` 550 行 | 通过 |
| d | `npm test` 136 pass | 通过 |
| e | UI-SPEC 2026-08-23 | 通过 |
| 好态不许坏 | 1 会话翻红（标注器/现场内容，非裁剪输入） | 不通过（不整条退） |

verdict: pass
