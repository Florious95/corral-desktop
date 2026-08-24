import { fileToAttachment } from '../core/upload.js';

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

function fromClipboardItem(item, type, blob) {
  return fileToAttachment({
    name: type.replace('/', '.') || 'image',
    type,
    arrayBuffer: () => blob.arrayBuffer(),
  });
}

/** Read image bytes without synthesising a keyboard or pointer event. */
export async function readClipboardImage({ navigatorObj = globalThis.navigator, nativeInvoke } = {}) {
  const read = navigatorObj?.clipboard?.read;
  if (typeof read === 'function') {
    try {
      const items = await read.call(navigatorObj.clipboard);
      for (const item of items || []) {
        const type = (item.types || []).find((x) => String(x).startsWith('image/'));
        if (type) return await fromClipboardItem(item, type, await item.getType(type));
      }
    } catch {
      // WKWebView may expose Clipboard but reject image reads; use the native seam.
    }
  }
  const invokeFn = nativeInvoke || (typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window
    ? defaultNativeInvoke : null);
  if (!invokeFn) return null;
  const image = await invokeFn('read_clipboard_image');
  if (!image || !Array.isArray(image.bytes)) return null;
  return { name: image.name || 'image', mime: image.mime || 'image/png', bytes: Uint8Array.from(image.bytes) };
}

export async function readClipboardText({ navigatorObj = globalThis.navigator } = {}) {
  if (typeof navigatorObj?.clipboard?.readText !== 'function') return '';
  try { return await navigatorObj.clipboard.readText(); } catch { return ''; }
}

/** Ctrl+V is image-only: text is deliberately reported as a loud no-op. */
export async function readCtrlV({ navigatorObj = globalThis.navigator, nativeInvoke } = {}) {
  const image = await readClipboardImage({ navigatorObj, nativeInvoke });
  if (image) return { kind: 'image', attachment: image };
  const text = await readClipboardText({ navigatorObj });
  return text ? { kind: 'text', text } : { kind: 'empty' };
}
