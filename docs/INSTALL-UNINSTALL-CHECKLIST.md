# AgentMirror 安装与卸载完整生命周期核验清单（Install & Uninstall Checklist）

- **立案依据**：GitHub Issue [#192](https://github.com/Florious95/corral-desktop/issues/192)
- **修订日期**：2026-09-21
- **适用平台**：Windows (WSL 2 / NSIS) & macOS (AppKit Native / DMG)

---

## 1. 管理组件矩阵

| 组件名称 | 目标安装路径 | 权限模式 | 作用说明 | 安装行为 | 卸载行为 |
|---|---|---|---|---|---|
| **`agentmirrord`** | `~/.local/bin/agentmirrord` | `0755` | Linux 静态代理守护服务 | 自动解压/写入并启动常驻守护 | 终止进程并物理删除二进制 |
| **`token`** | `~/.config/agentmirror/token` | `0600` | 内部双向握手安全令牌 | 自动生成高熵随机令牌 | 物理删除 |
| **`providers.tsv`** | `~/tools/nodeprobe/fixtures/providers.tsv` | `0600` | Agent 启动器白名单与模板 | 自动生成标准 6 大 Provider 配置 | 物理删除 |
| **`titles.tsv`** | `~/tools/nodeprobe/fixtures/titles.tsv` | `0600` | 会话标题映射表 | 自动初始化为空配置 | 物理删除 |
| **`pi 状态检测插件`** | `~/.pi/agent/plugins/agentmirror-probe` | `0755` | 捕获并上报 Pi 节点的实时健康、Working/Idle 状态 | 自动植入并验证可用性 | 完整清理插件目录，绝不残留 |

---

## 2. 安装生命周期核验清单（Installation Checklist）

当用户执行安装向导或客户端冷启动自愈时，必须依序通过以下门禁：

- [ ] **WSL2 / 运行环境就绪检查**：
  - 检测 WSL 发行版存活状态（若为 `Stopped` 自动拉起唤醒）；
- [ ] **Pi 状态检测插件自动植入**：
  - 检查目标用户的 Pi 插件目录（如 `~/.pi/agent/plugins`）；
  - 自动将内置的 Pi 探针插件写入目标路径，赋予 `0755` 可执行权限；
  - 验证 Pi CLI 能够正常识别并加载该插件，确保前端状态灯与工作状态上报真实有效；
- [ ] **守护服务原子换包（Hot-Swap）**：
  - 先以 `TERM` / `KILL` 终止可能存在的旧版 `agentmirrord`；
  - 将安装包内置的最新 Linux 静态单文件原子拷贝至 `~/.local/bin/agentmirrord`（`chmod 0755`）；
- [ ] **配置与令牌自愈**：
  - 检查并生成权限 `0600` 的私有 Token；
  - 检查并补齐 `providers.tsv` 表格；
- [ ] **脱钩常驻启动与端口监听**：
  - 以 `sh -lc 'exec ...'` 配合 Windows `DETACHED_PROCESS` 拉起常驻进程；
  - 探测验证 `9900` 端口进入 `LISTEN` 状态；
- [ ] **零命令直通准入验证**：
  - 自动对齐本地 Token，发送 `auth` 并收到 `auth_ack {ok: true}`；
  - 收到 `listing` 并在屏幕上正确呈现全部会话，无任何配对弹窗。

---

## 3. 卸载生命周期核验清单（Uninstallation Checklist）

当用户在操作系统中执行卸载（如 Windows 控制面板卸载向导）时，必须依序执行彻底清理，严禁残留孤儿资源：

- [ ] **进程安全终结**：
  - 遍历所有 WSL 发行版，执行 `pkill -x agentmirrord` 彻底杀死运行中的后台服务，释放 `9900` 端口；
- [ ] **Pi 状态检测插件彻底移除**：
  - 物理删除 `~/.pi/agent/plugins/` 下所有由 AgentMirror 植入的探针文件与配置目录；
  - 恢复 Pi 原生初始插件配置，不留下任何失效的钩子或僵尸路径；
- [ ] **守护文件与配置物理销毁**：
  - 物理删除 `~/.local/bin/agentmirrord`；
  - 物理删除 `~/.config/agentmirror/token`；
  - 物理删除 `~/tools/nodeprobe/fixtures/` 下的 `providers.tsv` 与 `titles.tsv`；
- [ ] **宿主机本地缓存与注册表归整**：
  - 清理 `$env:LOCALAPPDATA\Programs\AgentMirror`；
  - 清理 `$env:LOCALAPPDATA\agentmirror-desktop` 缓存与 store；
  - 清理开始菜单与桌面快捷方式；
  - 清理 Windows 卸载注册表注册项；
- [ ] **系统初态验收**：
  - 验证系统进程中 `agentmirrord` 计数为 0；
  - 验证网络端口 `9900` 处于绝对未占用状态。
