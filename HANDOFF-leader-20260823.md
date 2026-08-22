# HANDOFF · AgentMirror macOS 桌面端 · leader · 2026-08-23

> 覆盖 `HANDOFF-leader-20260822.md`（那份的重点「优化」已完成并被更紧急的事项取代）。
> **下阶段唯一重点：把「宽主机 pane 画面错乱」这一件事解决掉**（用户原话见 §2）。

---

## §0 compact 后先做什么

**一句话现状**：错乱问题的**根因已经用读数钉死**（不是我方渲染 bug，是 daemon 的
`pipe-pane` 单管道被第二个订阅者静默偷走），修法方向已定（客户端订阅对账看门狗，**零呈现代价**），
**但一行实现码都还没写**。用户已下令：接下来只做这一件事，并给了四条具体工作安排。

**开口第一句**（围绕用户指定的四条重点，⛔ 不要泛泛报现状）：

> 错乱的根因已经钉死在 daemon 的单管道偷管上（`.team/nodes/wide/WHY-STUCK.md`，双连接台架四步逐行复现）。
> 按你给的四条安排，我打算这样开：**先做第 1 条（无头浏览器复现出错乱画面）和第 2 条（错乱判据的日志/数据输出）**，
> 因为第 3 条（快速回路）要靠这两条当量具，第 4 条（读源码定向解决）要靠这两条验收。
> 第一个动作是 `<见 §4-A 的具体命令>`。你看这个顺序对吗？

**必读清单**（按优先级，全绝对路径）

1. 本文件
2. `/Volumes/nvme/Projects/tmux桌面端/.team/nodes/wide/WHY-STUCK.md` —— 🔴 **根因实锤，205 行，必读**
3. `/Volumes/nvme/Projects/tmux桌面端/.team/artifacts/求助-终端宽度错乱-20260823.md` —— 现象/坐标/**五条已排除的路**
4. `/Volumes/nvme/Projects/tmux桌面端/.team/nodes/wide/ANALYSIS.md` —— 上一轮分析（**其中安卓诊断已被 WHY-STUCK 修正，见 §3**）
5. `/Volumes/nvme/Projects/tmux桌面端/CLAUDE.md` —— 工程流程约定（§3 量具与证据、§4.5 扰动窗口、§5 安全红线）
6. `/Volumes/nvme/Projects/tmux桌面端/docs/BUILD-AND-SWAP.md` —— 出包换包唯一口径
7. `/Volumes/nvme/Projects/tmux桌面端/.team/artifacts/ledger-trial-findings.md` —— 编排工具的 12 条优化清单（只积攒不直投）

### 恢复工作流程（照做，做完才算接上）

**第 1 步 · 先核对，后开口**（文档写的是落笔那一刻，可能已过期）：

```sh
cd /Volumes/nvme/Projects/tmux桌面端
git log --oneline -1                                   # 期望 09b8b4b 或更新
git status --porcelain | grep -v '^??'                 # 期望空
sh scripts/acc-npm-test.sh 106                         # 期望 rc=0，# pass ≥106
gh pr list --repo Florious95/corral-desktop --state open --json number,headRefName
team-agent status --workspace "$(pwd)" --team corral-desktop
team-agent status --workspace /Volumes/nvme/Projects/tmux桌面端-judge --team corral-judge
pgrep -f "cargo-target-final/release/bundle/macos/AgentMirror.app"   # 用户的 app 在不在跑
for p in $(pgrep -x ledger-run); do lsof -a -p "$p" -d cwd -Fn | grep '^n'; done  # 驱动器归属
```

**第 2 步 · 先恢复守护**：账本驱动器若不在跑，按 §4 的命令重起（**一次只许一个**，
起完写 pid 文件 `.team/nodes/_driver/优化两点.pid`）。

**第 3 步 · 恢复期间 ⛔ 不许**：
- ⛔ **开 fable 席位**（用户令，见 §3-B，**未经用户允许不得再开**）
- ⛔ 重跑已 merged 的 PR、⛔ 动上游、⛔ 在主工作树 `git checkout`
- ⛔ 在「第 1、2 条量具建成」之前写产品码修错乱（用户四条安排的顺序就是理由）

**第 4 步 · 判恢复完毕**：上面命令读数与本文件一致 + 用户确认 §0 的开工顺序。

**第 5 步 · 与文档不符**：以现场为准，差异写回本文件；涉及验收口径变化的先问用户。

---

## §1 身份与不变量

- **leader 不亲写产品码**（含不解冲突）。建队、写任务书、裁定、核 diff、merge、出包换包、写文档是 leader 的。
- 🔴 **自报不算数**：要么亲跑写退出码，要么独立判官复核，要么标「待核」。
- 🔴 **两头夹住**：坏态必须红、好态必须绿。**今天两次翻车（#54/#55）都是只验了前一半。**
  判据里必须显式包含「**原本正常的不许被弄坏**」和「**既有能力不许丢**」。
- 🔴 **⛔ 绝不驱动用户的鼠标键盘**（`CGEvent` / `osascript keystroke` / `cliclick`）。
  用户本人在同一台机器上工作。测试走 Chrome + Chrome DevTools MCP 后台。
- 🔴 **理由被推翻的改动整条退**，连它为自己开的口子（CSP／依赖／测试）一起退，⛔ 不留半截。
- **一事一 PR 一闭环**；merge 前必查三条（§5）；land 后立刻推 main。
- **判者独立三件**：不是产出方 + 零上下文 + **破坏齿由判者自己选址**。
- **席位模型**：cursor `provider: cursor_agent` + `model: cursor-grok-4.6-medium`。
  ⚠️ `model` 必填且**必须取自 `cursor-agent models` 的 catalog**（跨家族/不存在的 id 会**静默兜底且零告警**，落点不稳定）。
  起完必须 `capture-pane` 自证；⛔ `ok: True` 不算起成功，⛔ 角色文件不算模型证据。
- **一个 workspace 只能有一个 cursor 席位**（`.cursor/mcp.json` 目录作用域）。
  ⇒ 多席位 = 多 workspace。**Claude 席位不受此限**（实测与 cursor 席位可共存）。

---

## §2 用户给的下阶段工作安排（原话，⛔ 不许概括）

> 接下来的工作安排，就解决这一个事情。
> **第一件事**要形成图像化能够看得到的判据，就是能够确切地通过无头浏览器去操作，得到画面，**复现出画面错乱的样式、现场**。
> **第二点**，构建日志体系，能够从代码逻辑层面知道当前画面是错乱的，并且日志能够展示。又或说日志输出一些数据，从这些数据可以得到，可以分析出它是错乱的。
> **第三点**，形成快速的测试与开发回路。
> **第四点**，开发要调转方向，要去找现有的实现，甚至读具体的源码，有针对性地去解决这个问题。
> 你要把 fable 席位关闭，然后没有我的允许你不能再开。

**leader 对顺序的理解**（待用户确认）：1 与 2 是量具，3 依赖 1+2，4 用 1+2 验收。
⇒ **先建量具，再动实现。** 这也和「五轮都在没有可信量具的情况下改代码」的教训一致。

**本期封存（未解封）**：新建文件夹、新建 Agent、联通远端、加远端节点。

---

## §3 P0 / 重大事项

### A. 🔴 错乱根因已钉死（**这是本轮最大产出，⛔ 别让它丢了**）

**结论**：不是我方渲染 bug，不是「有人抢宽度」。是 **daemon 的三件套**。

**产物**：`.team/nodes/wide/WHY-STUCK.md`（205 行）+ 探针
`probe-why-stuck.mjs` / `probe-two-subs.mjs` / `probe-A-seat92.json` / `probe-B-control.json` / `probe-two-subs.log`

**已证伪的旧前提**（leader 编的，整条链都建在它上面）：
- 「另一个 tmux 客户端把 `%88` 拽回 235」⇒ **假**。整个 socket 上**只有一个**附着客户端，
  且在 leader 会话上；出问题的 `team-refactor-maintainability` 会话 `list-clients` **为空**。
- 所有窗口的**窗级** `window-size` 都是 **`manual`** ⇒ 附着客户端尺寸**根本不参与几何**。
- 当年读到 `latest` 的那次**读的是全局值不是窗级** —— **量具错读，已坐实**。

**我方 reshape 一直是生效的**：`%92` 订阅后 **0.3s 内 235→100 并保持 22s**；
对照组（无第二订阅者）**60s 全程不回弹**。

**真正的制造者**（双连接台架在**真 daemon** 上逐行复现，`probe-two-subs.log`）：

```
[2.7s] X sub@100 : pane 100x50 pipe=1，X 收到快照
[3.9s] Y sub@120 : pane 120x50 —— X 最后一帧停在 2.741s，此后永远无帧、无错误帧
[7.4s] Y unsub   : pane 235x50 pipe=0  ← X 仍自认订阅中，daemon 恢复了基线
[9.0s] X resize@101: 宽度不变、无新帧  ← 服务端已不认 X 订阅，静默忽略
```

1. **`pipe-pane` 是单管道** —— 第二个连接订同一 pane 会**静默偷走**第一个的管子。
2. **老订阅者服务端被拆、零通知** —— 客户端仍自认订阅中（冻结）。
3. **第二订阅者退订时 count 归零**，`paneGeometry` 把 pane **恢复成基线 235×50**。

⇒ 🔴 **「手机端没问题」正是该机制的签名：最后订阅的永远是好的，先到的被静默杀死。**

**现场残留指纹**（只读盘点）：`%75`（developer-d128）137×42 但 `pipe=0` —— 桌面尺寸、无活管。

**修法（零代价，纯客户端，⛔ 尚未实现）**：**订阅对账看门狗** ——
listing 报的几何 ≠ 我方被授予的值、**持续 2 个周期** ⇒ 节流重订阅；
连试 ≤3 次仍被夺 ⇒ **显式提示「已被其它客户端接管」**。
**无缩字号 / 无横滚 / 不动网格策略。A/B 呈现取舍对本案作废**，上一轮 FOLLOW 方案降级为后备。

**最小上游改动（建议，不依赖）**：第二订阅者到来时给老订阅者发一帧 `kicked`。
⛔ 上游只读，要改得先告诉用户。

**不可判项（如实）**：daemon 日志进 `/dev/null` 读不到 `br.Resize` 返回值；
当年 `%88` 现场无法重放；`handleSubscribe` 里 **resize 失败不致命、继续按当前尺寸镜像**
（`ws_handler.go:156-158`）是「撕裂而非冻结」形态的另一条候选路径，无法回查。

### B. 🔴 用户令：fable 席位已关，⛔ 未经允许不得再开

**已执行**（本次交接前）：

```
team-agent remove-agent analyst-fable --workspace /Volumes/nvme/Projects/tmux桌面端 \
  --team corral-desktop --confirm --force
→ ok: True  status: removed  agent_health_deleted: true
```

复核：`tmux list-panes -a` 只剩 `claude_code` / `integrator` / `verifier`，**无 `analyst-fable`**。
⚠️ 它的产物**保留**在 `.team/nodes/wide/`（ANALYSIS.md / WHY-STUCK.md / 探针），⛔ 不要删。

### C. leader 今天的三次判断失误（写进来防复发）

| 失误 | 现象 | 正确做法 |
|---|---|---|
| 把「上游安卓怎么做」当免检 | 批准 #54「一辈子只 resize 一次」⇒ **分列与拖窗口不再重排** | **抄上游前先检查它那条规矩的前提在本端是否成立**（安卓只有 IME 挤压，桌面的分列/拖窗是真实几何变化） |
| 判据只写「坏态转绿」 | 批准 #55「无条件跟随主机宽度」⇒ **更多会话错乱** | 判据必须显式含「**好的不许被弄坏**」「**既有能力不许丢**」 |
| 把「#58 失败」错误归因到「横滚这个呈现」 | 在派单里**禁了 A**，逼出 A/B 取舍题 | #58 死因是**只撑列不撑行 + 几何战争没停 + 首帧宽度推断数学不成立**，**与横滚无关**。⇒ **归因要指到机制，⛔ 不许连坐** |

---

## §4 在途未收尾任务

### A. 🔴 下阶段第一项：按用户四条安排解决错乱（**尚未开工**）

**为什么是它**：用户原话「接下来的工作安排，就解决这一个事情」。根因已钉死（§3-A），
但**五轮修复全部失败**的共同原因是**没有可信量具**——所以用户先要量具（第 1、2 条）。

**下阶段第一个动作**（具体到命令/文件，⛔ 不许写「继续推进」）：

1. 给 `integrator` 派**量具格**（⛔ 不是实现格），任务书落
   `.team/nodes/wide/BRIEF-instrument.md`，要求：
   - **第 1 条**：Chrome + Chrome DevTools MCP（**无头/后台，⛔ 不碰用户鼠标**）驱动 `npm run dev`，
     **确定性复现**错乱画面并**截到图**。复现手段用 §3-A 的机制：**自建 daemon + 自建 pane +
     两个连接先后订同一 pane**（偷管 → 老订阅者冻结）。⛔ 不许碰用户的任何 pane。
   - **第 2 条**：错乱的**机器可读判据 + 日志**。已知可用判据：
     顶栏 `─` 连续长度、badge 起始列 vs `term.cols`、badge 落在第几视觉行（0 = 正常）。
     日志要能从**代码逻辑层面**输出这些数，⛔ 不是靠人眼看图。
   - 交付物：`.team/nodes/wide/INSTRUMENT.md` + 复现脚本 + **坏态截图** + 判据脚本。
   - 判据：**坏态必须红**（脚本判定 torn=true 且有图）、**好态必须绿**（正常 pane torn=false）。
2. **怎么算做完**：`sh <判据脚本>` 在坏态 rc=1、好态 rc=0，且 `.team/nodes/wide/` 下有坏态 PNG。

**顺序约束**：第 3 条（快速回路）依赖 1+2；第 4 条（读源码定向修）用 1+2 验收。
⇒ ⛔ **量具没建成之前不许写修复码。**

**负责人**：`integrator`（cursor 席位，workspace `/Volumes/nvme/Projects/tmux桌面端`，team `corral-desktop`）。
⚠️ 上下文曾到 87%，随时可能需要 `add-agent --force` 重建（cursor 重启即失忆，任务书与产物都在盘上，不会从零开始）。

### B. 账本与驱动器（可延后，但别误判为卡死）

| 项 | 值 |
|---|---|
| 账本 | `.team/nodes/_driver/账本-优化两点.json`，**revision 35** |
| 账本源码（受限 Python DSL） | `.team/nodes/_driver/账本-优化两点.py` |
| 驱动器 | `ledger-run --resident`，**pid 41165**（核对归属：`lsof -a -p <pid> -d cwd -Fn` 要含 `tmux桌面端`） |
| 日志 | `.team/nodes/_driver/优化两点.out` |
| pid 文件 | `.team/nodes/_driver/优化两点.pid` |

**三格仍 `planned`（都可延后，⛔ 别平均用力）**：
`t.pill-verify`（胶囊补判，**用户已手验过三个键正常**，走形式收口即可）、
`t.resize-verify`、`t.up-verify`（上传，卡在粘贴事件没触发）。

**重起驱动器的完整序列**（⛔ 一次只许一个）：

```sh
cd /Volumes/nvme/Projects/tmux桌面端
# 1) 停旧（按 cwd 核过归属的 pid）
for p in $(pgrep -x ledger-run); do c=$(lsof -a -p "$p" -d cwd -Fn | grep '^n' | cut -c2-); \
  case "$c" in *tmux桌面端*) kill -TERM "$p";; esac; done
sleep 3
# 2) 清陈旧租约（⛔ 先确认持有者已死）
L=.team/nodes/_driver/账本-优化两点.json.lease
[ -f "$L" ] && { LP=$(/usr/bin/python3 -c "import json;print(json.load(open('$L'))['pid'])"); \
  ps -o pid= -p "$LP" >/dev/null 2>&1 || rm -f "$L"; }
rm -f .team/nodes/_driver/账本-优化两点.json.resident-exit
# 3) 打针（改账本）——⛔ 席位在途时不打针
R=/Users/alauda/.claude/skills/ledger-orchestration/reference/ledgerdsl-0.1.1
PYTHONPATH="$R" /usr/bin/python3 - <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("acct", ".team/nodes/_driver/账本-优化两点.py")
m = importlib.util.module_from_spec(spec); sys.argv = ["acct", "/dev/null"]
spec.loader.exec_module(m)
from ledgerdsl.applyops import plan, apply
print(plan(m.ledger, ".team/nodes/_driver/账本-优化两点.json").render())   # 先看影响面
apply(m.ledger, ".team/nodes/_driver/账本-优化两点.json")
PY
# 4) 过门 + 起
ledger-run --preflight .team/nodes/_driver/账本-优化两点.json
ledger-run --dry-run  .team/nodes/_driver/账本-优化两点.json | head -5
nohup ledger-run --resident .team/nodes/_driver/账本-优化两点.json >> .team/nodes/_driver/优化两点.out 2>&1 &
```

🔴 **打针必先 `plan()` 看影响面**：`provenance` 一改会**把所有已完成格重置重跑**。
只给需要重跑的格单独换 `provenance`（脚本里已有 `PROV` / `PROV2` / `PROV3` 三档示范）。

🔴 **挂起（parked）不是卡死**：驱动器只在 **revision 前进**时解挂。
「我修的是仓库不是账本」时会无 delta 可造 —— 这是编排工具的已知痛点（清单 P4）。
⛔ 不许为了解挂编造假变更；找一个**真实**的字段变化（如 `provenance` 换到新基线、判据体量收紧）。

### C. 唯一开着的 PR：#47（可延后）

`feat/upload-native-http` —— 图片上传走 Tauri 原生 HTTP 绕开 WKWebView 的 CORS。
**mergeable=UNKNOWN**（基线已变，需 rebase）。卡点：**粘贴事件根本没触发 `uploadImage`**
（三种驱法、零条日志），疑似焦点问题（点了侧栏没点进终端内容区）。
⚠️ 该 PR 的验证曾依赖合成输入事件，**现已被红线禁止** ⇒ 要改走 Chrome 后台合成 `ClipboardEvent`。

---

## §5 运维与外部

- **远端仓**：`Florious95/corral-desktop`（private）。`gh` 已登录 `Florious95`。
  **统计（已核）**：`MERGED=58 CLOSED=3 OPEN=1`。
- **上游（只读）**：Go daemon 源码 `/Volumes/nvme/Projects/远程Agent安卓/server/internal/`，
  远端 **`Florious95/corral-serve`**（⚠️ 更正：先前误记为 `corral-core`；用户确认**该仓即最新，服务端未做任何修改**）。
  安卓客户端 `/Volumes/nvme/Projects/远程Agent安卓/app`（同协议，可参考）。
- **出包换包**：唯一口径见 `docs/BUILD-AND-SWAP.md`。用户常驻授权「**并完直接换，⛔ 不用问**」。
  🔴 **核版本用 md5，⛔ 不用 CLAUDE.md §6 写的「`dist/assets/*` 文件名比对」——那个量具在本工程失效**
  （资源压缩进二进制，阳性对照 `tauri`/`agentmirror` 命中均为 0）。
  二进制名是 **`agentmirror-desktop`**，⛔ 不是 `AgentMirror`。
- **merge 前必查三条**（都实撞过）：
  `git log origin/main..origin/<分支>`（有没有判官没看过的提交）、
  `git diff origin/main origin/<分支> --stat | grep -E "inputAckGate|ChromePill|nativeInput"`（会不会把已合修复带回去）、
  `git show origin/<分支>:CLAUDE.md | grep -c "绝不驱动用户的鼠标键盘"`（会不会删红线，必须 ≥1）。
- **用户的 app 当前未在跑**（`pgrep` 为空）。最后一次换包 `main`=`09b8b4b`，md5 `c51e669e16afd7bc0a26173490a9b42d`。
- **team-agent 私有 socket**：`/private/tmp/tmux-501/ta-eb63cbe5b286`。
- **两个 workspace**：产出方 `/Volumes/nvme/Projects/tmux桌面端`（team `corral-desktop`，席位 `integrator`）；
  判官 `/Volumes/nvme/Projects/tmux桌面端-judge`（分支 `judge/workspace`，team `corral-judge`，席位 `verifier`）。
  ⚠️ 判官队 `quick-start` 会报 `leader_receiver_unbound`（leader pane 已被产出方队占）——
  **席位照常起、照常收派单**，⛔ 不要为消警告去 `claim-leader`。
- **外部直报通道**：team-agent 框架问题投
  `/Users/alauda/Documents/code/agent前沿探索/多agent协作::refactor-maintainability/leader`；
  ledger-orchestration 问题投 `/Volumes/nvme/Projects/讨论team-agent::wiki/leader`。
  ⚠️ **投前先 `team-agent status` 验活**；`ok: True` 不是送达。**同一对方一天 ≤10 个往返**
  （今日与框架队已用 7）。编排工具的优化项**只积攒到 `.team/artifacts/ledger-trial-findings.md`，⛔ 不直投**。

---

## §6 安全约束（原文保留，⛔ 不可弱化）

- 🔴🔴 **⛔ 绝不驱动用户的鼠标键盘**（用户 2026-08-22 令：「在测试不要动我的鼠标啊」）。
  ⛔ `CGEvent` / HID 合成 / `cliclick` / `osascript` + System Events `keystroke`·`click`。
  **粘贴/上传/DOM 事件一律走 Chrome + Chrome DevTools MCP 在后台测**（用户同令：
  「粘贴这个事情通过 Chrome 是可以在后台测的」）。`.app` 上**同样不许合成输入事件**。
  只能靠驱动真实设备才验得了 ⇒ 判**不可判**上报。
- ⛔ 任何形式读凭据文件原文（`.env` / token / authkey / plist）。取值只用
  `set -a; . <file>; set +a` 注入子进程，**不打印、不落日志、不入截图**。
  🔴 这条**禁的是读原文/打印，⛔ 不是禁止使用凭据**；需要真 daemon 就自己
  `openssl rand -hex 16` 生成一次性 token 注入 env。
- ⛔ 无过滤 `ps aux`（会把 API key 打上屏）。进程只取 `ps -o pid,ppid,etime,stat,comm`。
- 🔴 **CSP 无因果放宽一律打回**（实撞三次全是多余的：`'unsafe-eval'`、`script-src tauri:`、
  `connect-src http:/https:` 通配）。要放开先证明因果（拿 `securitypolicyviolation` 原文），
  **并把裁定写成测试**。当前 CSP：`default-src 'self'; connect-src 'self' ipc: ws: wss:;
  img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'`。
- 配对 token 只在 `auth` 帧与上传 header 上行，⛔ 不进日志/toast/错误文案/截图。
- 桌面壳 token 走 `tauri-plugin-store`（`devices.json` 权限 **0600**），⛔ 不许回退到 localStorage。
- 产物**零 CDN 外链**。
- **按 pid 杀，⛔ 不按模式杀**（`pkill -f` 误伤过席位）。端口被占**换一个，⛔ 不 kill 占用者**。
- ⛔ 写 `/tmp` 或工程外路径（隔离 tmux socket 例外，须短路径 + `list-sessions` 自检）。
- ⛔ 往用户正在干活的 tmux pane 发按键；⛔ kill/open 用户正在用的 AgentMirror 进程（换包由 leader 做）。
- 🔴 **上游只读**：`/Volumes/nvme/Projects/远程Agent安卓/` 与 `Florious95/corral-serve`
  **一个字都不许写**。需要上游改动 ⇒ 记进 `.team/nodes/_night/BACKLOG-UPSTREAM.md` 并告诉用户。
- ⛔ 在主工作树 `git checkout`（主树跑着活团队）。一律独立 worktree。冲突手工解，⛔ 不许自动策略。
- ⛔ 不写 `Co-Authored-By: Claude`。

---

## §7 本轮已交付（已核，供后继判断"哪些别再动"）

| 修复 | PR | 状态 |
|---|---|---|
| 回车 ack 死锁（`waitAck` 无超时 + 重连不清表）⇒ `src/term/inputAckGate.js` 单一闸口 | #49 | 已合，独立判官 pass，已装 |
| 悬浮胶囊 chrome（红灯真关闭，⛔ Dock 不留残留） | #50 | 已合，**用户手验三个键正常** |
| 终端应答被当用户输入回传（`11;rgb:…` + 一颗 Escape）⇒ `consumeTerminalReplies` | #52 | 已合，独立判官 pass，已装 |
| 切换首帧错乱（本地 `term.resize` 延迟到几何落定） | #53 | 已合，**仍在 main** |

| 已回退（⛔ 不要重走） | 失败原因 |
|---|---|
| #51 fit 像素锁 | 被 #54 取代后 **CLOSED**；方向对但不解决本问题 |
| #54 一辈子只 resize 一次 | **回归：分列与拖窗口不再重排** |
| #55 无条件跟随主机宽度 | **更糟：更多会话错乱** |
| #58 + #59 + #60 + `3d04c7d` 撑 buffer + 横滚 | **未解决 + 性能回退**；死因 = 只撑列不撑行 / 几何战争没停 / 首帧宽度推断数学不成立 |

**回退整条干净**（PR #56、#57、#61）：`git diff b2f02c9` 为空，`npm test` 106。
