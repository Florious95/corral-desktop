import React from 'react';
import { TerminalIcon } from '../../lib/icons.jsx';

/**
 * Windows WSL 2 环境探测与自愈引导卡片
 *
 * @param {Object} props
 * @param {'idle'|'checking'|'starting'|'unready'|'error'} props.state
 * @param {Object} [props.envStatus]
 * @param {string} [props.errorMsg]
 * @param {() => void} [props.onRetry]
 */
export default function WslBootstrapCard({
  state = 'checking',
  envStatus = null,
  errorMsg = '',
  onRetry,
}) {
  let title = '正在连接 WSL 会话服务...';
  let subtitle = '正在检测 Windows WSL 2 与 Ubuntu 运行状态';
  let commandHint = '';

  if (state === 'starting') {
    title = '正在唤醒 WSL 2 会话服务...';
    subtitle = 'WSL 2 (Ubuntu) 与 tmux 环境已就绪，正在后台启动 agentmirrord 守护进程';
  } else if (state === 'unready') {
    title = 'WSL 2 会话环境未就绪';
    if (envStatus && !envStatus.wsl_installed) {
      subtitle = 'Windows 尚未安装 WSL 2 子系统，请打开终端执行安装：';
      commandHint = 'wsl --install';
    } else if (envStatus && !envStatus.ubuntu_installed) {
      subtitle = '尚未安装 Ubuntu 发行版，请执行命令安装：';
      commandHint = 'wsl --install -d Ubuntu';
    } else if (envStatus && !envStatus.tmux_installed) {
      subtitle = 'Ubuntu 中尚未安装 tmux，Agent 会话管理依赖 tmux：';
      commandHint = 'wsl -d Ubuntu -e sudo apt-get update && sudo apt-get install -y tmux';
    } else if (envStatus && !envStatus.service_installed) {
      subtitle = 'WSL 2 中未安装 Agent 会话服务，请在 Ubuntu 中执行命令安装：';
      commandHint = 'go install github.com/Florious95/corral-core/server/cmd/agentmirrord@latest';
    } else {
      subtitle = '请检查 WSL 2 运行状态并确保 Ubuntu 可正常启动';
    }
  } else if (state === 'error') {
    title = 'WSL 会话服务连接失败';
    subtitle = errorMsg || '无法拉起会话服务，请确保 agentmirrord 或 corral-core 在 WSL 中可执行';
    if (envStatus && !envStatus.service_installed) {
      subtitle = 'WSL 2 中未安装 Agent 会话服务，请在 Ubuntu 中安装 agentmirrord：';
      commandHint = 'go install github.com/Florious95/corral-core/server/cmd/agentmirrord@latest';
    } else if (errorMsg && errorMsg.includes('service_not_installed')) {
      subtitle = 'WSL 2 中未安装 Agent 会话服务，请在 Ubuntu 中安装 agentmirrord：';
      commandHint = 'go install github.com/Florious95/corral-core/server/cmd/agentmirrord@latest';
    } else if (errorMsg && (errorMsg.includes('token') || errorMsg.includes('令牌'))) {
      subtitle = errorMsg;
      commandHint = 'wsl -d Ubuntu -e cat ~/.config/agentmirror/token';
    }
  }

  const isLoading = state === 'checking' || state === 'starting';

  return (
    <div className="app-empty wsl-bootstrap-card" data-wsl-state={state}>
      <div className={`app-empty-icon wsl-icon${isLoading ? ' is-loading' : ''}`}>
        <TerminalIcon size={24} />
      </div>
      <div className="app-empty-title">{title}</div>
      <div className="app-empty-sub">{subtitle}</div>

      {commandHint && (
        <div className="wsl-command-box">
          <code>{commandHint}</code>
        </div>
      )}

      {onRetry && (
        <button
          type="button"
          className="app-empty-btn wsl-retry-btn"
          onClick={onRetry}
        >
          {isLoading ? '重新检测' : '重试检测'}
        </button>
      )}
    </div>
  );
}
