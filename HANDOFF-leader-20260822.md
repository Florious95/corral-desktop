# HANDOFF · AgentMirror macOS 桌面端 · leader · 2026-08-22（无人值守夜班结束态）

> 本文件**覆盖**了同日早些时候那份「Workflow 第二阶段(Build)完成态」交接。
> 那份里描述的两处 import 断点、以及「等用户发话才能续跑」的状态，**都已闭合**。
> 走的不是 Workflow 续跑，而是 team-agent 席位编排（用户改用 grok-4.6 席位）。

---

## §0 compact 后先做什么

**一句话现状**：验收口径的功能已经**进主干**（`origin/main` = `80a35f4`），5 个 PR 全部
**MERGED**，`npm test` / `npm run build` / `cargo check` 三道门由**独立判官席**复核全绿，
mock daemon 下「左侧目录 → 目录下 Agent → 右侧分列」已有截图为证。
**唯一没做的是真机验收**——那是用户的人类 gate，agent 不能代替。

**开口第一句**：桌面端 MVP 已合入 main（5 个 PR 全 merged，判官席独立复核三道门全绿，
mock 层截图达到验收口径），现在等你起真 `agentmirrord` 做真机验收；顺便问要不要开下期
（新建文件夹 / 新建 Agent / 远端节点）。

**必读清单**（按优先级）
1. 本文件
2. `CLAUDE.md` —— 工程流程约定（真相源地图 / 验收标准 / 一事一 PR / 判据纪律 / 安全红线）
3. `.team/nodes/_night/PLAN.md` —— 值夜策略 + **切分支杀掉活团队**的事故复盘
4. `.team/nodes/verify/VERDICT.md` —— 判官席的独立读数（含 `eye-see-split.png`）
5. `docs/UI-SPEC.md` / `docs/CLIENT-CONTRACT.md` —— UI 与协议的唯一事实来源

**恢复动作**：team-agent 团队 `corral-desktop` 今晚**已 shutdown**（活干完了，且它的运行时
状态文件挡住了 `git pull`）。要再开：

```bash
cd /Volumes/nvme/Projects/tmux桌面端
team-agent quick-start .team/current      # 角色文件还在，未入库但在磁盘上
team-agent status                          # 两行都要有「空闲/工作」才算活
```

### 恢复工作流程（照做，做完才算接上）

1. **先核对，后开口**（本文件写的是落笔那一刻，可能已过期）：
   ```bash
   git -C /Volumes/nvme/Projects/tmux桌面端 log --oneline -1        # 期望 80a35f4 或更新
   gh pr list --repo Florious95/corral-desktop --state all --json number,state
   git status --short                                              # 期望只有未入库的 .team/
   ```
2. **先恢复守护，后推进**：要派活就先 `quick-start` + `status` 验活；**⛔ `ok: True` 不是送达**。
   长任务必挂两件互补的东西：事件探针（盯产物落盘，命中即唤醒）+ 30 分钟心跳（能发现「探针死了」）。
3. **恢复期间 ⛔ 不许**：不重跑已 merged 的 PR、不改 `docs/` 里的判定、不动上游
   `/Volumes/nvme/Projects/远程Agent安卓/`、**不在主工作树 `git checkout`**（见 §3 事故）。
4. **判「恢复完毕」**：三条核对命令读数与本文件一致 + `team-agent status` 两席都活 ⇒ 可以推进。
5. **与文档不符**：以**现场**为准，把差异写进本文件再动手；涉及验收口径变化的先问用户。

---

## §1 身份与不变量

- **leader 不亲写产品码**。探索/实现/验证派给席位；leader 的上下文留给判断。
  今晚 leader 只做了：建队、写任务书、核 PR diff、merge、写文档。
- **自报不算数**。席位说「测试绿了」，要么 leader 亲跑，要么由**独立判官席**复核，
  要么在文档里标「待核」。⛔ 不许把自报直接写成「已完成」。
- **判者不能是产出方**。今晚 `verifier` 全程不读 `.team/nodes/integrate/`，不改 `src/`。
- **判据四态**：通过(0) / 不通过(1) / **不可判(2)** / 不适用。**编译不过 ≠ 测试红**。
- **一事一 PR 一闭环**，且 **land 之后立刻推 main**（不推 = PR 显示 closed = 流程没发生）。
- **席位模型**：provider `grok`，`model: grok-4.6`（用户 2026-08-22 裁定，已写进 CLAUDE.md §7）。
  ⛔ 禁用 Deepseek 那条仍在。

---

## §2 排期与封存令

**用户 2026-08-22 收窄的验收标准（未变更前一直有效）**：

> 把当前主机所有目录在左边摆出来，每个目录下的 Agent 摆出来，右边可以分列展示。
> 主机只有 Local。本地基于 WS 链接 + Token 联通。做到这一点就是验收标准。

**明确封存到下期**：新建文件夹、新建 Agent、联通远端、加远端节点。
⛔ 不许当成「顺手做了更好」偷偷做进来——那是加需求。判官席今晚专门 grep 反查过，没有越界。

---

## §3 P0 / 插队项：切分支杀掉活团队（已闭合）

**现象**：`team-agent send verifier` 返回 `name_not_resolvable`；`status` 显示
`session_name: null`、`agent_count: 0`；worker pane 还活着但成了孤儿。

**根因**：`.team/runtime/state.json` 与 `.team/logs/events.jsonl` **被 git 跟踪**
（项目 scaffold 提交时带进去的）。整合席在主工作树切分支，git 按各分支的跟踪状态
删掉了工作树里那几个文件——**删的是活团队正在用的运行时状态**。
不是框架故障，是建队前没先把 `.team/` 排除掉。

**处置**：① PR #2 合入 main（`.gitignore` 加 `.team/runtime/`、`.team/logs/`，
`git rm --cached` 摘掉已入库的）；② kill 孤儿 session + `quick-start` 重建
（两席都无需保留上下文：integrator 已交付，verifier 还没开工）；③ 之后所有验证一律走独立 worktree。

**对排期的扰动**：只推迟了 verify 的开工，没有任务因此漂掉。

**教训**：运行时状态目录必须在**建队之前**就 gitignore 掉。否则「切分支」这个最日常的
动作就是定时炸弹，而且它炸出来的症状（投递失败）读起来像网络问题，不像 git 问题。
后续两次同步本地 main 也都撞到同一条（活团队一直在写那两个文件 → `git pull` 反复
`Aborting`），最终靠**先 shutdown 团队再 pull** 解决。

---

## §4 在途未收尾任务

### 4.1 真机验收（**唯一真正的在途项**，负责人＝用户本人）

- **为什么是用户**：这是人类 gate，⛔ agent 的 succeeded 或判官的 pass 都不能代替。
  另外配对 token 属于凭据，leader 不读原文、不打印、不入截图。
- **怎么做**：
  ```bash
  cd /Volumes/nvme/Projects/远程Agent安卓/server && go run ./cmd/agentmirrord -listen 0.0.0.0:9900
  ```
  桌面端（`npm run tauri dev` 或 `npm run dev`）连 `ws://127.0.0.1:9900/ws` + 配对 token。
- **看什么**：左侧栏列出**真实**的 tmux 目录 → 每个目录下列出真实 agent → 右侧能分列镜像。
- **卡在哪**：卡在「需要用户在场看一眼」。今晚只做到 mock daemon 层（假目录 `a`/`b`）。

### 4.2 已完成、无需再动的

| PR | 状态（**已核** `gh pr list --state all`） | 内容 |
|---|---|---|
| #1 | MERGED | 三份真相源文档入库 |
| #2 | MERGED | `.gitignore` 排除 `.team/runtime/`、`.team/logs/` |
| #3 | MERGED | **MVP 主体**：Build 产物接线 + 三处修复 |
| #4 | MERGED | CLAUDE.md §7 模型铁律 → grok-4.6 |
| #5 | MERGED | `.gitignore` 排除 `.worktrees/`、`.grok/` |

`origin/main` = `80a35f4`；本地 main 同步到位；工作树干净（只剩未入库的 `.team/`）。

**PR #3 里三处修复的根因**（整合席报，判官席复核过效果）：
- `src/App.jsx` 与 `src/components/sidebar/AgentsList.jsx` 引了**从不存在**的
  `lib/provider.js` → 改指向真实模块 `src/core/providers.js`。
- `src/lib/icons.jsx` **缺失**（不是路径错）→ 按 `docs/UI-SPEC.md:750 §9 内联 SVG 清单`
  补齐 18 个图标。判官席三条独立核过：规格确实把清单定在这个路径、仓库里 9 处按该路径
  import、图标是真实现不是空壳。

### 4.3 判官席的独立读数（**已核**，不是自报）

在独立 worktree `.worktrees/verify`（detached @ `6e87f3f`）跑的：

| 项 | 读数 |
|---|---|
| G1 `npm test` | 退出码 **0**，58/58，无 skip/todo |
| G2 `npm run build` | 退出码 **0**，53 modules |
| G3 `cargo check` | 退出码 **0** |
| 棘轮 | 另开 worktree 实测 `main` 是 **39** 条，全部保留；HEAD 新增 19 条真断言 |
| 排除项 | grep 全仓无 `createWorkspace` / `createSession` / `addRemote` 实现入口 |
| 协议 D1 | 渲染层不读 `s.state` / `w.aggregate_state`；状态走 `level2_*` + 客户端三值聚合 |
| 协议 D2 | `SESSION_STATUS` 冻结为 `working/idle/unknown` |
| 协议 D3 | 发送 = **两帧**（`text` 不带回车 → 等 ack → 裸 Enter） |
| 眼见为实 | mock-daemon + vite + Chrome 真实点击；截图 `.team/nodes/verify/eye-see-split.png` |

**leader 落笔时纠正过自己一次**：任务书里写「58 是 main 的棘轮基线」是错的，
main 实测 39，58 是 HEAD（39 旧 + 19 新）。棘轮结论不变（旧 39 条一条没少）。

### 4.4 未入库的产物（不影响功能，想入库要单开 PR）

`.team/current/`（两个角色文件）、`.team/nodes/`（任务书 / IMPL.md / VERDICT.md /
TEST-DESIGN.md / 截图 / 值夜 PLAN.md）目前**未入库**。`.team/runtime/` 与 `.team/logs/`
已被 gitignore，⛔ 不要再把它们加回去。

---

## §5 运维与外部

- 远端仓：`Florious95/corral-desktop`（**private**）。`gh` 已登录 `Florious95`。
- team-agent 私有 tmux socket：`/private/tmp/tmux-501/ta-eb63cbe5b286`。
  ⛔ 用户默认 `tmux list-sessions` 看不到 worker 是**正常的**，不是故障。
- grok 席位需要项目目录被信任：`grok --trust` **要 TTY**，喂 `/dev/null` 只会拿到
  `Device not configured`。今晚是在隔离 tmux socket 里拉起 TUI 完成的；起隔离 socket
  必须 `tmux -S <sock> list-sessions` 自检，因为建 socket 失败时 tmux **不报错，
  静默回退到用户真实 tmux**。
- 上游 `/Volumes/nvme/Projects/远程Agent安卓/`：**只读**，今晚未写入任何字节。
- 外部通告：无。今晚没有需要投给框架维护方的缺陷（那起事故是我方配置问题，不是框架故障）。

---

## §6 安全约束（原文保留，不可弱化）

- ⛔ 任何形式读凭据文件原文（`.env` / profile / token / authkey / plist）。
  取值只用 `set -a; . <file>; set +a` 注入子进程，**不打印、不落日志、不入截图**。
- ⛔ 无过滤 `ps aux`（会把 API key 打上屏）；进程只取 `ps -o pid,ppid,etime,stat,comm`。
- **查任何配置前先想凭据**：一个 `grep -i` 打在偏好文件上就可能把 key 打上屏。
- 配对 token 只在 `auth` 帧上行，**不回显、不落日志、不进错误文本**，输入框按密码处理。
- 服务端 token 文件（0600，用户配置目录 `agentmirror/token`）⛔ 不 copy、不 print、不截图。
- `TS_AUTHKEY` 只走环境变量，**⛔ 绝不进 argv**，不打印、不截图。
- **凭据万一泄露 ≠ 停工**：只做三件——一行上报（⛔ 不复述泄露的值）、就地收紧做法、继续干活。
- ⛔ 不写 `/tmp` 或工程外路径（隔离 tmux 的 socket 目录因长度上限例外，必须短路径且预建）。
- 构建产物必须**零 CDN 外链**；localStorage 存 token 的安全边界 = 不得加载不可信第三方脚本。
