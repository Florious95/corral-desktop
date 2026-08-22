/*
 * Upload diagnostic log — user-retrievable, never carries pairing secrets.
 * Desktop: $APP_DATA/upload.log (0600). Tests: in-memory ring.
 */

import { isTauri } from '../core/store.js';

const RING_MAX = 200;
const ring = [];

/** Drop pairing material if a caller slips (Bearer / authkey= / long blobs). */
export function scrubLogText(s) {
  let t = String(s || '');
  t = t.replace(/Bearer\s+\S+/gi, 'Bearer ***');
  t = t.replace(/[?&]authkey=[^&\s]+/gi, 'authkey=***');
  t = t.replace(/[A-Za-z0-9+/_-]{16,}/g, '***');
  return t;
}

export function buildUploadRecord({
  n, url, status, unreachable, ok, name, message,
}) {
  return {
    t: Date.now(),
    n: Number(n) || 0,
    url: scrubLogText(url || ''),
    status: status == null ? null : Number(status),
    unreachable: unreachable === true,
    ok: ok === true,
    name: scrubLogText(name || ''),
    message: scrubLogText(message || ''),
  };
}

export function rememberUploadRecord(rec) {
  ring.push(rec);
  if (ring.length > RING_MAX) ring.shift();
}

export function readUploadLogRing() {
  return ring.slice();
}

export function clearUploadLogRing() {
  ring.length = 0;
}

export async function persistUploadRecord(rec) {
  rememberUploadRecord(rec);
  if (!isTauri()) return;
  try {
    const { invoke } = await import('@tauri-apps/api/core');
    await invoke('append_upload_log', { line: JSON.stringify(rec) });
  } catch {
    /* log must never change upload outcome */
  }
}
