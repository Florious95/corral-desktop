/**
 * Windows 宿主路径与 WSL 2 (Ubuntu) 路径双向映射器
 */

const WIN_DRIVE_REGEX = /^([a-zA-Z]):[\\/](.*)$/;
const WSL_MNT_REGEX = /^\/mnt\/([a-zA-Z])(?:\/(.*))?$/;
const WSL_UNC_REGEX = /^\\\\wsl(?:\.localhost|\$)?\\([^\\]+)\\(.*)$/;

/**
 * 将 Windows 宿主路径转换为 WSL 2 POSIX 路径
 *
 * 示例：
 * - windowsToWsl("C:\\Users\\foo\\code") -> "/mnt/c/Users/foo/code"
 * - windowsToWsl("D:/work/repo") -> "/mnt/d/work/repo"
 * - windowsToWsl("\\\\wsl.localhost\\Ubuntu\\home\\foo\\code") -> "/home/foo/code"
 * - 已经是 POSIX 绝对路径直接返回
 *
 * @param {string} winPath
 * @returns {string}
 */
export function windowsToWsl(winPath) {
  if (!winPath || typeof winPath !== 'string') return '';
  const clean = winPath.trim().replace(/^["']|["']$/g, '');
  if (!clean) return '';

  // 已经是 POSIX 路径
  if (clean.startsWith('/')) {
    return clean;
  }

  // Windows 盘符 C:\... 或 C:/...
  const matchDrive = clean.match(WIN_DRIVE_REGEX);
  if (matchDrive) {
    const drive = matchDrive[1].toLowerCase();
    const rest = matchDrive[2] ? matchDrive[2].replace(/\\/g, '/') : '';
    return rest ? `/mnt/${drive}/${rest}` : `/mnt/${drive}`;
  }

  // UNC 路径 \\wsl.localhost\Ubuntu\home\... 或 \\wsl$\Ubuntu\home\...
  const matchUnc = clean.match(WSL_UNC_REGEX);
  if (matchUnc) {
    const sub = matchUnc[2].replace(/\\/g, '/');
    return sub.startsWith('/') ? sub : `/${sub}`;
  }

  return clean.replace(/\\/g, '/');
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
