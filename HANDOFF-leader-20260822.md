# HANDOFF — AgentMirror macOS 桌面端 · leader · 2026-08-22

> 写作时点:Workflow 第二阶段(Build)完成、**按用户明令在 Build 边界停机**之后。
> 用户交代本文档重点:**基于第二阶段完成后的信息写交接** —— 见 §B「第二阶段完成态快照」,那一节是本文档的核心,证据均为现场核实。

---

## §0 compact 后先做什么

**一句话现状**:在 `/Volumes/nvme/Projects/tmux桌面端` 用一个 5 阶段 Workflow(全 agent 跑 Opus)构建 AgentMirror macOS 桌面客户端;前两阶段(Foundations 3 agent + Build 5 agent)已完成,**用户明令"第二阶段完成后停下"**,已在 Integrate 刚启动数秒时 TaskStop。现在等用户审阅/发话才能续跑。

**开口第一句**(compact 后对用户说):
> 「Build 阶段成果已落盘:npm test 58/58 绿(我亲测),vite build 还有 2 个已定位的 import 断点(App.jsx 引了不存在的 `./lib/provider.js` 与 `./lib/icons.jsx`,属集成阶段要对齐的活)。两份规格在 docs/,源码在 src/,均未提交 git。你审完发话,我就 resume Workflow 从 Integrate 续跑(缓存秒回已完成的 8 个 agent),之后是三路对抗验证 + 修复 + 真机验收门。」

**必读清单**(按序):
1. 本文档全文,尤其 §B(第二阶段快照)与 §C(协议漂移三条)。
2. `/Volumes/nvme/Projects/tmux桌面端/docs/CLIENT-CONTRACT.md`(602 行)——**§0 权威顺序警告必读**:实现 > 文档,三处 protocol.md 已被服务端推翻。
3. `/Volumes/nvme/Projects/tmux桌面端/docs/UI-SPEC.md`(810 行)——UI 唯一事实来源,读它就不用再读设计稿。
4. 设计稿原件(仅存疑时回看):`design-handoff/cross-platform-desktop-ui-mockups/project/Agent App Prototype.dc.html`(**核心蓝本,用户点名**);`Desktop Mockups.dc.html` 只取 macOS 窗口 chrome 规格。
5. 用户全局规则 `/Users/alauda/.claude/CLAUDE.md`(禁写 memory、禁 AskUserQuestion、简洁优先、外科手术式修改)。

**恢复工作流程(编号步骤,做完才算恢复完毕)**:
1. **先核对,后开口**:
   ```bash
   cd /Volumes/nvme/Projects/tmux桌面端
   git log --oneline          # 应为:546844f scaffold…、63b5fd6 chore…(共 2 个)
   git status --short | wc -l # 应 ≈13 行未提交(feature 产物,见 §B)
   npm test 2>&1 | tail -3    # 应 pass 58 / fail 0
   ```
   与本文档不符 → 以现场为准,把差异报给用户再动。
2. **不要急着修 build**:`npm run build` 的 2 个断点是集成阶段的活(§B.4),恢复期间手痒去修 = 抢 Integrate agent 的活还破坏 resume 缓存一致性。
3. **恢复期间禁令**:①禁碰 `/Volumes/nvme/Projects/远程Agent安卓/`(上游只读);②禁 git commit(用户未叫提交;集成 agent 的提交动作在续跑时自然发生);③禁重跑任何 feature agent(文件已在盘上,重跑会重复/冲突);④**禁在用户发话前 resume Workflow**——停机是用户明令,续跑要用户点头。
4. **判"恢复完毕"**:上面三条核对命令结果与文档一致(或差异已向用户说明),且已把「开口第一句」说出去。
5. 现场与文档冲突时:现场为准,冲突点报用户。

---

## §1 身份与不变量

- 角色:本工程唯一操盘手(无 team-agent 团队;`.team/` 下只有 logs/runtime,非协作团队)。
- **模型铁律(用户两次强调)**:Workflow 内所有 agent 显式 `model: 'opus'`(Opus 5)。续跑/新开 agent 同样遵守。
- **上游只读**:`/Volumes/nvme/Projects/远程Agent安卓/`(服务端 + web 客户端 + 协议文档)只能读,禁止任何写入。
- **实现 > 文档**:协议问题以 `server/internal/` Go 源码与 `docs/CLIENT-CONTRACT.md` 为准,`docs/protocol.md` 有三处已过期(§C)。web 端 `client.js` 读 `s.state`/`w.aggregate_state` 的代码是死代码,不得照抄。
- 用户全局规则生效:禁写 memory;禁 AskUserQuestion(直接对话问);技术栈已裁定(Tauri v2 + Vite + React 19 JSX 无 TS + @xterm/xterm 6,npm),不要重开技术选型。
- 客观核对不凭自报:agent 报绿必须亲跑命令复核(本文档所有"已核"均为我亲跑)。

## §2 排期与验收(用户裁定原文要点)

**当前验收标准(用户原话大意,2026-08-22 收窄)**:
> 核心是把当前主机所有目录在左边摆出来,每个目录下的 Agent 摆出来,右边可以分列展示。主机只有 Local。本地基于 WS 链接 + Token 联通。做到这一点就是验收标准。

**明确排除在本期外(用户明令"之后要做,不是现在")**:新建文件夹、新建 Agent、联通远端、加远端节点。多设备 UI 壳已作为超集实现,但**验收只看 Local 单设备**。
**成品排除项(用户配图指认)**:设计稿底部的「图标 · 运行/空闲」画廊条是审阅用私例,成品没有(已写进 UI-SPEC「不做」清单)。
**停机令**:「build 完成之后就停下来……第二阶段完成之后就停下」——已执行,是当前一切等待的原因。

排期(5 阶段 Workflow):Foundations ✅ → Build ✅ → **Integrate(停在此前)** → Verify(3 路对抗)→ Fix → (workflow 外)真机验收门。

## §B 第二阶段完成态快照(用户特别交代,证据可核)

### B.1 Workflow 案卷
- 运行 ID:`wf_d89509d4-8ac`;任务 ID `wp8bq60m6`(**已 TaskStop,2026-08-22**)。
- 脚本(续跑用):`/Users/alauda/.claude/projects/-Volumes-nvme-Projects-tmux---/1179e67a-ad03-49d5-80ac-48afbd547087/workflows/scripts/build-agentmirror-desktop-wf_d89509d4-8ac.js`
- 案卷/journal:`/Users/alauda/.claude/projects/-Volumes-nvme-Projects-tmux---/1179e67a-ad03-49d5-80ac-48afbd547087/subagents/workflows/wf_d89509d4-8ac/`(journal.jsonl + 每 agent 的 .jsonl 全文)。
- **续跑命令**(仅在用户发话后):`Workflow({scriptPath: <上面脚本路径>, resumeFromRunId: "wf_d89509d4-8ac"})` —— 已完成 8 个 agent 走缓存秒回,从 Integrate 重新起跑(Integrate agent `af8d1d7ab8fe246be` 当时只跑了几秒即被杀,无实质写入,resume 会全新重跑它,正常)。

### B.2 已完成 agent(8/8,均自报完成且关键项我已复核)
| agent | ID | 产物 |
|---|---|---|
| spec:ui | ad66e573780c576e1 | docs/UI-SPEC.md(810 行,138 token,组件 props 契约,「不做」清单) |
| spec:contract | a44e5c863cd1e1f13 | docs/CLIENT-CONTRACT.md(602 行,§0 漂移警告 + vendor 判定 + DeviceManager API + mock daemon 规格) |
| scaffold | ae8183c237d274f2d | 骨架四门全绿,**已提交 546844f(已核 git log)**;react 19.2.8 / vite 8.2.2 |
| feat:core | a95c038150b81c687 | src/core/{devices,store,providers}.js + scripts/mock-daemon.mjs + 2 测试文件 |
| feat:sidebar | a5921f8e1a760ed97 | src/components/sidebar/ 5 文件(含 ProviderIcon.jsx) |
| feat:terminal | a398e162bbaf77b08 | src/components/terminal/ 5 文件 + src/term/TerminalView.js + terminal.test.js |
| feat:chrome | a16db0d3f0fe89fec | src/components/chrome/ 7 文件 |
| feat:app-shell | acd05429be10f7f65 | src/App.jsx、src/styles/{tokens,app}.css、main.jsx/index.html 调整 |

### B.3 已核事实(我亲跑,2026-08-22)
- `npm test`:**pass 58 / fail 0**(vendor 协议 golden + core-devices 真连 mock + core-providers + terminal)。
- `git log`:仅 2 commit(63b5fd6 设计稿基线、546844f 脚手架)。**全部 feature 产物未提交**(git status ≈13 条:docs/、scripts/、src/components/、src/core/、src/styles/、src/term/、3 个新测试、App.jsx/main.jsx/vendor 两文件的修改)。
- `npm run build`:**失败,恰好 2 个断点**(已核,原文):
  - `[UNRESOLVED_IMPORT] Could not resolve './lib/provider.js' in src/App.jsx`(3:31)
  - `[UNRESOLVED_IMPORT] Could not resolve './lib/icons.jsx' in src/App.jsx`
- `cargo check`:脚手架阶段 agent 自报绿且 546844f 后 src-tauri/ 无改动 → **大概率仍绿,标待核**(Integrate 会重跑)。

### B.4 断点定性(给 Integrate 或手工接管者)
app-shell agent 臆造了 `src/lib/` 路径;实际位置:provider 推断在 `src/core/providers.js`(导出名待核,feat:core 自报 `inferProvider` 语义存在)、图标组件在 `src/components/sidebar/ProviderIcon.jsx`。修法二选一:改 App.jsx 的两行 import 指到真实路径,或建 `src/lib/` 薄 re-export。**这正是 Integrate 阶段设计要干的活**(props 签名走查以 UI-SPEC 为仲裁),不止这两行——五模块并行开发,其余 props 漂移未验,Integrate 必须全量走查。

## §C 协议漂移三条(契约 agent 实测 Go 源码;我核过契约文档,未逐行复核 Go)

照 `docs/protocol.md` 写会静默出错,**以 CLIENT-CONTRACT.md §0 为准**:
1. **listing 无状态字段**(060 uproot):session 无 status/provider、title 恒空、workspace 无 aggregate_state。状态/provider/标题走 **`level2_*` 直播流**,且一条连接同时只能订阅**一个** workspace 的 level2 → 只有选中 space 有实时状态点,其余灰空心。聚合态客户端自算:有 working→working,否则有 idle→idle,否则 unknown。
2. **状态三值闭集** `working/idle/unknown`,无 blocked/done。设计稿琥珀点(blocked)/绿对勾(done)分支保留但当前 daemon 永不触发,**验收不演示**。
3. **input 语义**(059 直通):`text` 打字**不回车**;空 text = 裸回车提交;`keys` 按键不回车(8 值闭集,web 端漏了 `backspace`,补丁已含)。InputBar「发送」= 两帧(text + 裸 Enter)。

另:protocol.js/client.js 是「vendor + 只加不改的追加补丁」(新帧类型 level2_*、pane_mode_changed、scroll_wheel、attach_preview、attachment_path 字段等),golden 夹具测试全绿是协议未漂移的唯一证据,**不得改动既有编解码路径**。

## §4 在途未收尾任务(按序,全部等用户发话)

1. **续跑 Workflow(Integrate → Verify → Fix)** — 负责人:本 leader;命令见 §B.1;无活进程可查(已停),进度信号 = journal.jsonl 追加。Integrate 验收 = npm test / vite build / cargo check 三门全绿 + 集成提交;Verify = 协议/UI 保真/冒烟三路对抗(schema 化 findings);Fix = 逐条修复后终门全绿。
2. **真机验收门(workflow 外,我对用户的承诺)** — 起真 daemon:`cd /Volumes/nvme/Projects/远程Agent安卓/server && go run ./cmd/agentmirrord -listen 0.0.0.0:9900`(token 见服务端 README:默认自动生成持久化在用户配置目录 `agentmirror/token`,或 `AGENTMIRROR_TOKEN` 显式);桌面端连 `ws://127.0.0.1:9900/ws` + token,验证:左侧摆出本机全部 tmux 目录(含 team-agent 私有 socket 存量会话)→ 每目录 Agent 列表 → 右侧分列镜像实时终端。**这是用户的最终验收标准(§2)**。
3. (远期,用户已排到之后)新建文件夹/新建 Agent/远端节点——**不做,别捡起来**。

## §5 运维与外部

- mock daemon:`node scripts/mock-daemon.mjs`(测试自起自停,不需常驻)。dev:`npm run dev`(端口 1430);桌面壳:`npm run tauri dev`。
- 无外部通告、无跨团队依赖。ledger/team-agent 通道本工程未启用。
- 磁盘/额度无异常;src-tauri 首次 cargo 编译慢属正常。

## §6 安全约束(原文级,不可弱化)

- 配对 token 只在 `auth` 帧上行一次;**不回显、不落日志、不进错误文案**;UI 输入框密文态。
- `TS_AUTHKEY` 只允许环境变量,**禁 argv**(进程列表/shell history 可见);不打印、不截图。
- token 持久化于 localStorage(桌面 WebView 同源存储)——不得引入任何第三方远程脚本;构建产物应零 CDN 外链(Verify 冒烟含此检查项)。
- 服务端 token 文件 `agentmirror/token`(0600):不复制、不打印、不截图其内容。
- 上游仓 `/Volumes/nvme/Projects/远程Agent安卓/` 只读,包括其凭据与日志文件一律不读不动。
