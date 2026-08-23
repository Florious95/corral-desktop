# 交接 · corral-desktop leader · 2026-08-23（第二份，覆盖当日全天）

> 工程：**AgentMirror macOS 桌面客户端**，仓库 `/Volumes/nvme/Projects/tmux桌面端`，
> 远端 `https://github.com/Florious95/corral-desktop.git`。
> Tauri v2 + Vite + React 19（JSX，无 TS）+ `@xterm/xterm` 6，WebSocket 协议 v1 镜像主机 tmux 里的 Agent CLI。

---

## §0 compact 后先做什么

### 一句话现状

**只在解一件事：桌面端打开会话时，部分 Agent CLI 画面错排。**
今天走完的是**第一步**——把「什么是坏的」这个判据夯实。**修复一次没成功（已整条回退）。**
现在手上有：**用户亲手打的 ground truth**、**两种失效模式的自动化复现**、**一条零手工的截图回路**。
下一步**仍不是修**，是**加日志找确切证据**。

### 🔴 开口第一句（照说）

> 昨天到今天真正立住的只有第一步：**判据**。
> 现在有你打标的 5 个「一打开就坏」、你圈的 5 个「轮转后坏」，两种模式**都能自动复现**
> （模式二实测：停留 600ms 快切 15 次必错排，停留 2200ms 则一直好）。
> 按你「找到确切证据之前不往下走」的令，下一步是**在点击→排布完成这条路上加日志**，
> 拿你的标签去验它能不能判定坏/为什么坏。**第一个动作见 §4-A。**
> 我把后面的流程排成了五步（§2），每步都有「怎么算做完」。你看这个排法对不对？

### 必读清单（按顺序）

| # | 文件 | 为什么 |
|---|---|---|
| 1 | 本文件 | 全局 |
| 2 | `/Volumes/nvme/Projects/tmux桌面端/.team/nodes/garble/LABELS.md` | 🔴 **唯一权威标签** + 两种失效模式 + 已证否清单 + 测试禁区 |
| 3 | `/Volumes/nvme/Projects/tmux桌面端/.team/nodes/_driver/席位纪律.md` | 席位共用纪律，**§1.5 / §1.6 / §1.7 是今天新增的红线** |
| 4 | `/Volumes/nvme/Projects/tmux桌面端/.team/nodes/garble/BRIEF-evidence.md` | 下一格的任务书（已写好，**未派**） |
| 5 | `/Volumes/nvme/Projects/tmux桌面端/CLAUDE.md` | 工程流程约定 |
| 6 | `/Users/alauda/.claude/CLAUDE.md` | 全局品味准则 |

### 恢复工作流程（编号照做）

1. **先核对，后开口**（文档可能过期）：
   ```sh
   cd /Volumes/nvme/Projects/tmux桌面端
   git rev-parse --short HEAD                 # 期望 a2515bd
   npm test 2>&1 | grep -E "^# (pass|fail)"   # 期望 113 / 0
   pgrep -f "cargo-target-final/release/bundle/macos/AgentMirror.app"   # 用户的客户端 pid
   for f in .team/nodes/_driver/*.pid; do p=$(cat $f 2>/dev/null); ps -p "$p" >/dev/null 2>&1 && echo "仍活 $f pid=$p"; done
   ```
   最后一条**应无输出**（落笔时我已把 r10 / r12 / r14 三个挂起驱动和 vite 全部按 pid 停掉）。
2. **恢复守护**：本工程的看门狗是 `.team/nodes/_driver/watchdog.sh`，**只在派了格之后才需要开**。
   现在**没有在跑的格**，⛔ 不要空开。派格后用 `Bash(run_in_background)` 起它。
3. **恢复期间禁令**（做完第 1 步之前）：⛔ 不改产品码、⛔ 不换包、⛔ 不派新格、⛔ 不动用户的 tmux/AgentMirror、
   ⛔ 不删 `/Users/alauda/.team-agent/runtime/0.5.67.broken`。
4. **判"恢复完毕"**：第 1 步四条命令都符合预期，且读完必读清单 1–3。
5. **与文档不符怎么办**：**以现场为准**，并在开口第一句里把差异告诉用户，⛔ 不要自行"修正"文档后当没发生。

---

## §1 身份与不变量

- **我是 leader**：编排、判断、并线、换包。🔴 **⛔ 不亲写产品码**（测试脚本/夹具不算）。
- **席位**：`integrator`（`corral-desktop`，主树，唯一写产品码）、`verifier`（`corral-judge`，
  `/Volumes/nvme/Projects/tmux桌面端-judge`，零上下文判官，⛔ 不写产品码）。均为 `cursor_agent` / `Cursor Grok 4.6 Medium`。
- **自报不算数**：席位说做完了 ⇒ 要么我亲跑写退出码，要么判官复核，要么标「待核」。
- 🔴 **先怀疑量具，再怀疑被测物。** 今天我在这上面栽了四次，见 §3-C。
- **`ok: True` 不是送达**；投前 `team-agent status` 验活；⛔ 不凭记忆拼地址。
- **按 pid 杀，⛔ 不按模式杀**。今天差点用 `pkill` 端掉框架队六条常驻编排（§3-D）。
- ⛔ **派单正文里不许出现括号粘贴的结束标记字面量**——会截断投递而 `send` 仍返回 ok（今天实撞）。

---

## §2 排期：后面怎么走（🔴 用户特别交代，见 §2.0）

### §2.0 用户原话（⛔ 照抄，不概括）

> 「我们现在要一步一个脚印，把初始的判据夯实。然后后面才有，在这个基础上后面才有，努力的必要。
> 你要把接下来的流程安排好，相当于我们现在才走了第一步。」

⇒ **判据没夯实之前，⛔ 不许进入修复。** 下面五步，**每步都必须拿用户的标签验，不许自证**。

### 五步流程（每步给出「怎么算做完」）

| 步 | 做什么 | 怎么算做完 | 状态 |
|---|---|---|---|
| **1** | **判据的第一半：ground truth** —— 自动化截整界面图，由**用户**打标 | 用户逐张看过并指名哪些坏 | ✅ **已完成**（5 坏 / 54 好 + 第二种模式 5 个） |
| **2** | **判据的第二半：坏态可按需复现** | 两种模式各有一条命令能稳定复现，且**同一命令能产出好态对照** | ✅ **模式二已达成**；⚠️ **模式一尚未做到"按需"**（只知道它首次打开就坏，⛔ 未证明可在自建台复现） |
| **3** | **加日志，验日志能否判定** | 日志字段组合对**用户标签**做到假阳 0 / 假阴 0；达不到就写清哪两条记录字段全同而标签相反 + 缺哪个埋点 | ⬜ **下一步**，任务书已写好未派 |
| **4** | **从区别反推代码逻辑** | 根因落到**文件:行**，并给出**事前**预测判据（改前写死「改完 X 会从 A 变 B」） | ⬜ 阻塞于第 3 步 |
| **5** | **定向修 + 判官 + 换包** | 两头夹住（坏态红/好态绿）+ **好态不许坏**（逐会话列出）+ 判官独立复核 + 换包后**用户实测确认** | ⬜ 阻塞于第 4 步 |

🔴 **第 2 步的缺口要补**：模式一现在只能在**用户的真实会话**上观察到，而那些会话 ⛔ 不许反复打扰。
补法：在**自建 tmux + 自建 daemon** 上复刻出一个「首次打开即错排」的 pane。**这是第 3 步的前置**，
否则第 3 步只能在真实会话上采样，受禁区限制。

### 封存令

- 本期只做**错排**。⛔ 其它一切让路（图片上传 PR #47 等，见 §4-C）。
- ⛔ **不许再基于任何我们自己写的 detector 下结论**（`detectGarble` 已随 PR #79 整条退掉，⛔ 不许带回）。

---

## §3 P0 / 今天的插队与实撞

### §3-A 🔴 修复失败并整条回退（最重要的一条）

- **做了什么**：PR #78「捕获行按显示宽度裁到 `term.cols`」——判据全绿（含判官独立复核、破坏齿自选、对照组自跑），换包。
- **结果**：用户实测 **「这个客户端每一个会话都是错乱的」**，比修前更差。
- **处置**：PR #79 **整条退**，`src/` `test/` `docs/` 与 `6aa5921` **逐字节一致**（`git diff` 为空，已核），
  `npm test` 136 → **106**（下降 30 条全是随功能一并退掉的测试，属合法）。重新出包换机。
- 🔴 **被推翻的前提**：我假设「一个 `capture-pane` 输出行 = 一个 tmux 网格行」。
  **若成立，裁剪对正常行应是空操作**；实测全坏 ⇒ **捕获行超过 `term.cols` 是常态**。
  ⇒ `EDGE.md` 的「115 是真超宽」**至多适用于它测的那 4 条，⛔ 不可外推**。
- 🔴 **判官为什么没拦住**：它验的是「守卫是否按显示宽度工作」（验得很扎实），
  **⛔ 没验「这个前提在全场是否成立」**。**判据设计漏了这一层，是 leader 的。**

### §3-B ⚠️ 当前线上还带着一个未经用户确认的修复

`main = a2515bd` 含 **PR #80「同宽不变量」**（`src/term/sameWidth.js` + `TerminalView` / `TerminalPane`，`+110/-10`），
**已出包换机**，运行中 `.app` md5 `f5f76793966dd735dfd71161714ff091`（已核）。

🔴 **但它没解决问题**：模式二的复现（§3-E）**就是在这个版本上做出来的**。
⇒ 后继要决定：**留着还是退掉**。我的建议是**暂留**（它的失败模式是"不刷新"而非"画错"，且判官复核过），
但 ⛔ 这只是建议，用户可以随时要求退——退法见 §5。

### §3-C 🔴 leader 今天做出的**四个没有分辨力的量具**（⛔ 后继别重犯）

| # | 坏量具 | 怎么暴露的 |
|---|---|---|
| 1 | **拿自己写的 `detectGarble` 当 ground truth**，再拿日志去拟合它 | 循环论证。修复让指标全绿而画面全坏 ⇒ 标签与画面从未对齐过 |
| 2 | 把 **2x 截图**当整幅看，宣布「抓到错排」 | 用户指出「只展示了左下角 1/4」。改 dsf=1 后同一会话完全正常 |
| 3 | 用 **`convertEol: true` + 主机几何**渲染出 79 张「参考图」，拿去让用户打标 | 全部正常，零诊断价值——它画的是「本该长什么样」，不是「我们画成什么样」 |
| 4 | 「非空行数」「每行起始列分布」当判别特征 | 坏的 `%7` 有 38 个非空行（反例）；起始列分布坏/好看不出差别（那只是缩进） |

**共同教训**：⛔ 不许在没有外部 oracle 的情况下构建指标。**先有画面与人工标签，再有指标。**

### §3-D ⚠️ 差点误杀别人的进程

看到 8 个 `ledger-run` 在跑，第一反应是「我的僵尸驱动」。逐个查 `cwd`/`argv` 后发现
**六个属于框架队 `多agent协作`、`讨论team-agent`、`远程Agent安卓`**。⛔ 按模式杀会全端掉。
⇒ **认领所有权再动手**，这条已在 §1。

### §3-E ✅ 今天真正的产出：两种失效模式 + 自动化复现

见 `LABELS.md`。摘要：

| 模式 | 触发 | 名单 | 复现 |
|---|---|---|---|
| **一：一打开就坏** | 首次点开 | `reviewer-r19` `reviewer-r21` `w2-dev-b` `w2-dev-c` `grok` | 单次巡检即可（但目前只能在真实会话上，见 §2 第 2 步缺口） |
| **二：轮转后坏** | 反复切换 + **停留短** | `tester-t150` `reviewer-r16` `reviewer-r17` `tester-t151` `reviewer-r18` | ✅ **命令见 §4-A**，第 15 次必错排 |

**模式二的关键读数（leader 亲测）**：停留 **2200ms** 轮询 3 轮 ⇒ 全好；停留 **600ms** 来回快切 ⇒ 第 15 次坏。
**停留时间就是自变量。** 证据图：
`.team/nodes/garble/toggle/k15__reviewer-r17.png`（坏）对 `.team/nodes/garble/shots-rounds/r3__25__reviewer-r17.png`（好）。

### §3-F ✅ 框架侧 P0 已闭环（与产品无关，但影响协作）

**现象**：派单文本粘进席位输入框但不提交，席位静默空转（第一次 54 分钟，第二次 12 分钟）。
**根因**（框架队 2026-08-23 定性）：我方两个 coordinator 一直在跑 **`0.5.67.broken`**——
装机时 rename 不影响已运行进程，`ps` 显示新路径名而 `lsof` 才是真身。
**处置**：按 pid 杀两个 coordinator → 重拉 → `lsof` 自证不带 `.broken` → `shutdown` + `restart` 两队 →
`claim-leader` 重绑 → 判官席实测 `PING-C4D71E` **自动上屏**。**已闭环。**
🔴 ⛔ **不许删 `0.5.67.broken` 目录**（仍有进程 txt 可能指向它，删会触发 macOS kalloc 泄漏）。

---

## §4 在途未收尾任务

### §4-A 🔴 下一步第一个动作（第 3 步：加日志）

- **任务书已写好未派**：`/Volumes/nvme/Projects/tmux桌面端/.team/nodes/garble/BRIEF-evidence.md`
- **负责人**：`integrator`（workspace `/Volumes/nvme/Projects/tmux桌面端`，team `corral-desktop`）
- **⚠️ 派之前必须先补一件事**：该任务书写于「只知道模式一」的时候，**⛔ 没有涵盖模式二**。
  后继要先把 §3-E 的模式二与复现命令补进去，**并把「日志必须能区分两种模式」写成判据**。
- **前置（§2 第 2 步缺口）**：模式一目前只能在真实会话上观察。若要在禁区外采样，
  需要先在**自建 tmux + 自建 daemon** 上复刻一个「首次打开即错排」的 pane。
  **建议把这个复刻单独作为一格，排在加日志之前。**
- **怎么算做完**：产物 `.team/nodes/garble/EVIDENCE.md` 给出对 `LABELS.md` 标签的**混淆矩阵**
  （假阳 0 / 假阴 0），或如实写「未达 100% + 分不开的样本 + 缺哪个埋点」。
- **派法**：
  ```sh
  cd /Volumes/nvme/Projects/tmux桌面端
  PYTHONPATH=/Users/alauda/.claude/skills/ledger-orchestration/reference/ledgerdsl-0.1.1 \
    /usr/bin/python3 .team/nodes/_driver/账本-r16.py .team/nodes/_driver/账本-r16.json
  ledger-run --preflight .team/nodes/_driver/账本-r16.json      # 期望 rc=0 issues:[]
  nohup ledger-run --drive --resident --json .team/nodes/_driver/账本-r16.json \
    > .team/nodes/_driver/r16.out 2>&1 & echo $! > .team/nodes/_driver/r16.pid
  ```
  然后把 `watchdog.sh` 里的 `r16.out` / `r16.pid` 对上，用 `Bash(run_in_background)` 起看门狗。
- **⛔ 本格绝不修任何东西**（用户令：「找到确切证据之前，就不要往下一步去走。」）

### §4-B 可复用的量具（今天造的，⛔ 别重造）

| 脚本 | 干什么 | 关键参数 |
|---|---|---|
| `.team/nodes/garble/shots-web.mjs` | 无头 Chrome 起 Web 端，视口锁 **1400x860**（= 桌面端窗口），逐会话截**整界面** | `--origin` `--rounds N` `--out` |
| `.team/nodes/garble/toggle-web.mjs` | 两个会话之间**快速来回切**，每次截图（**模式二复现器**） | `--a` `--b` `--n` `--dwell` `--out` |

两者共同点：从 tauri store 读配对（**⛔ token 不打印**）、点击走 CDP `HTMLElement.click()`
（**⛔ 不碰系统键鼠**）、**内置 `EXCLUDE` 跳过收藏会话**。

**已有产物**：
- `.team/nodes/garble/shots-web/`（59 张，1:1，**用户已打标**）
- `.team/nodes/garble/shots-rounds/`（177 张 = 59 × 3 轮，停留 2200ms，全好）
- `.team/nodes/garble/toggle/`（16 张快切，**k15 为坏态证据**）

⚠️ **`shots-web/` 那 59 张是在加 `EXCLUDE` 之前跑的**，里面**包含 claude_code 会话**。
后继重跑时会自动跳过；⛔ 不要因为张数从 59 变少就以为夹具坏了。

### §4-C 可延后（⛔ 与本期无关，别分心）

| 项 | 状态 |
|---|---|
| PR **#47** 图片上传（native HTTP） | OPEN，很旧，需 rebase。⛔ 本期封存 |
| PR **#81** 79 张待标注截图 | OPEN，**内容已被 §3-C-3 判为无诊断价值**。建议**关掉**，⛔ 别合 |
| `settle_ms` 端到端计时 | 550 行里只有 3 条有值 ⇒ 「点击→排布准确」的端到端数字**至今给不出来**。属第 3 步的一部分 |
| 上游 `remote-agent-android` 的回信 | 见 §5，两封已发已回，**结论已吸收进本文件**，无需再追 |

---

## §5 运维与外部

### 出包换包
唯一口径：`/Volumes/nvme/Projects/tmux桌面端/docs/BUILD-AND-SWAP.md`（⛔ 退出码不经管道；⛔ 不先 `rm -rf` 目标；核 md5 不核文件名）。
**回退一次约 6 分钟**（今天跑通两次）：`git revert` 或 `git checkout <good> -- src/ test/ docs/` → 构建 → 换包 → 四条验收。

### 外部通道（今天都用过，地址已验活）

| 对方 | 地址 | 今天聊了什么 |
|---|---|---|
| ledger-run / 账本编排 维护方 | `/Volumes/nvme/Projects/讨论team-agent::wiki/leader` | 接受了「驱动器等待期不观测席位活性」为他们的 N5-a |
| team-agent 框架队 | `/Users/alauda/Documents/code/agent前沿探索/多agent协作::refactor-maintainability/leader` | §3-F 那条 P0，已定性闭环 |
| daemon/App 上游 | `/Volumes/nvme/Projects/远程Agent安卓::remote-agent-android/leader` | 🔴 **两封关键回信，结论见下** |

### 🔴 上游给的两条结论（已吸收，⛔ 不要重新问）

1. **他们撤回了「结构上不会错」**：把 235 列真 capture 喂进更窄的 `replaySnapshot(114/80)`，
   **他们的模拟器一样整屏位移、框线错列**。他们没撞见过，只因手机端**先 reshape 再拍，
   客户端网格与快照永远同宽**。⇒ 建议我们把「同宽」变成不变量（就是 PR #80 做的事）。
2. **`tmux resize-window` 确是同步 reflow**（tmux 3.6a，变宽/变窄各 6 档延迟 × n=20，
   不一致率**全 0.0%**）。**但他们只测了 tmux 格子层，⛔ 没测「应用已按新尺寸重绘完」那一层。**
3. ⚠️ 他们纠正了我一条：我说「50ms 不可达」的理由是「你们做到了」——**他们说自己也等首帧、没有更快的协议**。
   ⇒ 「50ms 目标可不可达」**目前无定论**，⛔ 不要引用我之前那个结论。

---

## §6 安全约束（原文保留，⛔ 不可弱化）

- 🔴🔴 **⛔ 绝不驱动用户的鼠标键盘**（「在测试不要动我的鼠标啊」）。⛔ `CGEvent` / HID 合成 / `cliclick` /
  `osascript` + System Events `keystroke`·`click`。**粘贴/上传/DOM 事件一律走 Chrome + CDP 在后台测**。
  `.app` 上同样不许合成输入事件。只能靠驱动真实设备才验得了 ⇒ 判**不可判**上报。
- 🔴 **⛔ 绝不在用户的真实会话上取证**（「你需要让他们在其他的地方去测试」）：⛔ 订阅 / 点击 / resize /
  任何会让 `:9900` 那台 daemon 改动用户 pane 几何的操作；**连「只订一下马上退订」也不行**（退订时
  `paneGeometry` 会再恢复一次，等于抖两下）。用自建 tmux + 自建 daemon + git 历史里的真 fixture。
- 🔴 **⛔ 收藏里的会话测试中一律不许点**（「我收藏里面的那些会话，在测试过程中都不要点」）。
  收藏 = 5 个 `claude_code` 席位，**含用户正在用的那条对话**。两个夹具已内置 `EXCLUDE`，⛔ 不许移除。
- ⛔ 任何形式读凭据文件原文（`.env` / token / authkey / plist）。取值只用 `set -a; . <file>; set +a`
  注入子进程，**不打印、不落日志、不入截图**。🔴 这条禁的是**读原文/打印**，⛔ 不是禁止使用凭据。
- ⛔ 无过滤 `ps aux`（会把 API key 打上屏）。进程只取 `ps -o pid,ppid,etime,stat,comm`。
- 🔴 **CSP 无因果放宽一律打回**（实撞三次）。要放开先证明因果（拿 `securitypolicyviolation` 原文），
  **并把裁定写成测试**。
- 配对 token 只在 `auth` 帧与上传 header 上行，⛔ 不进日志/toast/错误文案/截图。
- 桌面壳 token 走 `tauri-plugin-store`（`devices.json` 权限 **0600**），⛔ 不回 localStorage。产物**零 CDN 外链**。
- **按 pid 杀，⛔ 不按模式杀**（`pkill -f` 误伤过席位；今天差点端掉框架队六条编排）。端口被占**换一个，⛔ 不 kill 占用者**。
- ⛔ 写 `/tmp` 或工程外路径（隔离 tmux socket 例外，须短路径 + `list-sessions` 自检）。
- ⛔ 往用户正在干活的 tmux pane 发按键；⛔ kill/open 用户正在用的 AgentMirror（换包由 leader 做）。
- 🔴 **上游只读**：`/Volumes/nvme/Projects/远程Agent安卓/` 与 `Florious95/corral-serve` **一个字都不许写**。
- ⛔ 在主工作树 `git checkout`。一律独立 worktree。冲突手工解，⛔ 不许自动策略。
- ⛔ 不写 `Co-Authored-By: Claude`。
- ⛔ **不许删 `/Users/alauda/.team-agent/runtime/0.5.67.broken`**（仍有进程可能映射它，删会触发 macOS kalloc 泄漏）。
- ⛔ **不许开 fable 席位**（用户前令：「你要把 fable 席位关闭，然后没有我的允许你不能再开」）。
- ⛔ **派单正文里不许出现括号粘贴的结束标记字面量**（会截断投递而 `send` 仍返回 ok）。

---

## §7 落笔时的客观核实状态

| 项 | 值 | 怎么核的 |
|---|---|---|
| `main` | **`a2515bd`** | `git rev-parse --short HEAD` |
| `npm test` | **113 pass / 0 fail** | leader 亲跑 |
| 用户运行的 `.app` | pid `97180`，md5 `f5f76793966dd735dfd71161714ff091` | `pgrep` + `md5 -q "$(ps -o comm= -p …)"` |
| 我的 ledger-run 驱动 | **全部已停**（r10/r12/r14 按 pid 停掉） | 遍历 `.team/nodes/_driver/*.pid` 后 `ps -p`，无输出 |
| vite dev server | **已停**（pid 50123） | 同上 |
| 席位 | `integrator` `%29` / `verifier` `%28`，均 `Cursor Grok 4.6 Medium` | `capture-pane` 自证 |
| 两个 coordinator | `lsof` txt 均为 `runtime/0.5.67/`，**不带 `.broken`** | §3-F |
| 开着的 PR | **#81**（建议关）、**#47**（封存） | `gh pr list` |
| 今天并入 main 的 PR | #64…#78（埋点/分析链）→ **#79 整条退** → **#80 同宽不变量** | `git log --merges` |
