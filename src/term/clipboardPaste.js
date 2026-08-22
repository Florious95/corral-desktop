/*
 * DOM paste → input.text / POST /upload + input.attachment_path.
 * 不用 navigator.clipboard.read()（要权限，Tauri 也没有剪贴板插件）。
 *
 * 多行文本整段当 text 发，换行原样保留、不自动补裸 Enter —— 否则会替用户提交命令。
 * 单帧 JSON payload 上限按契约 1 MiB，文本按 UTF-8 字节切块。
 */

/** 给 JSON 外壳留余量。 */
export const PASTE_TEXT_MAX_UTF8 = 900_000;

export function wsToHttpOrigin(wsUrl) {
  const u = new URL(wsUrl);
  if (u.protocol === 'ws:') u.protocol = 'http:';
  else if (u.protocol === 'wss:') u.protocol = 'https:';
  return u.origin;
}

export function splitPasteText(text, maxUtf8 = PASTE_TEXT_MAX_UTF8) {
  if (typeof text !== 'string' || text.length === 0) return [];
  const enc = new TextEncoder();
  const bytes = enc.encode(text);
  if (bytes.length <= maxUtf8) return [text];
  const dec = new TextDecoder();
  const out = [];
  for (let i = 0; i < bytes.length; i += maxUtf8) {
    out.push(dec.decode(bytes.subarray(i, i + maxUtf8)));
  }
  return out;
}

export function pickPasteImage(data) {
  if (!data) return null;
  const files = data.files;
  if (files && files.length) {
    for (let i = 0; i < files.length; i++) {
      const f = files[i];
      if (f && typeof f.type === 'string' && f.type.startsWith('image/')) return f;
    }
  }
  const items = data.items;
  if (items && items.length) {
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      if (!it || typeof it.type !== 'string' || !it.type.startsWith('image/')) continue;
      if (typeof it.getAsFile === 'function') {
        const f = it.getAsFile();
        if (f) return f;
      }
    }
  }
  return null;
}

export function isPasteKey(ev) {
  if (!ev || ev.type !== 'keydown') return false;
  const k = ev.key;
  if (k !== 'v' && k !== 'V') return false;
  return !!(ev.metaKey || ev.ctrlKey);
}

/** @returns {Promise<'image'|'text'|'empty'>} */
export async function handleClipboardData(data, { sendText, sendImage, onError }) {
  const img = pickPasteImage(data);
  if (img) {
    try {
      await sendImage(img);
    } catch (e) {
      const msg = String((e && e.message) || e || '上传失败');
      onError(msg);
    }
    return 'image';
  }
  const text = data && typeof data.getData === 'function' ? data.getData('text/plain') : '';
  if (text) {
    for (const chunk of splitPasteText(text)) sendText(chunk);
    return 'text';
  }
  return 'empty';
}

/**
 * Desktop posts via Rust (`postUpload` / invoke). Injected `fetchImpl` is
 * only for Node tests — it must not be the gate that *skips* native.
 */
export function chooseUploadTransport({ fetchImpl, postUpload, desktop }) {
  if (typeof postUpload === 'function') return 'native';
  if (fetchImpl) return 'fetch';
  if (desktop) return 'native';
  return 'fetch';
}

export function sanitizeUploadError(status, unreachable) {
  if (unreachable) return '上传失败：无法连接';
  if (status === 401) return '上传失败：未授权';
  if (status === 413) return '上传失败：文件太大';
  return '上传失败';
}
