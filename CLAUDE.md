# tmux桌面端（AgentMirror macOS 桌面客户端）——工程流程约定

Tauri v2 + Vite + React 19（JSX，无 TS）+ @xterm/xterm 6，通过 WebSocket（协议 v1）
镜像主机 tmux 里的 Agent CLI。技术栈已裁定，⛔ 不要重开选型。

只写关键流程。写代码的品味准则在 `/Users/alauda/.claude/CLAUDE.md`（全局），不重复。

---

## 1. 真相源

| 问什么 | 看哪 |
|---|---|
| 协议 | `docs/CLIENT-CONTRACT.md`（**§0 权威顺序必读**） |
| UI | `docs/UI-SPEC.md`（唯一事实来源） |
| 进度与在途 | `HANDOFF-leader-<日期>.md`（最新那份） |
| 上游挂起项 | `.team/nodes/_night/BACKLOG-UPSTREAM.md` |
| 设计稿原件（存疑时） | `design-handoff/.../Agent App Prototype.dc.html` |

- 🔴 **实现 > 文档**：协议有分歧以上游 `server/internal/` 的 Go 源码为准。
  web 端 `client.js` 里读 `s.state` / `w.aggregate_state` 的分支是死代码，⛔ 不许照抄。
- 🔴 **上游只读**：`/Volumes/nvme/Projects/远程Agent安卓/` 与 GitHub `Florious95/corral-core`
  **只能读**。需要上游改动 ⇒ 记进 BACKLOG 告诉用户，⛔ 不许动手。
- **遇疑难先搜上游**：`corral-core` 的 `requirement-base/entries/` 常有同一问题的根因与判据。
  实例：`083-真机视觉收口六条.md` 解过框线断点/logo 黑缝，连「交点闭合」判据都是现成的。
- **规格与实现同步改**：改实现要在同一个 PR 里改 UI-SPEC，注明裁定日期。
  ⛔ 不许留中间态——判官按旧规格判，会判出真红但假缺陷。

## 2. 验收标准（用户 2026-08-22 收窄）

> 把当前主机所有目录在左边摆出来，每个目录下的 Agent 摆出来，右边可以分列展示。
> 主机只有 Local。本地基于 WS 链接 + Token 联通。

**本期封存**：新建文件夹、新建 Agent、联通远端、加远端节点。多设备 UI 壳可作超集存在。
⛔ 做多了和做少了一样是不满足。

## 3. 量具与证据（🔴 今天栽最多的地方）

**先怀疑量具，再怀疑被测物。「没报错」不等于「工作正常」。**

| 坏量具 | 实撞症状 | 正确做法 |
|---|---|---|
| `cmd \| tail` 取 `$?` | 构建失败读成 rc=0 | ⛔ 退出码不许经管道 |
| grep 源码标识符判包版本 | 恒假阴性（资源在包里压缩存） | 比对 `dist/assets/*` 文件名 |
| tmux pane 里起 GUI 截图 | 全白（AX windowCount=0） | 同命令先截一个已知有内容的窗口 |
| 证据夹具缺 `xterm.css` | canvas 掉到 host 下，像产品坏了 | 先排除夹具与产品的差异 |
| 只判 `loadAddon` 抛没抛错 | load 成功但 canvas 空 | 检查**工作结果**，不只检查错误信号 |

- 🔴🔴 **⛔ 绝不驱动用户的鼠标键盘**（用户 2026-08-22 令：「在测试不要动我的鼠标啊」）。
  ⛔ `CGEvent` / HID 合成 / `cliclick` / `osascript` + System Events `keystroke`·`click` ——
  这台机器上用户本人在工作，和测试共用一套输入设备，抢走就是打断他。
  **粘贴/上传/DOM 事件一律走 Chrome + Chrome DevTools MCP 在后台测**（用户同令：
  「粘贴这个事情通过 Chrome 是可以在后台测的」）——Chrome 能合成 `ClipboardEvent`、
  注入 `DataTransfer`，不碰系统输入设备。`.app` 只留给桌面壳特有的东西，
  且 ⛔ **在 .app 上同样不许合成输入事件**。只能靠驱动真实设备才验得了 ⇒ 判**不可判**上报。
  ⚠️ 这条**收窄了下面「验证表面 = 交付面」**：交付面仍是 `.app`，但取证手段受本条约束。
- 🔴 **测试是我们的活，⛔ 不许把验证推给用户**（用户 2026-08-22 令：「你们要测试，你不能让我来测」）。
  席位在 `.app` 上验的做法：构建**独立 bundle id 的测试包**（`com.agentmirror.desktop.test`），
  自己开、自己点、自己截图。⛔ 只在测试构建里改身份，不进 PR。
  仍 ⛔ 不许 kill/open 用户正在用的那个实例；换正式包由 leader 做。
  **实撞**：我为保护用户实例下了「不许 open」，把 .app 验证也一起堵死，最后让用户去按 —— 约束写宽了。
- **两头夹住**：坏态必须红、好态必须绿。⛔ 只给「修好之后」证明不了任何事。
- **验证表面 = 交付面**：桌面壳的能力**必须在 `.app` 上验**，`npm run dev` 绿不算数，
  探针 app 绿也不算数。实撞两次：「dev 绿而 build 白」「Web 绿而桌面不绿」。
- **状态组合穷举**（布局类）：空/有内容 × 展开/折叠 × 普通/全屏 × 单列/多列。
  实撞：空态掩盖底栏回归，展开态掩盖折叠遮挡。
- **判据四态**：通过(0) / 不通过(1) / **不可判(2)** / 不适用。编译不过 ≠ 测试红。
- **自报不算数**：要么亲跑写退出码，要么判官复核，要么标「待核」。
- **判者不能是产出方**。
- **图是一手，转述是二手**：用户截图落 `.team/nodes/integrate/refs/`，让席位自己看；
  文字与图冲突以图为准。参考图若是别人家产品，**只取形态不取内容**。

## 4. 改代码

- **一次一条改动**，验过不倒退才做下一条。⛔ 不许攒一批一起上。
- **一个 PR 只装一件事**；建分支 → 提交 → 推 → `gh pr create` → 验 → merge → **立刻推 main**。
  land 之后才推 = PR 显示 closed，等于流程没发生。
- **修 bug 修根因**：改之前 grep 你要动的函数的所有调用方。
- 🔴 **回炉 / 不许污染**（用户 2026-08-22 令）：修完实测没生效 ⇒ **整条回退**，
  连它为自己开的口子（CSP、依赖、测试）一起退。⛔ 不许留半截说「反正比原来好一点」——
  **理由被推翻的改动就是噪音**，下一个人看到它不敢动，也说不清它为什么在。
  实撞：#15 幻影 CSP、#25 粘贴（桌面不生效）、#26 行高（方向错）。
- **棘轮**：`npm test` 只增不减。⛔ 不许删测试/弱化断言凑绿。
  因回退能力而下降属合法，要写明退了哪几条。
- ⛔ 不许用「让症状不可见」的修法（例：藏交通灯来消除遮挡）。
- ⛔ **不在主工作树 `git checkout`**——主树跑着活团队，切分支会删掉它的运行时状态。
  一律独立 worktree。冲突手工解，⛔ 不许自动策略。

## 5. 安全红线

- ⛔ 读凭据文件原文（`.env` / token / authkey / plist）。取值只用 `set -a; . <file>; set +a`
  注入子进程，不打印、不落日志、不入截图。
- ⛔ 无过滤 `ps aux`。进程只取 `ps -o pid,ppid,etime,stat,comm`。
- 🔴 **CSP 无因果放宽一律打回**。实撞三次全是多余的：`'unsafe-eval'`、`script-src tauri:`、
  `connect-src http:/https:` 通配。要放开先证明因果（拿违规原文），**并把裁定写成测试**。
- 配对 token 只在 `auth` 帧与上传 header 上行，⛔ 不进日志/toast/错误文案/截图。
- 产物**零 CDN 外链**；桌面壳 token 走 `tauri-plugin-store`(0600)，⛔ 不回 localStorage。
- **按 pid 杀，⛔ 不按模式杀**（`pkill -f` 误伤过 grok 席位）。端口被占**换一个，⛔ 不 kill 占用者**。
- ⛔ 写 `/tmp` 或工程外路径（隔离 tmux socket 例外，须短路径 + `list-sessions` 自检）。

## 6. 装机（用户常驻授权：并完直接换）

⛔ 不用问用户。顺序固定：

1. 构建：`CARGO_TARGET_DIR=<独立目录> CI=true npm run tauri build -- --ci --no-sign --bundles app`
2. 核版本：`dist/assets/*` 的文件名在 `.app` 里能不能找到。
3. **拷临时位 → 原子替换**。🔴 ⛔ 绝不先 `rm -rf` 目标再拷（实撞：源没了，用户一份可用包都不剩）。
4. kill 旧 → `open` 新 → 核 `lsof -nP -iTCP:9900` 有 ESTABLISHED → 核 `devices.json` 在且 0600。

主树 `node_modules` 易落后（席位各自 `npm ci`）。`Rolldown failed to resolve import` 多半是它，先 `npm install`。

## 7. 提交与模型

- commit 无需确认，验过就提交，⛔ 不许攒。⛔ 不写 `Co-Authored-By: Claude`。
- Workflow 内 agent 显式 `model: 'opus'`。⛔⛔ 禁用 Deepseek。
- 🔴 **team-agent 席位只许开 cursor 的 grok 4.6**（用户 2026-08-22 裁定，覆盖此前的「provider `grok`」）：
  角色文件写 `provider: cursor_agent`（⛔ 不是 `cursor`）+ `auth_mode: subscription` +
  `permission_mode: auto_approve` + `dangerously_skip_permissions: true`。
  🔴 **`model:` 必填，且本机实测生效。**
  - 省略 ⇒ **compile 直接失败**。CLI 这样做是对的：不写就静默落到内置默认而 argv 看着正常。
  - 写了 ⇒ **本仓库 2026-08-22 对照实验证明声明生效**：同机同版本**并发**两席，
    `integrator` 声明 `cursor-grok-4.6-high` → pane 显 `Cursor Grok 4.6 High`；
    `verifier` 声明 `cursor-grok-4.6-medium` → pane 显 `Cursor Grok 4.6 Medium`。
    两个声明不同 ⇒ 两个实跑不同。**该推断不依赖「Cursor 默认值是多少」**：
    默认若 High 则 judge 那格证明生效，默认若 Medium 则 integrator 那格证明生效。

  ✅ 框架队 2026-08-22 已复核并确认：`--model` 确实进 argv（`adapters/cursor_agent.rs`
  有测试 `cursor_role_explicit_model_reaches_argv`），他们原先「shim 剥掉」的说法作废。
  **同家族内，角色文件的 `model:` 能强制** ⇒ 用户的合规令是可以由配置保证的。

  ⚠️ 但他们同时给了两条限定，都是陷阱：
  - 🔴 **模型名必须取自该 provider 的 catalog**（查法：`cursor-agent models`）。
    跨家族或不存在的 id 会**静默兜底、零告警**，而且**兜底落点不稳定** ——
    他们同一个 `sonnet-4-thinking` 两次分别落到 `Cursor Grok 4.6 Extra High` 与 `Composer 2.5`。
    ⛔ 不许把兜底想成「落到本机默认」，它不是一个稳定值。（该缺陷已立案，短期无排期，⛔ 不要等。）
  - 🔴 **`capture-pane` 看到的是铬名，不等于实跑模型**。「pane 显示是不是实跑模型」
    框架队**答不了**（argv 只证明声明进了 CLI；无请求日志）。
  ⇒ **自证照做**（每次起/重建席位 `capture-pane`），但它只证明声明与铬名一致，
  ⛔ 不许把它当作实跑模型的证据。对不上就停下报用户，⛔ 不许自己改 Cursor 的默认设置。

  代价（写任务书时必须吃住）：**cursor 席位重启即失忆**，`--resume` 不载历史 ⇒
  ⛔ 只派**单回合自足**任务，要延续的信息一律落盘到产物文件，不许指望席位记得上一轮。
  cursor 席位当判者时，判据与证据**必须全部落盘**，⛔ 不能依赖它记得上一轮。

## 8. 单席位编排（2026-08-22 起，取代原六席位）

🔴 **框架硬限制：一个 workspace 只能有一个 cursor 席位。** 加第二个直接被拒：
`cursor_agent seat already occupies this workspace` ——
根因是 `<workspace>/.cursor/mcp.json` 是**目录作用域**的，第二席会覆盖 `TEAM_AGENT_ID`（后写者赢）。
⇒ 与 §7「只许 cursor」叠加的后果：**六席位编排作废**。⛔ 不许为绕开它在同一 workspace 硬塞第二席。

🔴 **多席位 = 多 workspace，一目录一席。这是正解，不是降级凑合。**
（框架队 2026-08-22 回信：grok 的 `<cwd>/.grok/config.toml` **同样是目录作用域**，
同一 workspace 起第二个 grok 席会**回溯性污染先起的那个**，而且**当年 `add-agent` 根本不拦**——
他们自己撞出来才写进纪律。cursor 这条至少 fail-closed 并给了 action。
他们四个席位就是四个 workspace 目录。）⇒ 要开第二席就开第二个 workspace，⛔ 不要等上游隔离。

**当前两个 workspace（2026-08-22 起）**：

| workspace | 目录 | 席位 | 干什么 |
|---|---|---|---|
| `corral-desktop` | `/Volumes/nvme/Projects/tmux桌面端`（主树，`main`） | `integrator` | **唯一写产品码** |
| `corral-judge` | `/Volumes/nvme/Projects/tmux桌面端-judge`（worktree，分支 `judge/workspace`） | `verifier` | 零上下文判官，⛔ 不写产品码 |

判官 workspace 是同一个 git 仓库的独立 worktree，有自己的 `.cursor/`，所以能各起一席。
⚠️ `quick-start` 判官队会报 `leader_receiver_unbound`（我的 leader pane 已被 `corral-desktop` 占）——
**席位照常起，照常收派单**；结果走 `team-agent collect --workspace <judge 目录>` 取，
⛔ 不要为了消这个警告去 `claim-leader`，那会把我从产出方队上解绑。

- 角色文件必须 `dangerously_skip_permissions: true`，否则席位停在确认提示上，
  症状伪装成「投递失败」。该字段只在启动生效，改文件要 `add-agent --force` 重建。
- `model:` 见 §7（必填；本机对照实验证明**生效**，但与框架队结论矛盾 ⇒ 仍以 pane 为准）。
- **起完必须 `capture-pane` 自证**：底部要显 `Cursor Agent v<版本>` + 具体模型名。
  ⛔ `ok: True` 不算起成功，⛔ 角色文件不算模型的证据。
- ⚠️ **保守假设：cursor 席位共享的目录作用域状态不止 `.cursor/mcp.json` 一处。**
  框架队 2026-08-22 明说这一条**他们没核过、不猜**，已立案查，查清会告知。
  在那之前 ⛔ 不许按「隔离了 mcp.json 就能同目录多席」做任何设计。
- 🔴 **判者独立性的实质是三件，缺一不算独立**（框架队 2026-08-22 纠正我的原文）：
  ① **判者不是产出方** ② **零上下文** ③ **破坏齿由判者选址**
  （判者自己另找一处把实现改坏，看测试红不红；⛔ 不许复用产出方给的那个反面样本）。
  ⇒ **判官优先开在第二个 workspace**。
  ⛔ **不许拿 `reset-agent --discard-session` 冒充独立判官**：它只买到②，
  同一个席位清了上下文**仍然是同一双手**，①不成立。
  实在拿不到第二个 workspace，至少让判者**自己另写反面样本**，并在产物里标明①未满足。
- **leader 不亲写产品码**，上下文留给判断。
- **投递纪律**：裁定写成文件再 `$(cat ...)` 投——正文里的反引号/尖括号会被 shell 截断
  **但 send 仍返回成功**。席位工作中投会 `send_unverified_exhausted`，**等空闲再投**。
  投递不确定时**靠产物反查，⛔ 不重投**（重投可能重复执行）。
- `ok: True` 不是送达。席位卡住读它的屏：`tmux -S <team socket> capture-pane -p -t <pane>`。
- ⛔ 不许 kill/open 用户正在用的 AgentMirror 进程；换包由 leader 做。
