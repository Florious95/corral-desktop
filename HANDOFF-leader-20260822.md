# HANDOFF · AgentMirror macOS 桌面端 · leader · 2026-08-22

> 覆盖同日所有旧版交接。**下阶段重点：优化**（用户原话：「接下来工作重点是优化。」）

---

## §0 compact 后先做什么

**一句话现状**：桌面端可用且用户正在用它工作（`main` = `7702d33`，36 PR MERGED / 1 CLOSED / 0 开着，
`npm test` 97/97 全绿，已核）。功能面基本收口，**下阶段重点转向「优化」**，但「优化」的具体范围
用户还没界定 —— 需要先问清，⛔ 不许自己挑一个方向就开工。

**开口第一句**（围绕用户指定的重点，不要泛泛报现状）：
> 桌面端功能面已收口（36 PR 全 merged，97 测试绿，你正在用 `7702d33`）。你说下阶段重点是优化 ——
> 优化哪一块？我这边看到四个候选，按我判断的收益排序：
> ① **启动与首帧**（打开到看见会话列表要 ~1.5s，`listing` 到达后 DOM 还空窗约 1s）
> ② **渲染性能**（WebGL 已上，但没量过帧率／大量输出时的表现）
> ③ **包体与依赖**（bundle 594KB→ 现约 600KB+，单 chunk 超 500KB 警告一直在）
> ④ **代码结构**（37 个 PR 快速迭代留下的重复与死角，例如 `src/lib/` 与 `src/core/` 职责重叠）
> 你点一个，或者告诉我你觉得哪里"不够顺手"，我从体感倒推。

**必读清单**（按优先级，全绝对路径）
1. 本文件
2. `/Volumes/nvme/Projects/tmux桌面端/CLAUDE.md` —— 工程流程约定（**§3 量具与证据必读**，今天栽最多的地方）
3. `/Volumes/nvme/Projects/tmux桌面端/.team/nodes/_night/BACKLOG-UPSTREAM.md` —— 挂起等上游 core 的两条
4. `/Volumes/nvme/Projects/tmux桌面端/docs/UI-SPEC.md` / `docs/CLIENT-CONTRACT.md` —— UI 与协议真相源
5. `/Volumes/nvme/Projects/tmux桌面端/.team/nodes/integrate/HOVER-TOGGLE.md` —— 最后一轮的待核项

**恢复动作**：六席位在跑（已核）。塌了就：
```bash
cd /Volumes/nvme/Projects/tmux桌面端
team-agent status                     # 六行都有「空闲/工作」才算活
team-agent quick-start .team/current  # 死了才用；角色文件在磁盘上
```

### 恢复工作流程（照做，做完才算接上）

1. **先核对，后开口**：
   ```bash
   git -C /Volumes/nvme/Projects/tmux桌面端 log --oneline -1     # 期望 7702d33 或更新
   gh pr list --repo Florious95/corral-desktop --state all --limit 100 --json number,state
   npm test                                                      # 期望 97/97
   team-agent status
   pgrep -f "AgentMirror.app/Contents/MacOS"                     # 用户的 app 在不在跑
   ```
2. **先恢复守护，后推进**：派长任务前先挂两件互补的东西 —— 事件探针（盯产物落盘）+ 30 分钟心跳
   （能发现「探针死了」）。会话级的东西不会跟过来。
3. **恢复期间 ⛔ 不许**：重跑已 merged 的 PR、动上游仓库、在主工作树 `git checkout`、
   kill 用户正在用的 AgentMirror 进程、在「优化范围」未确认前开新实现分支。
4. **判恢复完毕**：上面五条命令读数与本文件一致 + 用户已回答「优化哪一块」。
5. **与文档不符**：以现场为准，差异写回本文件；涉及验收口径变化的先问用户。

---

## §1 身份与不变量

- **leader 不亲写产品码**。建队、写任务书、裁定、核 diff、merge、写文档、换包 —— 这些是 leader 的。
- **自报不算数**：要么亲跑写退出码，要么独立判官复核，要么标「待核」。
- 🔴 **测试是我们的活，⛔ 不许把验证推给用户**（用户 2026-08-22 令：「你们要测试。你不能让我来测。」）。
  席位在 `.app` 上验的做法：构建**独立 bundle id 的测试包**（`com.agentmirror.desktop.test`），
  自己开、自己点、自己截图。⛔ 只在测试构建里改身份，不进 PR。
- 🔴 **验证表面 = 交付面**：桌面壳的能力必须在 `.app` 上验；`npm run dev` 绿不算数，探针 app 绿也不算数。
- 🔴 **理由被推翻的改动整条退**（用户令：「所有说了没改的都要回退，不然就是污染代码」），
  连它为自己开的口子（CSP／依赖／测试）一起退。
- **判据四态**：通过(0) / 不通过(1) / **不可判(2)** / 不适用。编译不过 ≠ 测试红。
- **一事一 PR 一闭环**；land 之后立刻推 main。
- **席位模型**：provider `grok`，`model: grok-4.6`（用户裁定）。

---

## §2 排期与封存令

### 下阶段第一项：**优化**（用户 2026-08-22 令，原话：「接下来工作重点是优化。」）

**为什么是它**：功能面已收口 —— 验收口径（左侧目录 / 目录下 Agent / 右侧分列 / WS+Token 联通）
早已达成并经真机验收；此后 20 多个 PR 都在补交互与观感。用户现在**每天用它工作**，
瓶颈从「能不能用」转成「顺不顺手」。

**⚠️ 范围未界定**：用户只说了「优化」，没说优化哪一块。⛔ 不许自己挑一个开工。
先问（§0 开口第一句已给出四个候选 + 一个倒推问法）。

**下阶段第一个动作**（问清范围之后才做，⛔ 不许跳过提问）：
- 若选 ①启动与首帧：先**量**，不改代码。在 `.app` 上记四个时间点 —— 进程起、首帧渲染、
  `auth_ack` 到达、首个 `listing` 到达、侧栏出现第一行。**怎么算做完**：四个数字落盘到
  `.team/nodes/perf/BASELINE.md`，且能指出最大的那一段在哪。
- 若选 ②渲染性能 / ③包体 / ④代码结构：同理**先量后改**，基线数字先落盘。
- 🔴 通则：**优化必须有前后两组数字**。没有基线的优化 = 不可判，⛔ 不许并。

### 本期封存（未解封）

新建文件夹、新建 Agent、联通远端、加远端节点。⛔ 做多了和做少了一样是不满足。

---

## §3 P0 / 插队项

**本轮无 P0**。但有一条**我造成的流程事故**，已闭合，写在这里防复发：

- **现象**：我 merge #36 之后，席位继续往同一个分支推了两个提交，其中 `8290fba` 才是全屏 hover 的真根因
  （热区读了陈旧的 `yMax`）。我把一个半成品（`0b8a9a4`）换给用户用了。
- **根因**：「就地更新 PR」模式下，我 merge 前没核 `git log origin/main..origin/<branch>`，
  merge 后也没告诉席位「该分支已封」。
- **止血**：另开 PR #37 收进来，已 merge（`7702d33`）。
- **正确做法**：merge 前先 `git log origin/main..origin/<branch>` 确认没有落下的提交；
  merge 后立刻通知席位「这条分支已封，后续另开」。

---

## §4 在途未收尾任务

⚠️ **全部与「优化」无关，按用户的重点令，这些都标「可延后」。** 但不许当成不存在。

| # | 任务 | 卡在哪 | 下一步 | 优先级 |
|---|---|---|---|---|
| 1 | **全屏 hover 折叠钮的实机取证** | **取证障碍，非实现**。席位三轮都没能在真全屏下截到折叠钮浮现：系统全屏顶栏把左上角 mousemove 吃掉，调试 POST 从未到达 | 换取证手段（真移光标并保持 / CDP 强制伪类 / `:focus-within`）+ DOM 读数（rect + computed opacity） | 可延后 |
| 2 | **图片粘贴端到端截图** | HTTP 层**已核**（席位自起 daemon:19940，`POST /upload` 得 200 与 401）；但「粘贴 → CLI 出现 attachment」整条链没有图 | 用席位自己的 daemon + 自己起的 tmux pane，在测试包里粘一张图截图 | 可延后 |
| 3 | `.team/` 产物入库 | 全部未入库（任务书、判词、截图、证据 JSON） | 想留档单开 PR。`.team/runtime/`、`.team/logs/` 已 gitignore，⛔ 不要加回去 | 可延后 |

**负责人**：以上全部是 `integrator`（team-agent 席位，workspace `/Volumes/nvme/Projects/tmux桌面端`，
team `corral-desktop`）。无常驻驱动进程 —— 靠**产物落盘**判进度，不是靠 `status`。

🔴 **判停滞的正确口径**（今天实撞）：`team-agent status` 报「工作」**不等于**它在干活 ——
席位留着未停的后台任务会让状态永远是「工作」。今天我因此空等 40 分钟而它闲了 36 分钟。
⇒ 产物 mtime 超过 ~15 分钟不变就**读屏取证**：
```bash
tmux -S /private/tmp/tmux-501/ta-eb63cbe5b286 capture-pane -p -t team-corral-desktop:integrator
```

### 挂起等上游 core（⛔ 桌面端不许做变通实现）

详见 `.team/nodes/_night/BACKLOG-UPSTREAM.md`：
1. **原始字节透传** —— `Ctrl-D` / `Ctrl-A` / `Ctrl-E` / `Ctrl-R` / `Ctrl-Z` / `Shift-Tab` /
   `Home` / `End` / `PgUp` / `PgDn` / `F1`–`F12` / `Alt` 组合。协议 v1 的 `keys` 是 8 值闭集
   （`esc` `ctrl_c` `tab` `up` `down` `left` `right` `backspace`），表达不了。
2. **鼠标点击透传** —— 协议里只有 `scroll_wheel`，没有任何点击帧。

⛔ 不许就近映射、伪造按键、拿别的帧凑合 —— 那比「发不出去」更坏，用户会以为发出去了。
当前行为：吞掉 + 底部短暂提示「协议发不了：…」。

---

## §5 运维与外部

- 远端仓：`Florious95/corral-desktop`（private）。`gh` 已登录 `Florious95`。
- **正式包路径**：`/Volumes/nvme/cargo-target-final/release/bundle/macos/AgentMirror.app`
  （当前 `7702d33`，mtime 08-22 14:16，**已核在跑**）。
- **装机流程**见 CLAUDE.md §6（用户常驻授权「并完直接换」，⛔ 不用问）。
  🔴 三条实撞纪律：⛔ 退出码不许经管道；核版本用 `dist/assets/*` 文件名比对（⛔ 不许 grep 源码标识符，
  资源压缩存恒假阴性）；⛔ **绝不先 `rm -rf` 目标再拷**。
- 🔴 **资源约束：grok 周额度剩 5%**（08-22 从 integrator 席位屏幕读到 `Weekly limit left: 5%`）。
  六席全跑在 grok 上，额度归零 = 全队停摆。
  **备选**：环境里有 `cursor-teammate` skill，可把执行席换成 cursor 订阅。
  代价：cursor 席位**重启即失忆**，只接单回合自足任务；要重写角色文件 + 重建席位。**换不换由用户定。**
- team-agent 私有 tmux socket：`/private/tmp/tmux-501/ta-eb63cbe5b286`。
  ⛔ 用户默认 `tmux list-sessions` 看不到 worker 是正常的。
- 上游只读：`/Volumes/nvme/Projects/远程Agent安卓/` 与 GitHub `Florious95/corral-core`，全程未写入。
- 外部通告：无。

---

## §6 安全约束（原文保留，不可弱化）

- ⛔ 任何形式读凭据文件原文（`.env` / profile / token / authkey / plist）。
  取值只用 `set -a; . <file>; set +a` 注入子进程，**不打印、不落日志、不入截图**。
- ⛔ 无过滤 `ps aux`（会把 API key 打上屏）；进程只取 `ps -o pid,ppid,etime,stat,comm`。
- 🔴 **CSP 无因果放宽一律打回**。今天实撞三次全是多余的：`'unsafe-eval'`、`script-src tauri:`、
  `connect-src http:/https:` 通配。要放开先证明因果（拿违规原文），**并把裁定写成测试**。
  当前 CSP：`script-src 'self'`，`connect-src` 只多 `ipc:` 与 loopback 的 http/https。
- 配对 token 只在 `auth` 帧与上传 header 上行，⛔ 不进日志/toast/错误文案/截图。
- 桌面壳 token 走 `tauri-plugin-store`，`devices.json` 权限 **0600**，⛔ 不许回退到 localStorage。
- 产物**零 CDN 外链**。
- **按 pid 杀，⛔ 不按模式杀**（`pkill -f` 误伤过 grok 席位）。
  端口被占**换一个，⛔ 不许 kill 占用者**（可能是用户正在跑的东西）。
- ⛔ 写 `/tmp` 或工程外路径（隔离 tmux socket 例外，须短路径 + `list-sessions` 自检 ——
  建 socket 失败时 tmux **不报错，静默回退到用户真实 tmux**）。
- ⛔ 往用户正在干活的 tmux pane 发按键；需要真 pane 就起自己的。
- ⛔ kill/open 用户正在用的 AgentMirror 进程（换正式包由 leader 做）。
