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

async function defaultNativeInvoke(command, args) {
  const { invoke } = await import('@tauri-apps/api/core');
  return invoke(command, args);
}

/** Read image bytes through Tauri only; never touch the Web Clipboard API. */
export async function readClipboardImage({ nativeInvoke } = {}) {
  const invokeFn = nativeInvoke || (typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window
    ? defaultNativeInvoke : null);
  if (!invokeFn) return null;
  const image = await invokeFn('read_clipboard_image');
  const bytes = image?.bytes;
  if (!image || (!Array.isArray(bytes) && !(bytes instanceof Uint8Array)) || bytes.length === 0) return null;
  return { name: image.name || 'image', mime: image.mime || 'image/png', bytes: Uint8Array.from(bytes) };
}

/** Read Finder file paths through Tauri only; null means no native reader is available. */
export async function readClipboardFiles({ nativeInvoke } = {}) {
  const invokeFn = nativeInvoke || (typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window
    ? defaultNativeInvoke : null);
  if (!invokeFn) return null;
  const files = await invokeFn('read_clipboard_files');
  if (files == null) return [];
  if (!Array.isArray(files)) throw new Error('剪贴板文件路径无效');
  return files;
}

const SAFE_PATH = /^\/[A-Za-z0-9._/-]+$/;

/** Format absolute paths for one shell input without decoding or resolving them. */
export function formatClipboardFiles(paths) {
  if (!Array.isArray(paths) || paths.length === 0) return '';
  return paths.map((path) => {
    if (typeof path !== 'string' || !path.startsWith('/') || /[\0\r\n]/.test(path)) {
      throw new Error('剪贴板文件路径无法安全粘贴');
    }
    if (SAFE_PATH.test(path)) return path;
    return `'${path.replaceAll("'", "'\"'\"'")}'`;
  }).join(' ');
}

/** Ctrl+V is image-only: text is deliberately reported as a loud no-op. */
export async function readCtrlV({ nativeInvoke } = {}) {
  const image = await readClipboardImage({ nativeInvoke });
  return image ? { kind: 'image', attachment: image } : { kind: 'empty' };
}
