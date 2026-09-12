// Desktop-only additions to the pinned core codec. Basic frames stay in core.
import * as core from '../../deps/corral-core/web/js/protocol.js';
export * from '../../deps/corral-core/web/js/protocol.js';

const fields = Object.freeze({
  level2_subscribe: ['workspace'],
  level2_unsubscribe: [],
  level2_frame: ['workspace', 'seq', 'sessions'],
  level2_heartbeat: ['workspace', 'seq'],
  pane_mode_changed: ['ref', 'in_copy_mode'],
  scroll_wheel: ['ref', 'delta'],
  attach_preview: ['ref', 'path'],
});
export const SESSION_STATUS = Object.freeze(['working', 'idle', 'unknown']);
export const INPUT_KEYS = Object.freeze([...core.INPUT_KEYS, 'backspace']);
export const isKnownKey = (key) => INPUT_KEYS.includes(key);
export const isExtension = (type, p) => Object.hasOwn(fields, type)
  || (type === 'input' && (p?.attachment_path !== undefined || p?.keys?.includes?.('backspace')));

// Use core validation/canonicalization for req_id/ref/text and all original keys.
// A supported placeholder lets core validate the shape; the wire retains backspace.
function baseInput(p) {
  return { ...p, keys: Array.isArray(p.keys) ? p.keys.map(k => k === 'backspace' ? 'esc' : k) : p.keys };
}

export function validateFrame(type, p = {}) {
  p ??= {};
  if (!isExtension(type, p)) return core.validateFrame(type, p);
  if (type === 'input') {
    if (p.keys !== undefined && !Array.isArray(p.keys)) return 'input keys must be an array';
    if (p.text !== undefined && typeof p.text !== 'string') return 'input text must be a string';
    const error = core.validateFrame(type, baseInput(p));
    if (error) return error;
    if (p.attachment_path !== undefined) {
      if (typeof p.attachment_path !== 'string' || !p.attachment_path.startsWith('/')) return 'attachment path must be absolute';
      if (p.keys?.length) return 'input carries both text and keys; at most one is allowed';
    }
    return null;
  }
  if (fields[type].includes('workspace') && (typeof p.workspace !== 'string' || !p.workspace)) return `${type} workspace must be non-empty`;
  if (fields[type].includes('seq') && (!Number.isInteger(p.seq) || p.seq < 1)) return `${type} seq must be >= 1`;
  if (fields[type].includes('ref')) {
    const error = core.validateFrame('unsubscribe', p);
    if (error) return error;
  }
  if (type === 'scroll_wheel' && (!Number.isInteger(p.delta) || p.delta === 0)) return 'scroll_wheel delta must be a non-zero integer';
  if (type === 'attach_preview' && (typeof p.path !== 'string' || !p.path.startsWith('/'))) return 'attach_preview path must be absolute';
  if (type === 'level2_frame' && p.sessions != null && !Array.isArray(p.sessions)) return 'level2_frame sessions must be an array';
  if (type === 'pane_mode_changed' && p.in_copy_mode !== undefined && typeof p.in_copy_mode !== 'boolean') return 'in_copy_mode must be boolean';
  return null;
}

function checked(type, payload) {
  const error = validateFrame(type, payload);
  if (error) throw new core.ProtocolError('invalid_field', error);
}

export function encodeControl(type, payload = {}) {
  payload ??= {};
  if (!isExtension(type, payload)) return core.encodeControl(type, payload);
  checked(type, payload);
  let p;
  if (type === 'input') {
    p = JSON.parse(core.encodeControl(type, baseInput(payload))).payload;
    if (p.keys) p.keys = payload.keys;
    if (payload.attachment_path !== undefined) p.attachment_path = payload.attachment_path;
  } else {
    p = Object.fromEntries(fields[type].filter(k => payload[k] !== undefined).map(k => [k, payload[k]]));
    if (type === 'level2_frame') p.sessions ??= [];
    if (type === 'pane_mode_changed') p.in_copy_mode ??= false;
  }
  return JSON.stringify({ v: core.VERSION, type, payload: p });
}

export function decodeControl(text) {
  let root;
  try { root = JSON.parse(text); } catch { return core.decodeControl(text); }
  if (!isExtension(root?.type, root?.payload)) return core.decodeControl(text);
  // Reuse core's envelope/version/object checks with a payload-free known type.
  // Never mutate core FRAME_TYPES or run an extension through its field whitelist.
  core.decodeControl(JSON.stringify({ ...root, type: 'overlay_unsubscribe' }));
  const p = root.payload ?? {};
  checked(root.type, p);
  if (root.type === 'input') {
    const decoded = core.decodeControl(JSON.stringify({ ...root, payload: baseInput(p) }));
    if (decoded.payload.keys) decoded.payload.keys = p.keys;
    if (p.attachment_path !== undefined) decoded.payload.attachment_path = p.attachment_path;
    return decoded;
  }
  return { type: root.type, payload: Object.fromEntries(fields[root.type].filter(k => p[k] !== undefined).map(k => [k, p[k]])) };
}
