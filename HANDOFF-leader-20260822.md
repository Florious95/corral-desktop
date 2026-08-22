# HANDOFF · AgentMirror macOS 桌面端 · leader · 2026-08-22（整夜无人值守结束态）

> 本文件覆盖同日两份旧交接（Build 阶段完成态 / 夜班前半段）。
> 走的不是 Workflow，是 **team-agent 六席位编排**（用户裁定席位一律 grok / grok-4.6）。

---

## §0 compact 后先做什么

**一句话现状**：`origin/main` = `7a84b52`，**17 个 PR MERGED、1 个 CLOSED**。
Web 端 111 条用例、真 daemon 验收、Token 安全存储全部闭合。
**唯一悬着的是一件两秒钟的事：你双击一下 `.app`，确认界面画得出来。**

**开口第一句**：
> 桌面端已经全部走完需求→用例→Web 端实测→两轮修复→真机验收。main 上 17 个 PR 全 merged。
> 只剩一件要你亲眼看：打开 `/Volumes/nvme/cargo-target/release/bundle/macos/AgentMirror.app`，
> 看窗口里有没有界面。整晚在这一条上判不出来，原因是**从 team-agent 的 tmux pane 里起 GUI 应用，
> 窗口不进 AX、截图截不到 WebView 层**——不是产品问题，但我不能替你判。

**必读清单**
1. 本文件
2. `CLAUDE.md` —— 工程流程约定
3. `.team/nodes/req/REQUIREMENTS.md` + `RULINGS.md` —— 需求 R-01…R-77、封存 F-01…F-04、14 条裁定
4. `.team/nodes/exec/CASE-RESULTS.md` + `RULINGS-2.md` —— 111 条实测 + 10 条缺陷的分类裁定
5. `.team/nodes/pack/PACK-VERDICT-3.md` + `.team/nodes/integrate/WHITE-SCREEN-EVIDENCE.md` —— 白屏定性

**恢复动作**：团队 `corral-desktop` 六席可能还活着。
```bash
cd /Volumes/nvme/Projects/tmux桌面端
team-agent status                      # 六行都有「空闲/工作」才算活
team-agent quick-start .team/current   # 死了才用这个；角色文件在磁盘上
```

### 恢复工作流程

1. **先核对，后开口**：
   ```bash
   git -C /Volumes/nvme/Projects/tmux桌面端 log --oneline -1   # 期望 7a84b52 或更新
   gh pr list --repo Florious95/corral-desktop --state all --json number,state
   git status --short                                          # 期望只有未入库的 .team/
   ```
2. **先恢复守护，后推进**：派活前先 `team-agent status` 验活（⛔ `ok: True` 不是送达）。
   长任务必挂两件互补的东西：事件探针（盯产物落盘）+ 30 分钟心跳（能发现「探针死了」）。
3. **恢复期间 ⛔ 不许**：重跑已 merged 的 PR、改 `docs/` 里的判定、动上游
   `/Volumes/nvme/Projects/远程Agent安卓/`、**在主工作树 `git checkout`**（见 §3）。
4. **判恢复完毕**：三条核对读数与本文件一致 + 六席都活。
5. **与文档不符**：以现场为准，差异写进本文件再动手。

---

## §1 身份与不变量

- **leader 不亲写产品码**。整夜 leader 只做：建队、写任务书、裁定、核 diff、merge、写文档。
- **自报不算数**。要么 leader 亲核，要么独立判官复核，要么标「待核」。
- **判者不能是产出方**。判官席全程不读实现席的产物目录。
- **判据四态**：通过(0) / 不通过(1) / **不可判(2)** / 不适用。**编译不过 ≠ 测试红**。
- **一事一 PR 一闭环**，land 之后立刻推 main。
- **席位模型**：provider `grok`，`model: grok-4.6`（用户 2026-08-22 裁定，CLAUDE.md §7 已改）。

---

## §2 验收标准（用户 2026-08-22 收窄，未变更前一直有效）

> 把当前主机所有目录在左边摆出来，每个目录下的 Agent 摆出来，右边可以分列展示。
> 主机只有 Local。本地基于 WS 链接 + Token 联通。做到这一点就是验收标准。

**封存到下期**：新建文件夹、新建 Agent、联通远端、加远端节点。
⛔ 做多了和做少了一样是不满足。用例 F-01…F-04 专门反查过，没有越界。

---

## §3 整夜踩过的坑（每条都有实撞，别重演）

### 3.1 `.team/runtime` 被 git 跟踪 → 切分支杀掉活团队【已闭合】

**现象**：`team-agent send` 返回 `name_not_resolvable`，`agent_count: 0`，worker pane 变孤儿。
**根因**：`.team/runtime/state.json` 被 scaffold 提交带进了 git。席位在主工作树切分支，
git 按各分支的跟踪状态删掉了**活团队正在用的运行时状态**。
**症状伪装成投递失败，读起来像网络问题，不像 git 问题。**
**处置**：PR #2 把 `.team/runtime/`、`.team/logs/` 加进 `.gitignore` 并 `git rm --cached`。
**防线**：⛔ 任何人不在主工作树 `git checkout`；验证一律独立 worktree。

### 3.2 我把「合成态」的验证结论套用到拆开后的 main【已闭合】

**现象**：#16（Token 走 tauri-plugin-store）并进 main 后，token 其实**存不进去**。
**根因**：plugin-store 需要的 `connect-src ipc:` 白名单躺在 #15 里。我先并 #16、压着 #15。
封装席验到的 `devices.json` 0600 是在**含 #15 的合成包**上取的。
**教训**：🔴 **PR 拆开合并时，基于合成态取得的验证结论不会自动继承。**
**处置**：PR #18 单独补 `connect-src ipc:`，两头夹住验过才并。

### 3.3 白屏是量具问题，不是产品问题【定性完成，待人眼确认】

四轮才定性。最终读数：
| 来源 | 读数 |
|---|---|
| 页内 JS | `visibilityState=hidden`、`outer 0×0`、`screenY=1080`；但侧栏文本齐全（Spaces/收藏/空态）、CSS 234 条、`body` = `rgb(251,250,248)` |
| Rust | 1 个 WebviewWindow `label=main`，`visible=true`、`focused=false`，位置 (260,55) |
| CGWindow | 同 pid **两扇**窗：1400×860 onscreen + 500×500 offscreen（Tauri 窗表不认） |
| AX | **windowCount = 0** |
| 截图 | `screencapture -l` 与 ScreenCaptureKit 两路都是纯 (255,255,255) |
| 量具自证 | **同一条命令截 Chrome 对照窗能出内容**（近白 0.16）→ 量具没坏、TCC 没被整段关掉 |

**定性**：从 team-agent 的 tmux pane 里起 GUI 应用，窗口不进 AX、WebView 层不参与合成。
**⛔ 不要再为白屏改任何产品配置。** 由用户双击 `.app` 亲眼确认。

### 3.4 #15 是幻影修复，已 CLOSED

为「白屏」开的 PR #15 改了两处：`base: './'` + `script-src 'self' tauri:`。
对照读数（`.team/nodes/integrate/PR15-PHANTOM-CHECK.md`）证明：main 上模块已执行、
绝对 `/assets/…` 在 `tauri://localhost` 下取得到、**无任何 script-src 违规**。
两处都无依据 ⇒ **关掉，不并**。
🔴 **CSP 终态 `script-src 'self'`，整夜一个字没放宽。**
（中途它曾加过 `'unsafe-eval'`，被 leader 打回；复验证明**没有人在 eval**。）

---

## §4 在途未收尾

### 4.1 🔴 唯一在途项：人眼确认 `.app`（负责人＝用户）

```
open /Volumes/nvme/cargo-target/release/bundle/macos/AgentMirror.app
```
**看什么**：窗口里有没有界面（侧栏 / Spaces / 「还没有添加设备」空态）。
- **有** ⇒ 桌面封装闭合，整期完成。
- **没有** ⇒ 白屏是真的，把 §3.3 的证据表交给下一轮，从「WebView 层为什么没合成」查起，
  ⛔ 不要回头再动 CSP / vite（已证无关）。

**为什么不代劳**：这是人类 gate；整晚的歧义全部来自无头截图管线，人眼两秒就能定。

### 4.2 建议但未做

- `.team/current/`（六个角色文件）、`.team/nodes/`（全部任务书、判词、截图、证据 JSON）
  **未入库**。想留档要单开 PR。`.team/runtime/`、`.team/logs/` 已 gitignore，⛔ 不要加回去。
- 2 条不可判：C-016 / C-018 需真 daemon Token；执行席**没有可用 token 且被禁读 `.env`**，
  它守住了红线。真机层面已由 `.team/nodes/live/LIVE-VERDICT.md` 覆盖（L1–L5 全绿）。
- 用例 C-053 / C-049 已裁定为**用例错**，用例表尚未回改。

---

## §5 整夜产出（全部已核）

| 阶段 | 产物 | 结果 |
|---|---|---|
| 需求分析 | `REQUIREMENTS.md` | R-01…R-77 + 封存 F-01…F-04 + 14 条待裁定 |
| leader 裁定 | `RULINGS.md` / `RULINGS-2.md` | 14 条 + 10 条缺陷分类 |
| 用例设计 | `TEST-CASES.md` | C-001…C-111，77 条 R 全覆盖，零孤儿 |
| Web 端执行 | `CASE-RESULTS.md` | 96 通过 / 10 不通过 / 2 不可判 / 3 不适用 = **111** |
| 修复①② | PR #7–#14 | 8 条，全 MERGED，带修前/修后对照图 |
| 真机验收 | `LIVE-VERDICT.md` | **L1–L5 全绿**，列出本机 13 个真实目录 |
| 封装 | `PACK-VERDICT-1/2/3.md` | G-P1 构建 0 / G-P4 零 CDN 通过 / **G-P5 Token 0600 通过** / G-P2 不可判 |
| 幻影排查 | `PR15-PHANTOM-CHECK.md` | #15 CLOSED，CSP 未放宽 |

**PR：17 MERGED / 1 CLOSED。** `origin/main` = `7a84b52`。

---

## §6 安全约束（原文保留，不可弱化）

- ⛔ 任何形式读凭据文件原文（`.env` / profile / token / authkey / plist）。
  取值只用 `set -a; . <file>; set +a` 注入子进程，**不打印、不落日志、不入截图**。
- ⛔ 无过滤 `ps aux`（会把 API key 打上屏）；进程只取 `ps -o pid,ppid,etime,stat,comm`。
- 配对 token 只在 `auth` 帧上行，**不回显、不落日志、不进错误文本**，输入框按密码处理。
- 服务端 token 文件（0600）⛔ 不 copy、不 print、不截图。
- `TS_AUTHKEY` 只走环境变量，**⛔ 绝不进 argv**。
- **CSP ⛔ 无因果放宽**：这个应用 localStorage/store 里放着配对 Token。
  整夜实证两次——`'unsafe-eval'` 和 `script-src tauri:` 都是多余的，都被打回。
- 构建产物**零 CDN 外链**（G-P4 已核通过）。
- ⛔ 不写 `/tmp` 或工程外路径（隔离 tmux socket 因长度上限例外，须短路径且预建）。
- ⛔ 起隔离 tmux 必须 `tmux -S <sock> list-sessions` 自证——建 socket 失败时 tmux
  **不报错，静默回退到用户真实 tmux**。
- 端口被占**换一个，⛔ 不许 kill 占用者**（可能是用户正在跑的东西）。
- ⛔ 往用户正在干活的 tmux pane 发按键。需要真 pane 就起自己的。
