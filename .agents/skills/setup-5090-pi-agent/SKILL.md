---
name: setup-5090-pi-agent
description: 将当前 Mac 的 Pi Coding Agent 配置、扩展与技能栈安全同步到 5090 Windows WSL 2 Ubuntu-24.04，并安装真实 LLM API 驱动的 Pi。
---

# setup-5090-pi-agent

把 5090 WSL 打造成 Mac Pi 的可复现后台工作环境。脚本只通过 SSH 调用 WSL，使用 Git archive 传输经过脱敏的配置树，不使用 SCP，不触碰现有 tmux pane；默认不创建或重启 Agent 会话。

## 先决条件

- 当前目录是本项目 Git checkout，并且 `origin` 的指定 ref 已经推送；远端 WSL 能通过 Git 读取该 ref。
- `ssh 5090`（或 `.env` 中的 `SETUP_5090_SSH_TARGET`）可用，目标发行版是 Ubuntu-24.04/WSL2。
- 目标 WSL 已有可用的 Node/npm。脚本不会用未审计的 curl|sh 安装 Node；缺 Node 时先按组织标准安装，再重新运行。
- 在本 skill 同目录 `.env` 中填写 `TEAM_AGENT_API_KEY` 和 `TEAM_AGENT_BASE_URL`。该文件已加入根 `.gitignore`，不得打印、提交或截图其内容。

## 凭据隔离（硬门禁）

- 只允许通过 `TEAM_AGENT_BASE_URL` 与 `TEAM_AGENT_API_KEY` 访问模型服务；不要把个人订阅带到 5090。
- 同步明确排除 `auth.json`、`models-store.json`、`credentials*.json`、OAuth/token 文件，以及 Cursor、Claude、xAI、OpenAI 的授权文件。脚本不会备份 shell 启动文件；目标上发现受禁文件或凭据字面量会 fail-closed。
- 5090 的 `.bashrc` 与 `.profile` 会显式 `unset OPENAI_API_KEY XAI_API_KEY ANTHROPIC_API_KEY`，再加载仅含 Team Agent 变量的 `~/.pi/agent/env`，并再次 unset。Pi 默认 provider/model 被固定为 Team Agent / `gpt-5.6-luna`，防止复制来的本机默认配置误走官方订阅出口。
- 脚本完成同步后会静态审计 `~/.pi/agent/`：受禁认证文件必须不存在，除 `env` 外不得含个人订阅形态字面量；审计失败即返回非零。
- `.env` 已被根 `.gitignore` 排除。不要读取、打印、提交或截图其内容；脚本输出不会显示 API key。

## 执行

```bash
cd /Volumes/nvme/Projects/tmux桌面端
bash .agents/skills/setup-5090-pi-agent/scripts/setup-5090.sh
```

常用参数：

```text
--target HOST       SSH 目标，默认读取 SETUP_5090_SSH_TARGET 或 5090
--repo-ref REF      远端 Git archive 使用的 ref，默认 SETUP_5090_REPO_REF 或当前 HEAD
--repo-url URL      远端 Git URL，默认 SETUP_5090_REPO_URL 或 origin URL
--smoke-session NAME 安装后在新 tmux session 中启动交互 Pi；不传则绝不启动 Agent
--no-global-skills  不同步 ~/.agents/skills（默认同步）
--help              显示帮助
```

脚本的同步边界：

- `~/.pi/agent/extensions/` 全量普通文件；其中本地 `team-agent-models.ts` 的硬编码 API key 会被替换为“仅从 `TEAM_AGENT_API_KEY` 读取”，任何疑似凭据内容都会 fail-closed。
- `~/.pi/agent/skills/` 与 `~/.agents/skills/` 全量技能文件（排除 `.git`、node_modules、缓存、`.env`、密钥和凭据文件）。
- `~/.pi/agent/settings.json`、`models.json`（若存在）经过 JSON 凭据字段脱敏后同步；不会同步 `auth.json`、`models-store.json`、`trust.json`、`mcp.json`、session、缓存或 npm 目录。同步后的默认路由固定到 Team Agent。
- 目标现有受管目录先以 0700 目录备份到 `~/.cache/setup-5090-pi-agent-*/backup`，然后原子替换受管内容；备份路径不包含在日志之外的凭据值。
- LLM 凭据只写入目标 `~/.pi/agent/env`（0600），并在 `.bashrc`、`.profile` 增加幂等 source hook。脚本输出只显示状态与 Pi 版本，不显示 key、完整命令或环境变量值。

## 验收

无 smoke session 时，脚本至少执行：

1. `npm install -g @earendil-works/pi-coding-agent --no-audit --no-fund`；
2. `pi --version`；
3. `pi --list-models`，输出写入受保护的临时文件后立即删除，成功只报告 pass；
4. 检查扩展、settings/models、skills 和 env 文件权限/存在性；
5. 检查认证文件缺失、个人订阅字面量未残留，以及官方 API 环境变量为空。

需要实际挂机 Agent 时，显式传入一个全新的 session 名：

```bash
bash .agents/skills/setup-5090-pi-agent/scripts/setup-5090.sh \
  --smoke-session agentmirror-pi-smoke
```

脚本只在该 session 不存在时创建它，并通过 `tmux has-session` 验证存活；不会 capture pane 正文，不会 kill 或复用任何已有 session。停止该专用 smoke session 由操作者明确执行：

```bash
ssh 5090 'wsl.exe -e bash -lc "tmux kill-session -t agentmirror-pi-smoke"'
```

## 故障处理

- API key/base URL 为空、含换行或不符合 `http(s)://` 时，脚本在本机 fail-closed。
- Git ref 无法从远端读取、资产校验失败、Node/npm/Pi 缺失或模型列表请求失败都会返回非零；脚本不会把失败伪装成“已连接”。
- 现有 tmux Agent 不会自动得到新环境；新开的 login/interactive shell 会 source hook。已有 Agent 需要用户在不影响任务的前提下自行决定何时重启。
- 5090 的 WSL daemon、AgentMirror 9900 服务和 pairing token 不由本 skill 管理；不要把 token 放入 `.env`、Git、日志或截图。
