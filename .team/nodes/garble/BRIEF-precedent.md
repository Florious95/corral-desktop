# 简报 · t.precedent —— 照上游**已解决过同一个 bug** 的做法，把仪表补到同一水准

**先读** `.team/nodes/_driver/席位纪律.md`（🔴 含 §一点八 pane 画面永不入库）。
**再读** `.team/nodes/garble/CAUSE.md`（受控矩阵，已并 main）。

## 0. 🔴 用户 2026-08-23 裁定（⛔ 本格的宪法，逐字）

> 「**不需要我拍板。有正常的先例，就不存在解决不好的问题。你现在这种办法在牺牲体验。
> 想中途结束这个问题。你找不到根本原因，你就加日志。**」

⇒ 三条硬约束，⛔ 一条都不许违反：

1. ⛔ **不许提任何牺牲体验的修法**（缩字号 / 横向滚动 / 首屏等 367ms / 向 pane 发按键促重绘）。
   上一格 leader 提的三个候选**全部作废**，⛔ 不要在本格复活它们。
2. ⛔ **不许收口**。找不到根因就**继续加日志**，⛔ 不许拿「代价换效果」结案。
3. 🔴 **先例存在** ⇒ 这个问题一定有不牺牲体验的解。⛔ 不许写「这是产品取舍」。

## 1. 先例：上游 **已经解决过同一个 bug**（⛔ 只读，一个字都不许改上游）

`/Volumes/nvme/Projects/远程Agent安卓/requirement-base/entries/081-回前台重连后终端重排错乱.md`

**同一个现象**（他们 2026-08-19，用户实测）：
> 同一屏内存在**两种换行宽度**——一部分内容按旧列宽已经折过行，新内容按新列宽折行，两者叠在一起。

**他们的根因与修法**（`app/core-conn/.../ConnectionManager.kt:559` 注释原文）：
> 「081：**重连必须重放最新行列，不能回落到首次 subscribe 的 40×120**」

⇒ 根因不是「reshape 有害」，是**客户端在某个时刻用了一个错的/陈旧的几何去订阅**，
把主机 pane 按错宽度重塑了一次。**修法零体验代价。**

**他们的仪表纪律**（这才是本格要照抄的东西）：

| 他们做的 | 出处 |
|---|---|
| **每个 ref 一份订阅簿记** `activeSubscriptions[ref] = rows to cols`，重连按 ref 重放**最新**值 | `ConnectionManager.kt:548` |
| **每个守卫两侧操作数都记**，分得出「没调用 / 调用了被拦 / 发出去了」 | `ConnectionManager.kt:566` `resize skipped rows= cols= reason= ready= conn= bookkept_rows= bookkept_cols=` |
| **每次 resize 记 reason**（`resume`/`rotate`/`ime`/`user`） | 同上 |
| **推导值与内核值两边都记** `view_width_px / cell_width_px / derived_cols / last_sent_cols` | `TermViewPresenter.kt:341` |
| **服务端认的列宽单独在 SNAPSHOT 路径记 `frame cols`** | 同上注释 |
| **判据**：`derived_cols` 与 `frame cols` 两个数都读得到**且相等**；🔴 **读不到这两个数 = 仪表没做够，不算通过** | `081` §3 |

## 2. 我们缺什么（leader 已核，本格核对一遍）

`src/term/sameWidth.js`（PR #80）只比 **我们自己的两个数**（`sent` vs `grid`），
🔴 **从来没有和帧里服务端报的 `host_cols` 比过**。上游的判据正是这一比。

上一格 `EVIDENCE.md` 已经看到**同一次激活里飞着三个不同的数**：
`subscribe` 发 235、`req_cols` 157、随后 `resize_up` 又发 157。**这就是 081 那个形状。**

## 3. 要做的三件事

### ① 按上游标准补仪表（这是本格主体）

在我们客户端的对应位置补齐，**每条都要带两侧操作数**：

| 记什么 | 至少含 |
|---|---|
| 每次 `subscribe` / `resize` 发出 | `ref` `rows` `cols` **`reason`**（`activate`/`fit`/`settle`/`reconnect`/`user`）`ok` + **发出后的簿记值** |
| 每次被守卫拦下 | 🔴 **同样要记**，含拦下的原因与两侧操作数（分得出「没调用 / 被拦 / 发出去了」） |
| 每个 ref 的订阅簿记 | `bookkept_rows` `bookkept_cols`，**按 ref 分开**（⛔ 不许全局一份） |
| 推导侧 | `container_width_px` `cell_width_px` `derived_cols` `last_sent_cols` |
| 服务端侧 | 每个 SNAPSHOT / DELTA 帧的 **`frame_cols`（= host_cols）**，以及**上屏那一刻的 `grid_cols`** |

🔴 日志里 ⛔ 不许有 pane 正文、token。⛔ 不许带回 `garbleDetect.js`。

### ② 回答三个具体问题（每个都要有日志原文支撑，⛔ 不许推理代答）

1. 🔴 **一次「点开会话」的全过程里，我们一共发出过几次几何？分别是多少、reason 是什么？**
   —— 有没有我们自己的「40×120」：一个**在 fit 落定之前**发出的默认几何（xterm 默认 80×24？）。
2. 🔴 **上屏那一刻，`grid_cols` 与 `frame_cols` 相不相等？** 逐帧给出这两个数。
3. 🔴 **切换会话时，订阅簿记是按 ref 分开的，还是被上一个 ref 的值污染？**
   （`SameWidthController` 只有单份 `sent` —— 核实它是每个 pane 一个实例还是共享。）

### ③ 复现台仍用自建（⛔ 不碰用户会话）

沿用 `run-cause.mjs` 的自建 tmux + 自建 daemon。⛔ 不连 `:9900`、⛔ 不扫 `/tmp/tmux-501/`。
在自建台上走**完整的点开流程**（不是直接调 API），把 ① 的日志抓下来。

## 4. 判据

| # | 判据 |
|---|---|
| a | `.team/nodes/garble/PRECEDENT.md` 存在、非空 |
| b | 🔴 §3① 五类记录点全部落地，产物里**贴出真实日志行原文**（每类至少一条） |
| c | 🔴 §3② 三个问题**逐条**回答，每条附日志原文；⛔ 不许「推测」「应该」 |
| d | 🔴 上游 081 的判据在我们这边跑一遍：**`derived_cols` 与 `frame_cols` 两个数都读得到且相等**。**不相等 ⇒ 贴出不相等的那几帧，那就是缺陷现场**（这是好结果，不是失败） |
| e | 🔴 「点开会话」全过程发出的几何次数与取值序列（含 reason），**列成表** |
| f | `npm test` 全绿且 **≥ 115** |
| g | ⛔ 未改任何渲染/协议逻辑——本格**只加日志**（`git diff` 里除埋点、夹具、测试外无行为改动）；🔴 `git diff-tree -r HEAD` 里**一张图都没有** |

## 5. ⛔ 本格不修，但**必须**给出反推

产物末尾一节「根因候选」：每条给出**日志原文**、**文件:行**、以及**事前预测**
「若这样改，哪个读数应从 X 变成 Y」。
⛔ 不许出现任何牺牲体验的候选（见 §0）。**若日志还不足以定位 ⇒ 明写「还缺哪个埋点」，那是下一格。**

## 6. ⛔ 红线

- 🔴 **上游只读**：`/Volumes/nvme/Projects/远程Agent安卓/` **一个字都不许写**。
- ⛔ 订阅 / 点击 / resize 用户任何真实会话；⛔ 点收藏（`claude_code`）。
- 🔴 ⛔ 图片、pane 正文进 commit（§一点八，今天出过事故）。
- ⛔ 驱动系统鼠标键盘；⛔ 动用户的 AgentMirror；⛔ 放宽 CSP；⛔ token 进日志。
- 杀进程**按 pid**，⛔ 不 `pkill -f`；端口被占换一个，⛔ 不 kill 占用者。

## 7. 收工

独立 worktree；开工先 `git fetch origin`，基于 `origin/main`。
🔴 收工 **commit + push + `gh pr create`**。⛔ **你不 merge。**
push 前自查 `git diff-tree --no-commit-id --name-only -r HEAD | grep -Ei '\.(png|jpe?g)$'`，有输出就停下重来。

**产物 `.team/nodes/garble/PRECEDENT.md`，落盘后 `report_result`。末行格式见席位纪律 §6。**
