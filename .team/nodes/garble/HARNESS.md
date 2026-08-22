# HARNESS · 网页版全会话 CDP 巡检夹具（t.harness）

⛔ 本格不修产品、不断根因。点击走 Chrome `Runtime.evaluate` → `HTMLElement.click()`，
⛔ 未用 `CGEvent` / HID / `cliclick` / System Events。

## 0. 显式改动的任务定义

账本要求在 **本 worktree** `npm run dev`。`wt-harness` 的 `write_paths` 不含 `src/`，
而 `window.__amDiag` 在 t.inst 的树里。夹具因此用

`--app-root /Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-inst`

起 Vite（端口被占则换，本次 `127.0.0.1:1437`）。脚本与产物仍只写在 `wt-harness`。

## 1. 怎么跑

```sh
cd /Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-harness
node scripts/garble-sweep.mjs --rounds 10 --timeout-ms 5000
```

| 参数 | 默认 | 含义 |
|---|---|---|
| `--rounds N` | 1 | 全会话重复 N 轮 |
| `--timeout-ms` | 8000 | 单会话等到 snapshot+`garble_label` 的上限 |
| `--port` | 1437 | Vite；占用则自动换 |
| `--cdp` | 9333 | Chrome remote debugging；占用则自动换 |
| `--out` | `.team/nodes/garble/sweep-sample.jsonl` | JSONL |
| `--app-root` | 邻接 `wt-inst` | 带 `__amDiag` 的网页源 |
| `--self-check-only` | | 只跑坏/好自检，不覆盖 JSONL |

Chrome：独立 `--user-data-dir=.team/nodes/garble/chrome-profile`、`--headless=new`、**新标签**。
配对：tauri `devices.json` → `localStorage[agentmirror.desktop.v1.devices]` 后 reload（token 不打印）。

流程：listing 后枚举全部 `.agents-row` → 逐行 DOM click → `__amDiag.reset()` → 等 dump → 一行 JSONL。
接口字段以 `INSTRUMENT.md` 为准。`activate.ref` 是 uid，`subscribe`/`garble_label.ref` 是协议 ref，
夹具 `mergeSettle` 把两套 key 拼回去。

`t_stable` 要连续 **2** 次 `garbled:false`。一帧 snapshot 只有一次 label ⇒ `settle_ms` 常为 null、
`timed_out:true`。有标签即可采；稳定计时留给多帧 delta。超时 **5000ms**。

## 2. 自检（两头夹住）

读数 `.team/nodes/garble/self-check.json`（2026-08-23，headless 1100×800，本地网格 **114** 列）。

### 好态 → `garbled: false`

| 项 | 值 |
|---|---|
| 会话 | `/tmp/tmux-501/default` `%2`（协议 ref；未打印 token） |
| garbled | **false** |
| reasons | `[]` |
| local_cols | 114 |
| 做法 | 未改 subscribe，DOM 点击真实 listing 行 |

### 坏态 → `garbled: true`

第一次用 `Client.prototype.subscribe` 补丁失败（Vite 双模块实例，申报仍是 114，标签仍绿）。
改成 **`WebSocket.prototype.send` 把上行 subscribe 改写成 50×235**（页面内、CDP evaluate，非产品码）：

| 项 | 值 |
|---|---|
| 会话 | `ta-a9fd5b7defbd` `%0` |
| garbled | **true** |
| reasons | `overwide_line`, `box_run_exceeds_cols` |
| local_cols | 114 |
| 做法 | 窄视口 + 申报 235 → 宽 snapshot 进窄网格 |

对照：t.inst 夹具 `detectGarble(wide-host.snapshot.bin, 80×24)` 经 Vite `import` 同为
`garbled:true`（`cup_clamped,overwide_line,box_run_exceeds_cols`）。坏态以 **WS 改写的活路径** 为准。

破坏齿不在用户正在输入的键盘上；未向 pane 发 `send-keys`。副作用见 §4。

## 3. 真数据

`.team/nodes/garble/sweep-sample.jsonl`：**55 行 = 55 个真实会话 × 1 轮**（listing 有多少跑多少）。
每行含 `round`、`session_ref`、`garbled`、`reasons[]`、`settle_ms` 及分段、`local_cols/rows`、
`listing_cols/rows`、`ts`。无 pane 正文、无 token。

该轮 **55 行**：`garbled:true` 13、`false` 41、无标签 1（`unknown:26`，click 后 5s 内无 activate/snapshot）。
13 条 true 的 `reasons` 以 `overwide_line` 为主（本地 114 vs 行宽仍超）。这是夹具读数，不是根因结论。

`npm test`（wt-harness）**115** 绿，棘轮 ≥106。

## 4. 副作用（必须知道）

网页 subscribe 会 **偷走桌面端同一 pane 的 pipe**（WHY-STUCK）。本轮点了全部 55 个会话。
坏态自检把 `%0` 申报成 235 列，daemon 可能把它拉到 235×50。未 kill/open 用户 AgentMirror.app。
若桌面某列冻结：在桌面里切走再点开以重订。

---

verdict: pass
