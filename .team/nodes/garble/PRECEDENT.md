# t.precedent · 照 081 先例把几何仪表补到同一水准

任务书：`.team/nodes/garble/BRIEF-precedent.md`
先例：`/Volumes/nvme/Projects/远程Agent安卓/requirement-base/entries/081-回前台重连后终端重排错乱.md`（只读）
本格 **只加日志，未改订阅/绘制/协议载荷**。`reason` 不进 wire。
夹具：`.team/nodes/garble/run-precedent.mjs`（自建 tmux + 自建 daemon，未连 `:9900`，未扫 `/tmp/tmux-501`）
跑数：`.team/nodes/garble/PRECEDENT-run.json`（指纹/行列/reason，无 pane 正文）

⛔ 不提缩字号 / 横向滚动 / 首屏空等 / 向 pane 发键。上一格三个代价修法不复活。

## 0. 台子（零打扰）

| 项 | 值 |
|---|---|
| tmux socket | `/tmp/amp-tmux/tmux-501/amp` |
| daemon | `127.0.0.1:19371`，`AGENTMIRROR_E2E_DISCOVERY_SOCKET_DIRS` 只扫该目录 |
| `:9900` | **未连** |
| 用户 socket | **未扫、未订** |
| 点开路径 | 与产品相同的调用序：`activate` → xterm 默认 propose 80×24 → `SameWidthController.settle(fit)` → `subscribe(reason=activate)` → `resize(reason=fit)`（App `onResize`）。未点用户会话、未驱动系统键鼠。 |

## 1. 五类记录点（每类一条原文）

### subscribe / resize 发出（两侧操作数 + reason + 簿记）

```
geom subscribe ref=/tmp/amp-tmux/tmux-501/amp%0 rows=47 cols=157 reason=activate ok=true skipped=null bookkept_rows=47 bookkept_cols=157
geom resize ref=/tmp/amp-tmux/tmux-501/amp%0 rows=47 cols=157 reason=fit ok=true skipped=null bookkept_rows=47 bookkept_cols=157
```

（JSON 里 ref 含 `\u001f`；上面为可读转写。wire 载荷仍是 `{ref,rows,cols}`，无 reason。）

### 被守卫拦下

单测 `gate_none is distinguishable from a sent subscribe`：同一几何第二次 `settle` → `{type:'none'}`，日志：

```
geom subscribe ref=x rows=47 cols=157 reason=settle ok=false skipped=gate_none bookkept_rows=null bookkept_cols=null
```

Client 在 READY 前：`skipped=not_ready`（`subscribe before READY…`）。

### 每个 ref 的订阅簿记

```
after alt … book235=157 book80=80
```

`Client.activeSubscriptions` 是 **Map keyed by ref**。`SameWidthController` 是 **每个 TerminalPane 实例一份**（切 `agent.ref` 会重挂 effect、新建 controller）。

### 推导侧

```
geom derived ref=…%0 derived_cols=80 derived_rows=24 last_sent_cols=null note=xterm_default_before_fit
```

产品路径里 fit 落定后的 `derived_cols` 来自 `TerminalView.lastFit`（`container_width_px / cell_width_px`）。本夹具无 DOM，用与产品相同的「先 80×24 propose 再 settle 到 fit」序。

### 服务端侧 SNAPSHOT `frame_cols` + 上屏 `grid`

```
geom snapshot ref=…%0 kind=1 frame_cols=235 frame_rows=50 bytes_len=8243
```

`frame_cols` = 当时 listing 里该 ref 的 `cols`（081 的 `frame cols`）。上屏格子 = 刚发出的 subscribe/grid = **157**。

## 2. 三个问题（只凭日志）

### Q1 一次点开发出几次几何？有没有 fit 前的默认几何？

**两次发出，同一最终值；80×24 只出现在 derived，没有上 wire。**

| # | 事件 | reason | rows×cols |
|---|---|---|---|
| 1 | subscribe | activate | 47×157 |
| 2 | resize | fit | 47×157 |

原文见 §1 subscribe/resize。`derived_cols=80` 在 subscribe 之前，但是 `SameWidthController.settle` 直接给出 157，**没有**发出 80×24，也 **没有** 40×120。

### Q2 上屏时 `grid_cols` 与 `frame_cols` 相不相等？

**不相等（缺陷现场，081 判据命中）。**

| 帧 | grid（刚 subscribe） | frame_cols（listing） |
|---|---|---|
| 点开 host235 后第一帧 SNAPSHOT | 157 | **235** |
| 点开 alt80 后第一帧 SNAPSHOT | 80 | 80（相等） |

原文：`geom snapshot … frame_cols=235` 紧跟 `geom subscribe … cols=157`。
约 100ms 后 listing 才变成 157（`after click-open pane=157x47 listing_cols=157`）。**第一帧按旧主机列宽标注、按新格子订了阅。**

### Q3 簿记按 ref 分开还是被上一个 ref 污染？

**按 ref 分开，未被污染。**

原文：`book235=157 book80=80`。两个 ref 各记各的。`SameWidthController.sent` 不跨 pane 共享。

## 3. 081 判据在我们这边

`derived_cols`（fit 后要上屏的 157）与 `frame_cols`（首帧 listing 235）**都能读到，且不相等**。
这就是缺陷现场，不是仪表不够。

相等的对照：alt80 首帧 `frame_cols=80` 与 subscribe 80 一致。

## 4. 点开会话几何序列表

host235（主机起盘 235×50，fit 目标 157×47）：

| 序 | 日志事件 | reason | 值 |
|---|---|---|---|
| 0 | derived | — | 80×24（本地默认，未发） |
| 1 | subscribe | activate | 47×157 **发出** |
| 2 | resize | fit | 47×157 **发出** |
| 3 | snapshot | — | frame_cols=**235** ≠ 157 |
| 4 | listing 追上 | — | listing_cols=157 pane=157×47 |

## 5. 根因候选（⛔ 未修；无牺牲体验）

### C1 首帧 SNAPSHOT 仍带 reshape 前的 `frame_cols`

- 原文：`subscribe cols=157` 然后 `snapshot frame_cols=235`
- 位置：`src/vendor/agentmirror/client.js:307` 二进制路径用 `sessionsByRef` 的 listing 列宽；listing 更新晚于首帧
- 事前预测：若上屏前等到 `listing.cols === sent.cols`（或首帧 SNAPSHOT 自带 host_cols），该帧 `frame_cols` 应从 **235 变成 157**，与 `grid_cols` 对齐。用户仍立即看到会话，不必空等一截固定 367ms。

### C2 一次点开发出 subscribe + resize 两次

- 原文：同 ref 连续 `reason=activate` 与 `reason=fit`，都是 47×157
- 位置：`src/components/terminal/TerminalPane.jsx:126` subscribe；`src/App.jsx:346` `onResize` → `dm.resize(..., 'fit')`
- 事前预测：若 App 不再对刚 subscribe 的同一几何再 `resize`，点开序列应从 **2 次变成 1 次**；`bookkept_cols` 仍为 157。重连 replay 只放 subscribe 簿记（resize **不写** `activeSubscriptions`——现日志 `resize` 后 `bookkept_cols` 仍是 subscribe 的值）。

### C3 本地 80×24 默认存在，但被 settle 挡住未发

- 原文：`derived_cols=80` 且无 `subscribe cols=80`
- 位置：xterm 默认格子；`src/term/sameWidth.js` 要 `settle` 才 subscribe（`TerminalPane.jsx:131`）
- 事前预测：若有人在 settle 前 `subscribe`，日志会出现 `reason=activate cols=80`；**当前没有**。保持「只在 settle 后发」则不应出现 80 上 wire。

还缺的埋点（下一格）：SNAPSHOT 帧本身的 host_cols（二进制里没有，只能借 listing，所以才有 C1 竞态）。可在 daemon 侧给 SNAPSHOT 带头，或让 listing 与二进制同序编号。本格不改行为。

## 6. 判据表

| # | 结果 | 说明 |
|---|---|---|
| a | 有 | 本文件 |
| b | 有 | §1 五类原文 |
| c | 有 | §2 三条都有日志，无「应该」 |
| d | 有 | 不相等已贴（Q2） |
| e | 有 | §4 表 |
| f | 有 | `npm test` `# tests 121` `# pass 121` `# fail 0` |
| g | 有 | 未改渲染/协议载荷；`reason` 仅日志；无 png/jpg |

verdict: pass
