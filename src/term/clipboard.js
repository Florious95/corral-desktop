import { nativeCapabilities } from '../core/nativeCapabilities.js';
import { windowsToWsl } from '../lib/wslPath.js';

export function isCtrlV(ev) {
  return !!ev && ev.type === 'keydown' && ev.ctrlKey && !ev.metaKey && !ev.altKey
    && (ev.key === 'v' || ev.key === 'V');
}

export function isCmdV(ev) {
  return !!ev && ev.type === 'keydown' && ev.metaKey && !ev.ctrlKey && !ev.altKey
    && (ev.key === 'v' || ev.key === 'V');
}

export function textFromPasteEvent(event) {
  return event?.clipboardData?.getData('text/plain') || '';
}

/** Read image bytes through native capabilities only; never touch the Web Clipboard API. */
export async function readClipboardImage({ nativeInvoke } = {}) {
  if (nativeInvoke) {
    const image = await nativeInvoke('read_clipboard_image');
    const bytes = image?.bytes;
    if (!image || (!Array.isArray(bytes) && !(bytes instanceof Uint8Array)) || bytes.length === 0) return null;
    return { name: image.name || 'image', mime: image.mime || 'image/png', bytes: Uint8Array.from(bytes) };
  }
  return nativeCapabilities.clipboard.readImage();
}

/** Read Finder file paths through native capabilities only; null means no native reader is available. */
export async function readClipboardFiles({ nativeInvoke } = {}) {
  if (nativeInvoke) {
    const files = await nativeInvoke('read_clipboard_files');
    if (files == null) return [];
    if (!Array.isArray(files)) throw new Error('剪贴板文件路径无效');
    return files;
  }
  return nativeCapabilities.clipboard.readFiles();
}

const SAFE_PATH = /^\/[A-Za-z0-9._/-]+$/;
const WIN_DRIVE_PATH = /^[A-Za-z]:[\\/]/;
const WSL_UNC_PATH = /^\\\\wsl(?:\.localhost|\$)\\[^\\]+(?:\\[\s\S]*)?$/i;

/** Format absolute paths for one shell input without decoding or resolving them. */
export function formatClipboardFiles(paths) {
  if (!Array.isArray(paths) || paths.length === 0) return '';
  return paths.map((path) => {
    if (typeof path !== 'string' || /[\0\r\n]/.test(path)) {
      throw new Error('剪贴板文件路径无法安全粘贴');
    }
    // 严格白名单校验：只允许非双斜杠的 POSIX 绝对路径、Windows 盘符路径、及 WSL 专属 UNC 路径
    const isPosixAbsolute = path.startsWith('/') && !path.startsWith('//');
    const isWinDrive = WIN_DRIVE_PATH.test(path);
    const isWslUnc = WSL_UNC_PATH.test(path);

    if (!isPosixAbsolute && !isWinDrive && !isWslUnc) {
      throw new Error('剪贴板文件路径无法安全粘贴');
    }

    const posixPath = windowsToWsl(path);
    if (!posixPath || !posixPath.startsWith('/') || posixPath.startsWith('//')) {
      throw new Error('剪贴板文件路径无法安全粘贴');
    }
    if (SAFE_PATH.test(posixPath)) return posixPath;
    return `'${posixPath.replaceAll("'", "'\"'\"'")}'`;
  }).join(' ');
}

/** Ctrl+V is image-only: text is deliberately reported as a loud no-op. */
export async function readCtrlV({ nativeInvoke } = {}) {
  const image = await readClipboardImage({ nativeInvoke });
  return image ? { kind: 'image', attachment: image } : { kind: 'empty' };
}
