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

/** Ctrl+V is image-only: text is deliberately reported as a loud no-op. */
export async function readCtrlV({ nativeInvoke } = {}) {
  const image = await readClipboardImage({ nativeInvoke });
  return image ? { kind: 'image', attachment: image } : { kind: 'empty' };
}
