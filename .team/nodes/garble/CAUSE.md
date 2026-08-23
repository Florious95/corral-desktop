# t.cause · reshape 后没有新输出是不是错排的充要条件

任务书：`.team/nodes/garble/BRIEF-cause.md`。
对照帧 = 同二进制 TUI 在目标几何下画的控制 pane（`want235` / `want157`），逐字节比 `capture-pane -p`。
⛔ 无启发式分数。⛔ 无 PNG / 无 pane 正文入库。本格未改 `src/`。

## 0. 台子（零打扰）

| 项 | 值 |
|---|---|
| tmux socket | `/tmp/amc-tmux/tmux-501/amc`（`TMUX_TMPDIR=/tmp/amc-tmux`） |
| daemon | `127.0.0.1:19171`，`AGENTMIRROR_E2E_DISCOVERY_SOCKET_DIRS` 只扫该目录 |
| `:9900` | **未连** |
| 用户 socket `/tmp/tmux-501/*` | **未扫、未订** |
| 夹具 | `grok-tui.c` + `--ignore-winch` + SIGUSR1 打一行 `HEAL`（非整帧重绘） |
| 跑数 | `.team/nodes/garble/CAUSE-run.json` |

自检：`tmux -S /tmp/amc-tmux/tmux-501/amc list-sessions` 起跑时 10 个会话；收工 `kill-server` 只打这颗 socket。

## 1. 假设（不许改口径）

> 错排 ⟺ 该 pane 在 reshape 之后、抓快照之前，没有产生任何新输出。

事前预测：A 红 / B 绿 / C 绿 / D 绿 / E 红 / F 绿。
判据 c：**A 红且 B 绿且 D 绿** 支撑「reshape 且不重绘」这一半；**任一格与预测不符必须写假设不成立**。

## 2. 六臂（预测 / 实测 / 首个不一致）

主机起盘 **235×50**。订阅窄档 **47×157**（桌面端实测挤窄）。绿 = 与 `want157`（或 D 的 `want235`）逐字节一致。

| 臂 | 预测 | 实测 | 首个不一致 | 备注 |
|---|---|---|---|---|
| **A** `--ignore-winch` + 挤窄 | 红 | **红** | 行 1 列 1；got_len=2097 exp_len=7424 | 挤成 157×47 后无重绘 |
| **B** 正常 SIGWINCH 重绘 + 挤窄 | 绿 | **绿** | — | settle_ms=426 |
| **C** ignore-winch + 挤窄 + SIGUSR1 一行 | 绿 | **红** | 行 1 列 1；got_len=2022 exp_len=7424 | 有新输出，**不是**整帧重绘 |
| **D** 订阅 50×235（不挤窄） | 绿 | **绿** | — | pane 仍 235×50 |
| **E** 两 pane 快切 dwell=600ms ×16 | 红 | **绿** | mismatch_rounds=**0** | TUI 会重绘，600ms 够 |
| **F** 两 pane dwell=2200ms ×16 | 绿 | **绿** | mismatch_rounds=**0** | |

原始 JSON 只含指纹与行列，不含画面。

## 3. 判据 c：假设是否成立

- **A 红、B 绿、D 绿**：成立。错排的充分条件是 **reshape 到更窄几何且进程不按新尺寸重绘**。D 绿 ⇒ 不是渲染器本身；元凶是挤窄。
- **C 与预测不符（预测绿、实测红）**：**推翻「有任何新输出 ⇒ 自愈」**。一行 `HEAL` 改了指纹（`9b096bd3…`→`588617ed…`）但整帧仍对不上 `want157`。
- **E 与预测不符（预测红、实测绿）**：**推翻「600ms 快切必错排」**（在会 SIGWINCH 重绘的假 TUI 上）。16/16 对齐 `want157`。

⇒ **作为充要条件的原假设不成立**（C、E 两格推翻双向）。
⇒ **收窄后仍成立的单向**：`reshape ∧ 无整帧重绘 ⇒ 错排`；`不 reshape ∨ 整帧重绘 ⇒ 不错排`（本夹具内 A/B/D）。

## 4. 模式二 + 耗时

- E 600ms：16 帧全绿（与「来不及重绘」预测相反；本 TUI 的 `draw()` 远小于 600ms）。
- F 2200ms：16 帧全绿（与预测一致，但在 E 已绿的前提下不再区分停留）。
- 3.4「订阅挤窄 → 与 want157 逐字节一致」10 次（臂 B 路径）：362–376ms，**均值 367ms**。用户 50ms 目标本格不算失败，只报数。

## 5. 反推结论（⛔ 未修）

产品侧发出的订阅宽度来自 fit 后的格子，不是主机 pane 宽：

- `src/components/terminal/TerminalPane.jsx:101` `subscribe(target, act.rows, act.cols)`（`act` 来自 `SameWidthController.settle` / fit）
- `src/vendor/agentmirror/client.js:123` 把该 rows/cols 送进 `subscribe` 帧

daemon 按订阅几何 reshape 主机 pane。本格 **D** 用主机 235 订阅则不挤、绿；**A** 用 157 订阅则挤且不重绘、红。

下一格若修（本格不动手），事前预测：

| 修法 | 应变绿的臂 |
|---|---|
| 订阅改发 listing 主机几何（本格 D） | A 仍红除非同时等重绘；**桌面观感**不再挤碎空闲 TUI |
| 挤窄后等到应用重绘再上屏（本格 B，~370ms） | A 仍红（ignore-winch 进程永远不重绘）；B 维持绿、均值应接近 367ms |
| 只打一行当「自愈」 | **C 已证伪**，不应再当修复 |

空闲真 Agent 更像 A（不处理 SIGWINCH）；活跃更像 B。LABELS 里相邻同几何一坏一好，与「有没有整帧重绘」相容，与「有没有任意新字节」不相容（见 C）。

## 6. 判据表

| # | 结果 | 说明 |
|---|---|---|
| a | 有 | 本文件 |
| b | 有 | 六臂均跑完 |
| c | **假设不成立** | ABD 方向对；**C、E 推翻原充要预测** |
| d | 有 | E 绿 0/16 错；F 绿；均值 367ms |
| e | 有 | 端口 19171；socket 见上；未连 :9900 |
| f | 有 | `npm test` **115** pass（≥113） |
| g | 有 | 产品码未改 |
| h | 有 | 无 PNG 入库（见提交 `git show --stat`） |

verdict: pass
