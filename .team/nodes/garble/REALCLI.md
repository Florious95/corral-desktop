# t.realcli · 真 cursor-agent 被挤窄后会不会自己整帧重绘

任务书：`.team/nodes/garble/BRIEF-realcli.md`。
对照口径与 `t.cause` 相同：绿 = `capture-pane -p` 与同 CLI 在目标几何下**另起的控制 pane**逐字节一致（`cause-diff.mjs` / `firstMismatch`）。
CLI：`/Users/alauda/.local/bin/cursor-agent`（未换 `claude`）。未发 prompt、未敲 Enter、未触发模型调用。B′ 仅在自建 pane 上 `send-keys Up`。
⛔ 无启发式。⛔ 无 PNG / 无 pane 正文入库。本格未改 `src/`。

夹具：`.team/nodes/garble/run-realcli.mjs`，跑数 `.team/nodes/garble/REALCLI-run.json`。

**口径限制（显式，不是静默改任务）**：真 CLI 两份同几何实例的首屏**不是**确定性字节副本（D′ 在 pane 仍 235×50、订阅未改指纹的情况下仍对不上 `want235`）。任务书的「绿 = 对上控制 pane」因此**不能**单独当「有没有整帧重绘」的判据。§1 的回答改由 **reshape 后指纹是否继续变** 给出；四臂的逐字节表仍按任务书口径照记。

## 0. 台子（零打扰）

| 项 | 值 |
|---|---|
| tmux socket | `/tmp/amr-tmux/tmux-501/amr`（`TMUX_TMPDIR=/tmp/amr-tmux`） |
| daemon | `127.0.0.1:19271`，`AGENTMIRROR_E2E_DISCOVERY_SOCKET_DIRS=/tmp/amr-tmux/tmux-501` |
| `:9900` | **未连**（`used_9900: false`） |
| 用户 socket `/tmp/tmux-501/*` | **未扫、未订**（`scanned_user_tmux: false`） |
| 收工 | 按 **pid** `SIGTERM` 自建 daemon；`tmux -S <上表 socket> kill-server` 只打这颗 |

第二次正式跑：六会话共用 `cwd-realcli/shared`（第一次各会话不同 cwd，会把路径写进 TUI，污染逐字节比；已作废）。listing 按 tmux session `name` 选会话。

## 1. §1 唯一问题

> 真 Agent CLI 在被挤窄之后，会不会自己整帧重绘？

**不会（空闲首屏）。** 不是「会」、也不是「只是慢」。

| 读数 | 实测 |
|---|---|
| 挤窄瞬间 `capture-pane` 指纹 | **变**（三臂 `fp_changed_at_reshape: true`）—— wrap / 一次 SIGWINCH 残画，对不上 `want157` |
| 挤窄之后、抓快照之前（A′ 3s / A″ 30s / B′ 键后 3s） | **再无新指纹**（`first_fp_change_ms: null`，`fp_change_count: 0`） |
| A″ | 等满 30s **未转绿**，没有「慢重绘」秒数可报 |
| B′ `send-keys Up` | 指纹在随后 3s **仍不变**，没有整帧对齐 `want157` |

⇒ `t.cause` 收窄后的单向（`reshape ∧ 无整帧重绘 ⇒ 错排`）在真 CLI 空闲首屏上**仍然成立**；**不能**用假 TUI 的 B（SIGWINCH 整帧）去套这个 CLI。用户「一打开就坏」与「订阅把主机 pane 挤到 fit 列、进程不按新尺寸整帧重绘」相容。本条线索**没有**在真 CLI 上被证伪。

## 2. 四臂（预测 / 实测 / 首个不一致 / 长度）

主机起盘 **235×50**。挤窄订阅 **47×157**。控制 `want157` fp=`2eb1c535632a69b1`；`want235` fp=`31b9908121a6367c`（控制 pane 在整场矩阵后仍同一指纹：`control_want235_still_same: true`）。

| 臂 | 预测 | 实测 | 首个不一致 | got_len / exp_len | reshape 后指纹 |
|---|---|---|---|---|---|
| **A′** 挤窄、无输入、3s | 红 | **红** | 行 4 列 13 | 280 / 284 | 挤窄瞬间变；之后 3s 不变 |
| **A″** 同 A′、30s | 红 | **红** | 行 4 列 8 | 301 / 284 | 挤窄瞬间变；之后 30s 不变 |
| **B′** 挤窄 + `Up` | 绿 | **红**（预测被推翻） | 行 4 列 8 | 267 / 284 | 挤窄瞬间变；键后 3s 不变 |
| **D′** 订阅 235 | 绿 | **红**（预测被推翻） | 行 4 列 8 | 273 / 301 | pane 仍 235×50；**同 pane** 订阅前后指纹相同 |

D′ 补充（**不是**任务书改口径，只解释红）：`fp_changed_by_subscribe: false`。不挤窄时订阅不改画面；红来自**另一份**同几何 `cursor-agent` 实例对不上，不是渲染器把 235 画坏。

B′ 推翻「方向键会促整帧重绘」。空闲 cursor-agent 首屏对 `Up` 无可见重绘。

## 3. 产品发出点（本格复核，未改）

仍是 fit 列，不是 listing 主机列：

- `src/components/terminal/TerminalPane.jsx:101` `subscribe(target, act.rows, act.cols)`（`act` 来自 `SameWidthController.settle` / fit）
- `src/vendor/agentmirror/client.js:123` 把该 rows/cols 送进 `subscribe` 帧

三臂挤窄后 `pane_after` 均为 `157x47`；D′ 为 `235x50`。与上一格一致：daemon 按订阅几何 reshape 主机 pane。

## 4. 三个候选修法（⛔ 未实现）

| 候选 | 代价 | 本格证据 | 若实现，事前预测哪臂红→绿 |
|---|---|---|---|
| ① 订阅改发**主机几何** | 显示层（字号/横滚） | **支持**：D′ 同 pane 在 235 订阅下指纹不变、几何不变；错排充分条件是挤成 157。跨实例 D′ 红**不反对**①，只说明「绿=另一份进程」量具对真 CLI 过严 | A′/A″/B′ 的**几何**不再被挤；跨实例逐字节仍可能红（量具），但用户「打开即碎」应消失 |
| ② 仍挤窄，等到应用重绘再上屏 | 首屏变慢 | **反对（空闲真 CLI）**：A″ 30s 零后续指纹，没有可等的整帧 | A′/A″ **仍红**（不会出现 cause 假 TUI 那 367ms 绿） |
| ③ 挤窄后发键促重绘 | 向 pane 注入按键 | **反对（本键）**：B′ `Up` 后 3s 指纹不变 | B′ **仍红**；换别的键本格未测，副作用风险仍高 |

## 5. 判据表

| # | 结果 | 说明 |
|---|---|---|
| a | 有 | 本文件 |
| b | 四臂全跑 | 见 §2 |
| c | 已答 | 空闲真 CLI **不会**自己整帧重绘；reshape 后等待窗指纹变化耗时 = **无**（null）；挤窄瞬间有一次指纹变化 |
| d | 有 | §4 |
| e | 有 | §0 |
| f | 见下 | `npm test` |
| g | 有 | 未改产品码；commit 无 png/jpg |

## 6. `npm test` / diff

`npm test`：`# tests 115` `# pass 115` `# fail 0`（worktree `feat/garble-realcli-r1`）。
`git diff` 产品 `src/` 空。HEAD 树无 png/jpg（push 前 `git diff-tree` 自查）。

verdict: pass
