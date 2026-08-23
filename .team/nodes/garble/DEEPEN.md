# DEEPEN · t.deepen（ledger.garble-truthsource-r2 t.deepen r1）

工作树：`.worktrees/wt-deepen`（`feat/garble-deepen-r1`）。基线 `origin/main` = `48a62b9`（#67 ROOTCAUSE）。

**派单 vs 简报：** 本回合派单写「不跑 git commit / push」。简报 §5 写明那是编排缺口、以简报为准（前三格烂在 worktree）。本格 **按简报 commit + push + `gh pr create`**，不 merge。

---

## §1 标注器是不是在说谎？

**裁定：解释 A。** 主机（在我们以 114 列订阅、daemon 把 pane 往 114 拉之后）仍然发出了 **显示宽度 115** 的行；xterm 114 列会折；`detectGarble.displayWidth` 与 xterm 逐码点宽度 **一致**。不是标注器假阳。

不是 B（`displayWidth` 多数一格）。不是「两者都不是」的第三种：逐字宽对齐之后，整行在 114 列折、在 115 列不折，与 115 的标签同构。

### 量具（阳性对照，先验尺子）

夹具 `test/testdata/garble/wide-host.snapshot.bin`（真 235 列 TUI）喂进真实 `@xterm/xterm` 6（Node 直接 `new Terminal`，`allowProposedApi`，`write` 回调后再读 `buffer.active.getLine(i).isWrapped`）：

| 网格 | `bufferLength` | `wrappedLines` |
|---|---:|---:|
| 114×39 | 152 | **102** |
| 80×24 | 196 | **146** |
| 235×50 | 99 | 49 |

**尺子有分辨力：** 宽快照在窄网格上大量 `isWrapped`。235 列上仍有 49 条 wrap，是「行宽恰好等于列数时游标进下一行」的 xterm 行为，不推翻窄网格上的阳性。

粗算「整份快照有没有任意 isWrapped」**不能**当 A/B 判据：`maxLineWidth=114` 的正常快照在 114 列上也有 wrap（满行/CUP）。必须把 **被判 115 的那一行** 剥 ANSI 后单独喂。

### 被判 115 的真字节

`sweep-full.jsonl` 只有 `bytes` 长度。按 `capture-fixtures.mjs` 配方从 tauri store 取 url/token（`set` 注入式读取脚本，**未打印**），以巡检几何 **39×114** 订阅后抓 payload。

活样本与 ROOTCAUSE「永远错乱的 default %1、bytes=4083、mlw=115、overwide=1、max_box_run=114」对得上：

| | 值 |
|---|---|
| listing（抓的时候） | **235×50** |
| 订阅 | 39×114 |
| snapshot 字节 | 4083 |
| `detectGarble` @114 | garbled，`overwide_line`，mlw=**115**，overwideLines=1，maxBoxRun=114 |
| 该超宽行 | 71 个码点，其中 44 个宽字符，`displayWidth=115` |

同批还抓到若干 mlw=115 的会话（overwide 2–4），形态相同（差 1 列 + 含宽字符），不是 235 列整屏。

### xterm 折行读数（隔离超宽行，不要整屏 isWrapped）

同一行纯文本（已剥 ANSI、trim 尾空格）：

| 终端列数 | 折行 | 说明 |
|---|---|---|
| **114** | **是**（第 0 行 `isWrapped=false`，第 1 行 `isWrapped=true`） | 解释 A 的判据 |
| **115** | **否**（无后继 wrap 行） | 行在 115 列网格里放得下 |
| **116** | 否 | 对照 |

逐码点：把该行每个字符单独写入 10 列 xterm，比较 `displayWidth(ch)` 与 xterm 占用格。**diffs = []，双方合计都是 115。** 排除「我们的 `isWide` 表比 xterm 多数一格」。

整份快照写入 114 列 xterm 时 `maxOccupiedCells=114`（物理行不会宽过网格，多出来的 1 格在下一行），与「折了 1 列」一致。

### 和用户截图 / WHY-STUCK 的关系

A 成立 ⇒ 这 79 条**不是**标注器把正常画面打成错乱。它们是 **1 列超宽**（常含 CJK 宽字符），盒子跑长仍是 114，**不是** 235 列 TUI 塞进窄格。

订阅 114 之后 listing 仍可能报 235：daemon 接受了 reshape，TUI 重排后最宽行停在 115，而不是整屏 235。所以 ROOTCAUSE 推翻「错乱=235 快照」在这批标签上仍然成立；本格补上的是「115 是真宽度，不是 displayWidth 假阳」。

---

## §2 四条埋点

| # | 位置 | 落地 |
|---|---|---|
| 1 | `client.js` `subscribe` / `replaySubscriptions` | 事件带 `host_rows`/`host_cols`/`listing_seq` |
| 2 | `client.js` `handleFrame` listing / list_delta | `recordHostGeom`；removed 走 `forgetHostGeom` |
| 3 | `garbleDetect.js` metrics | `maxLineChars`、`maxLineHasWide`；`garble_label` 同步打点。⛔ 正文不进环 |
| 4 | `amDiag.js` `touchSettle` | `SETTLE_QUIET_MS=100`：一次 `garble_label` 后 100ms 内无 `term_resize`/`write_snapshot` 则 `t_stable = t_label+100`。**环 `reset()` 不清 host 表** |

`window.__amDiag.hostGeomOf(ref)` 可在 CDP 里查表。

---

## §3 巡检有没有碰到用户那种错乱？

**碰到的是真的 1 列折行，不是用户截图那种「画面撕开、框线断裂」。** 允许的「我判不出来」只适用于「那张截图的充分条件」，不适用于本格 A/B。

已排除：

- 标注器对这批 115 的假阳（§1）。
- 「本轮 79 条 = 235 列快照进 114」（mlw 全是 115，盒线 114，xterm 隔离行只折 1 格）。

仍缺、本格没夹住的用户现场条件（候选，不是根因裁定）：

1. **视口**：巡检 headless 1100×800 → 本地 114 列；用户 `.app` 是真窗口宽度 + **分列**。列宽不同，超 1 列的相对位置也不同。
2. **第二个订阅者偷管**（`WHY-STUCK`）：本轮探针自己是唯一以 114 去订的客户端，会把 pane 往 114 拉。用户桌面若同时开着、或手机端订在 235，主机可能钉在远大于本地的几何，快照才会变成夹具那种 `maxBoxRun=231`。
3. **主机本来就比本地宽很多**：listing 235 在本轮抓包里常见，但 **snapshot 正文已经按 114 重排**。要看到 235 正文，得在**不**用 114 订阅改写主机的情况下收快照（例如桌面已订 235，或订阅后立刻读、赶在 TUI 重排前——本格没做这条竞态）。

---

## 判据

| # | 结果 |
|---|---|
| a | 本文件；§1 = **A**；xterm 隔离行 114 折 / 115 不折；wide-host @114 wrapped=102 |
| b | 四条埋点落地；`npm test` **120** 绿（棘轮 ≥112） |
| c | 判成 A，**未**改 `detectGarble` 阈值（§4c 仅 B 才修 off-by-one） |

副作用：抓包对约 25 个会话短暂 subscribe@114（立即 unsubscribe）。未 kill/open 用户 AgentMirror。若某列冻住：桌面里切走再点开。

脚本（可复现量具，不含 token）：`.team/nodes/garble/probe-xterm-wrap.mjs`、`probe-line-isolate.mjs`、`probe-width-diff.mjs`。活 payload **不入库**（pane 正文）。

verdict: pass
