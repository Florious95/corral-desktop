/**
 * Windows 宿主路径与 WSL 2 (Ubuntu) 路径双向映射器
 */

const WIN_DRIVE_REGEX = /^([a-zA-Z]):[\\/](.*)$/;
const WSL_MNT_REGEX = /^\/mnt\/([a-zA-Z])(?:\/(.*))?$/;
const WSL_UNC_REGEX = /^\\\\wsl(?:\.localhost|\$)\\([^\\]+)(?:\\(.*))?$/i;

/**
 * 将 Windows 宿主路径转换为 WSL 2 POSIX 路径
 *
 * 示例：
 * - windowsToWsl("C:\\Users\\foo\\code") -> "/mnt/c/Users/foo/code"
 * - windowsToWsl("D:/work/repo") -> "/mnt/d/work/repo"
 * - windowsToWsl("\\\\wsl.localhost\\Ubuntu\\home\\foo\\code") -> "/home/foo/code"
 * - 已经是 POSIX 绝对路径直接返回
 * - ⛔ 非 WSL UNC 路径（如 \\\\evil\\share\\x）或相对路径必须 fail-closed 返回空字符串
 *
 * @param {string} winPath
 * @returns {string}
 */
export function windowsToWsl(winPath) {
  if (!winPath || typeof winPath !== 'string') return '';
  const clean = winPath.trim().replace(/^["']|["']$/g, '');
  if (!clean) return '';

  // 已经是单斜杠开头的 POSIX 绝对路径（排除 // 双斜杠网络路径）
  if (clean.startsWith('/') && !clean.startsWith('//')) {
    return clean;
  }

  // Windows 盘符 C:\... 或 C:/...
  const matchDrive = clean.match(WIN_DRIVE_REGEX);
  if (matchDrive) {
    const drive = matchDrive[1].toLowerCase();
    const rest = matchDrive[2] ? matchDrive[2].replace(/\\/g, '/') : '';
    return rest ? `/mnt/${drive}/${rest}` : `/mnt/${drive}`;
  }

  // WSL 专属 UNC 路径 \\wsl.localhost\Ubuntu\home\... 或 \\wsl$\Ubuntu\home\...
  const matchUnc = clean.match(WSL_UNC_REGEX);
  if (matchUnc) {
    const sub = matchUnc[2] ? matchUnc[2].replace(/\\/g, '/') : '';
    if (!sub) return '/';
    return sub.startsWith('/') ? sub : `/${sub}`;
  }

  // 严禁放行非 WSL UNC 路径（如 \\evil\share）或未知相对路径，一律返回空字符串以 fail-closed
  return '';
}

/**
 * 将 WSL 2 POSIX 路径转换为 Windows 路径
 *
 * 示例：
 * - wslToWindows("/mnt/c/Users/foo/code") -> "C:\\Users\\foo\\code"
 * - wslToWindows("/mnt/c") -> "C:\\"
 * - wslToWindows("/home/foo/code", "Ubuntu") -> "\\\\wsl.localhost\\Ubuntu\\home\\foo\\code"
 *
 * @param {string} wslPath
 * @param {string} [distro='Ubuntu']
 * @returns {string}
 */
export function wslToWindows(wslPath, distro = 'Ubuntu') {
  if (!wslPath || typeof wslPath !== 'string') return '';
  const clean = wslPath.trim();
  if (!clean) return '';

  // 挂载盘符 /mnt/c/... 或 /mnt/c
  const matchMnt = clean.match(WSL_MNT_REGEX);
  if (matchMnt) {
    const drive = matchMnt[1].toUpperCase();
    const rest = matchMnt[2];
    if (rest) {
      return `${drive}:\\${rest.replace(/\//g, '\\')}`;
    }
    return `${drive}:\\`;
  }

  // Linux 原生路径（以 "/" 开头）
  if (clean.startsWith('/')) {
    const rest = clean.slice(1).replace(/\//g, '\\');
    return rest
      ? `\\\\wsl.localhost\\${distro}\\${rest}`
      : `\\\\wsl.localhost\\${distro}`;
  }

  return clean;
}

// 别名导出
export const windowsToWslPath = windowsToWsl;
export const wslToWindowsPath = wslToWindows;

/**
 * 统一标准化工作区路径（对齐 WSL POSIX 与 Windows 本地路径）
 */
export function normalizeCwd(cwd) {
  if (!cwd || typeof cwd !== 'string') return '';
  const converted = windowsToWsl(cwd);
  return converted || cwd.trim();
}

/**
 * 比较两个 spaceKey 是否指向同一工作区（支持 Windows 盘符与 WSL 路径跨格式等价判定）
 * 格式：`${deviceId}::${cwd}` 或单字符串
 */
export function isSameSpaceKey(k1, k2) {
  if (k1 === k2) return true;
  if (!k1 || !k2) return false;
  const sep1 = String(k1).indexOf('::');
  const sep2 = String(k2).indexOf('::');
  if (sep1 < 0 || sep2 < 0) {
    return normalizeCwd(k1) === normalizeCwd(k2);
  }
  const dev1 = k1.slice(0, sep1);
  const dev2 = k2.slice(0, sep2);
  if (dev1 !== dev2) return false;
  const cwd1 = k1.slice(sep1 + 2);
  const cwd2 = k2.slice(sep2 + 2);
  return normalizeCwd(cwd1) === normalizeCwd(cwd2);
}

