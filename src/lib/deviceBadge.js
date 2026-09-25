import { isLocalUrl } from '../core/local.js';

/**
 * 判断是否为本地主机标识（IP/localhost/loopback 等）
 * @param {string} [name]
 * @param {string} [url]
 * @returns {boolean}
 */
export function isLocalHost(name = '', url = '') {
  if (url && isLocalUrl(url)) return true;
  if (name && isLocalUrl(name)) return true;
  if (!name) return false;
  const lower = String(name).trim().toLowerCase();
  return lower === 'local'
    || lower === 'localhost'
    || lower.startsWith('localhost:')
    || lower === '127.0.0.1'
    || lower.startsWith('127.0.0.1:')
    || lower === '::1'
    || lower === '[::1]'
    || lower.startsWith('[::1]:');
}

/**
 * 提取精简紧凑的设备别名（UI-SPEC §5.2 / §5.3，Issue #312）
 * @param {string} [name]       设备名称
 * @param {Object} [options]
 * @param {boolean} [options.deviceLocal] 是否为本机
 * @param {string} [options.deviceUrl]   设备连接 URL
 * @returns {string} 精简别名，如 'Local', '5090', 'Server'
 */
export function formatDeviceBadge(name = '', options = {}) {
  const { deviceLocal = false, deviceUrl = '' } = options;

  if (deviceLocal || isLocalHost(name, deviceUrl)) {
    return 'Local';
  }

  const raw = String(name || '').trim();
  if (!raw) {
    if (deviceUrl) {
      try {
        const u = new URL(deviceUrl);
        return u.hostname || 'Remote';
      } catch {
        return 'Remote';
      }
    }
    return 'Remote';
  }

  // 1. 若包含 5090（如 "Windows 5090 · 安卓 APP"），优先呈现 5090 极简别名
  if (/\b5090\b/i.test(raw)) {
    return '5090';
  }

  // 2. 若包含 " · " 分隔符，取第一段有效别名
  let alias = raw.split(' · ')[0].trim();

  // 3. 若别名形如 ws://host:port/ws 或 http://host:port，提取 host
  if (/^wss?:\/\//i.test(alias) || /^https?:\/\//i.test(alias)) {
    try {
      const u = new URL(alias);
      alias = u.host || u.hostname || alias;
    } catch {}
  }

  // 4. 若为 IP:Port 或 host:9900，剔除冗余默认端口（如 :9900）
  alias = alias.replace(/:9900$/, '');

  return alias || 'Remote';
}

/**
 * 生成设备 Hover 完整提示文案（UI-SPEC / Issue #312）
 * @param {string} [name]
 * @param {Object} [options]
 * @param {string} [options.deviceUrl]
 * @returns {string}
 */
export function getDeviceBadgeTitle(name = '', options = {}) {
  const { deviceUrl = '' } = options;
  const rawName = String(name || '').trim();
  const rawUrl = String(deviceUrl || '').trim();

  if (rawName && rawUrl && rawName !== rawUrl) {
    return `${rawName} (${rawUrl})`;
  }
  return rawName || rawUrl || 'Device';
}
