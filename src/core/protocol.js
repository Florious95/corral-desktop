// Desktop-only additions to the pinned core codec. Basic frames stay in core.
import * as core from '../../deps/corral-core/web/js/protocol.js';
export * from '../../deps/corral-core/web/js/protocol.js';

const fields = Object.freeze({
  auth_ack: ['ok', 'reason', 'agent_launchers'],
  create_agent: ['req_id', 'workspace', 'anchor_ref', 'provider', 'name', 'bypass'],
  create_agent_result: ['req_id', 'ok', 'ref', 'name', 'naming', 'reason'],
  close_session: ['req_id', 'ref'],
  close_session_result: ['req_id', 'ok', 'reason'],
  level2_subscribe: ['workspace'],
  level2_unsubscribe: [],
  level2_frame: ['workspace', 'seq', 'sessions'],
  level2_heartbeat: ['workspace', 'seq'],
  pane_mode_changed: ['ref', 'in_copy_mode'],
  presence_update: ['ref', 'has_mobile', 'mobile_count', 'desktop_count'],
  scroll_wheel: ['ref', 'delta'],
  attach_preview: ['ref', 'path'],
  subscribe: ['ref', 'rows', 'cols', 'client_type', 'retain_pane_size'],
});
export const MAX_INPUT_BYTES = 1 << 20;
export const SESSION_STATUS = Object.freeze(['working', 'idle', 'unknown']);
export const INPUT_KEYS = Object.freeze([...core.INPUT_KEYS, 'backspace']);
export const isKnownKey = (key) => INPUT_KEYS.includes(key);
export const isExtension = (type, p) => (type !== 'subscribe' && Object.hasOwn(fields, type))
  || (type === 'subscribe' && (p?.client_type !== undefined || p?.retain_pane_size !== undefined))
  || (type === 'input' && (p?.attachment_path !== undefined
    || p?.bytes !== undefined
    || (p?.keys !== undefined && (!Array.isArray(p.keys) || p.keys.includes('backspace')))));

function asBytes(value) {
  if (value instanceof Uint8Array) return value;
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (Array.isArray(value) && value.every((n) => Number.isInteger(n) && n >= 0 && n <= 255)) {
    return Uint8Array.from(value);
  }
  return null;
}

function base64Encode(value) {
  if (typeof value === 'string') return base64Length(value) >= 0 ? value : null;
  const bytes = asBytes(value);
  if (!bytes) return null;
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

function base64Length(value) {
  if (typeof value !== 'string' || value.length === 0 || value.length % 4 !== 0
    || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) return -1;
  try { return atob(value).length; } catch { return -1; }
}

function bytesLength(value) {
  const bytes = asBytes(value);
  return bytes ? bytes.length : base64Length(value);
}

// Use core validation/canonicalization for req_id/ref/text and all original keys.
// A supported placeholder lets core validate the shape; the wire retains extensions.
function baseInput(p) {
  const { bytes: _bytes, ...withoutBytes } = p;
  return {
    ...withoutBytes,
    keys: Array.isArray(p.keys) ? p.keys.map(k => k === 'backspace' ? 'esc' : k) : p.keys,
  };
}

export function validateFrame(type, p = {}) {
  p ??= {};
  if (!isExtension(type, p)) return core.validateFrame(type, p);
  if (type === 'input') {
    if (p.keys !== undefined && !Array.isArray(p.keys)) return 'input keys must be an array';
    if (p.text !== undefined && typeof p.text !== 'string') return 'input text must be a string';
    const error = core.validateFrame(type, baseInput(p));
    if (error) return error;
    const hasText = (typeof p.text === 'string' && p.text.length > 0)
      || (typeof p.attachment_path === 'string' && p.attachment_path.length > 0);
    const hasKeys = Array.isArray(p.keys) && p.keys.length > 0;
    if (p.attachment_path !== undefined
      && (typeof p.attachment_path !== 'string' || !p.attachment_path.startsWith('/'))) {
      return 'attachment path must be absolute';
    }
    if (p.bytes !== undefined) {
      const size = bytesLength(p.bytes);
      if (size < 0) return 'input bytes must be standard base64 or byte array';
      if (size === 0) return 'input bytes must be non-empty';
      if (size > MAX_INPUT_BYTES) return `input bytes exceeds max-input-bytes (${MAX_INPUT_BYTES})`;
    }
    const hasBytes = p.bytes !== undefined;
    if ((hasText ? 1 : 0) + (hasKeys ? 1 : 0) + (hasBytes ? 1 : 0) > 1) {
      return 'input carries more than one of text/attachment_path, keys, bytes; at most one is allowed';
    }
    return null;
  }
  if (type === 'subscribe') {
    const subError = core.validateFrame(type, { ref: p.ref, rows: p.rows, cols: p.cols });
    if (subError) return subError;
    if (p.client_type !== undefined && (typeof p.client_type !== 'string' || !p.client_type)) {
      return 'subscribe client_type must be a non-empty string';
    }
    if (p.retain_pane_size !== undefined && typeof p.retain_pane_size !== 'boolean') {
      return 'subscribe retain_pane_size must be boolean';
    }
    return null;
  }
  if (type === 'presence_update') {
    if (typeof p.ref !== 'string' || !p.ref) return 'presence_update ref must be non-empty';
    if (typeof p.has_mobile !== 'boolean') return 'presence_update has_mobile must be boolean';
    if (p.mobile_count !== undefined && (!Number.isInteger(p.mobile_count) || p.mobile_count < 0)) {
      return 'presence_update mobile_count must be a non-negative integer';
    }
    if (p.desktop_count !== undefined && (!Number.isInteger(p.desktop_count) || p.desktop_count < 0)) {
      return 'presence_update desktop_count must be a non-negative integer';
    }
    return null;
  }
  if (type === 'auth_ack') {
    const authError = core.validateFrame(type, p);
    if (authError) return authError;
    if (p.agent_launchers !== undefined && !Array.isArray(p.agent_launchers)) {
      return 'auth_ack agent_launchers must be an array';
    }
    const seen = new Set();
    for (const launcher of p.agent_launchers || []) {
      if (!launcher || typeof launcher.provider !== 'string' || !launcher.provider
        || typeof launcher.display_name !== 'string' || !launcher.display_name
        || !['cli', 'tmux'].includes(launcher.naming)
        || typeof launcher.supports_bypass !== 'boolean') {
        return 'auth_ack agent launcher is invalid';
      }
      if (seen.has(launcher.provider)) return `auth_ack duplicate agent launcher: ${launcher.provider}`;
      seen.add(launcher.provider);
    }
    return null;
  }
  if (type === 'create_agent' || type === 'create_agent_result' || type === 'close_session' || type === 'close_session_result') {
    if (!Number.isInteger(p.req_id) || p.req_id < 1 || p.req_id > 0xffffffff) {
      return `${type} req_id must be in uint32 range`;
    }
  }
  if (type === 'create_agent') {
    if (typeof p.workspace !== 'string' || !p.workspace) return 'create_agent workspace must be non-empty';
    if (typeof p.anchor_ref !== 'string' || !p.anchor_ref) return 'create_agent anchor_ref must be non-empty';
    if (typeof p.provider !== 'string' || !p.provider) return 'create_agent provider must be non-empty';
    if (typeof p.name !== 'string' || !p.name.trim() || Array.from(p.name).length > 64
      || Array.from(p.name).some((ch) => /\p{Cc}/u.test(ch))) return 'create_agent name is invalid';
    if (typeof p.bypass !== 'boolean') return 'create_agent bypass must be boolean';
    return null;
  }
  if (type === 'create_agent_result') {
    if (p.ok === true) {
      if (typeof p.ref !== 'string' || !p.ref || typeof p.name !== 'string' || !p.name
        || !['cli', 'tmux'].includes(p.naming) || p.reason) return 'successful create_agent_result is invalid';
    } else if (p.ok === false) {
      if (!['invalid_field', 'target_not_found', 'provider_unavailable', 'unsupported_bypass', 'launch_failed'].includes(p.reason)) {
        return 'failed create_agent_result reason is invalid';
      }
    } else return 'create_agent_result ok must be boolean';
    return null;
  }
  if (type === 'close_session') {
    if (typeof p.ref !== 'string' || !p.ref) return 'close_session ref must be non-empty';
    return null;
  }
  if (type === 'close_session_result') {
    if (p.ok === true && p.reason) return 'accepted close_session_result must not carry a reason';
    if (p.ok === false && !p.reason) return 'failed close_session_result must carry a reason';
    if (typeof p.ok !== 'boolean') return 'close_session_result ok must be boolean';
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
    if (payload.bytes !== undefined) p.bytes = base64Encode(payload.bytes);
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
    if (p.bytes !== undefined) decoded.payload.bytes = p.bytes;
    return decoded;
  }
  return { type: root.type, payload: Object.fromEntries(fields[root.type].filter(k => p[k] !== undefined).map(k => [k, p[k]])) };
}
