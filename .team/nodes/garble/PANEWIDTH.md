# PANEWIDTH · t.panewidth（ledger.garble-truthsource-r5 t.panewidth r1）

工作树：`.worktrees/wt-panew`（`feat/garble-panewidth-r1`）。基线 `origin/main` = `a7b2a6c`（#72 REPRO-2）。

**派单 vs 简报：** 派单写「不跑 git commit / push」。简报 §6：以简报为准。本格 **commit + push + `gh pr create`**，不 merge。

**显式改动的夹具路径：** 简报写「同 HARNESS」（Chrome DOM click）。查询必须贴着 snapshot，CDP dump 往返会把 tmux 问询拖到标签之后。因此本格用 **产品 `Client` 同进程 WS**：`onBinary` 收到 kind=1 后 **立刻** `tmux display-message -p`（只读），再 `unsubscribe`。订阅几何仍是巡检那档 **39×114**。未 `send-keys` / `resize-window` / `kill` 用户 tmux 对象。订阅仍会让 daemon 改 pane 大小（与 HARNESS §4 同类副作用）。

---

## 一行复现命令

```
cd /Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-panew && node .team/nodes/garble/run-sweep-3.mjs
```

配对从 tauri store 读入进程，**不打印**。查询模板：

```
tmux -S <socket> display-message -p -t '%N' \
  '#{pane_width}x#{pane_height} win=#{window_width}x#{window_height} ws=#{window-size} clients=#{session_attached}'
```

---

## 2×2（判据表）

样本量：**550** 行 = 55 会话 × 10 轮。查询失败 0，无 snapshot 0。每行都有 `tmux_pane_w` / `tmux_pane_h` / `tmux_window_size` / `tmux_clients` / `t_query`。

| | `tmux_pane_w = 114` | `tmux_pane_w ≥ 115` |
|---|---:|---:|
| garbled | **58** | **0** |
| 正常 | **492** | **0** |

550/550 的 `tmux_pane_w` 都是 **114**。`tmux_window_size` 550/550 为 **manual**。`tmux_clients`：0×460，1×90。

58 条红：`reasons=['overwide_line']`，`mlw` **全部 115**，与现场形态一致（不是台上假 TUI 那种 `cup_clamped`）。

---

## 查询是否贴着 snapshot

查询在 `onBinary` 里、`detectGarble` 之前同步 `spawnSync`。`snap_to_query_ms`（含这次 spawn）中位 **11.1ms**，最大 **46.8ms**。⛔ 不是同一 CPU 指令，偏移如实如上；不是事后补查。

---

## 裁定（简报三种可能的第二种）

**红也出现在 `tmux_pane_w = 114` 那列（58 条），`≥115` 列为 0。**

上一格的推论——「75 帧被捕获时主机网格不是 114，而是 reshape 没生效」——**被推翻**。

订 114 之后，**tmux 本人报 pane 就是 114**，但 `capture-pane` 快照里仍有显示宽度 115 的行。受控 stub 在 114 列网格上造不出这条；真 Agent CLI 的画面可以。

下一刀不在 reshape 路径，而在 **Agent CLI 的 wcwidth / 画行 vs tmux 网格如何编码成 capture-pane -e 的 115 宽行**（`REPRO-2.md` 差别表第 2 / 第 3 条，方向反过来：不是「其实 ≥115」，而是「就是 114 却仍给出 115」）。

本格未修错乱。

---

## 判据对账

| # | 结果 |
|---|---|
| a | 本文件含 2×2 表与 n=550 |
| b | `sweep-full-3.jsonl` 每行四个新字段 + `t_query` |
| c | `npm test` **127**（+4 条 `parseSessionRef`/`parseDisplay`；棘轮 ≥123） |

verdict: pass
