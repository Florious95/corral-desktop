/*
 * AgentMirror web client — protocol layer: JSON control frames.
 *
 * Wire contract (authoritative): docs/protocol.md v1.
 * Mirrors: server/internal/protocol/ (Go reference) and
 *          app/.../conn/FrameCodec.kt + Frames.kt (Kotlin reference).
 *
 * Rules that matter:
 *  - Unknown JSON fields inside envelope/payload are IGNORED (forward compat);
 *    an unknown "type" is an ERROR.
 *  - The "v" field must equal VERSION; otherwise the server closes with an
 *    error(unsupported_version) frame.
 *  - Invalid frames never cross the wire in either direction: encode validates
 *    before producing JSON, decode validates after parsing (same contract as
 *    Go MarshalFrame/UnmarshalFrame).
 *  - The payload NEVER carries terminal bytes; those travel in binary frames
 *    (see binary.js).
 */

export const VERSION = 1;
export const BINARY_VERSION = 1;
export const BINARY_MAGIC = 'RA';
export const MAX_REF_LEN = 255;
export const MAX_BINARY_PAYLOAD = 1 << 20; // 1 MiB

/** Closed set of control-frame type discriminators (docs/protocol.md §4.1). */
export const FRAME_TYPES = Object.freeze([
  'auth', 'auth_ack', 'list', 'listing', 'list_delta',
  'subscribe', 'unsubscribe', 'input', 'input_ack',
  'scrollback', 'resize', 'error',
  'overlay_subscribe', 'overlay_unsubscribe', 'overlay_frame',
]);

/** Closed set of AgentState values (§7.1) — server computes, client renders. */
export const AGENT_STATES = Object.freeze(['working', 'idle', 'blocked', 'done', 'unknown']);

/** Closed set of input.keys named keys (§4.2, R-1 shortcut bar). */
export const INPUT_KEYS = Object.freeze(['esc', 'ctrl_c', 'tab', 'up', 'down', 'left', 'right']);

/** Closed set of error frame codes (§7.2). */
export const ERROR_CODES = Object.freeze([
  'unauthorized', 'bad_frame', 'unsupported_version',
  'unsupported_type', 'session_not_found', 'internal',
]);

/** Closed set of input_ack failure reasons (§7.3). */
export const INPUT_FAIL_REASONS = Object.freeze([
  'session_not_found', 'not_subscribed', 'inject_failed', 'too_large', 'internal',
]);

/**
 * Local control/binary codec failure with a stable machine-readable code.
 * @contract
 * @pre code and message describe one local protocol failure
 * @post constructed error retains code/message and is named ProtocolError
 * @err none; construction does not validate the code set
 * @inv never carries pairing tokens or terminal payload bytes
 */
export class ProtocolError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
    this.name = 'ProtocolError';
  }
}

/**
 * Tests membership in the protocol AgentState closed set.
 * @contract
 * @pre none
 * @post returns true exactly for AGENT_STATES members
 * @err none
 * @inv does not mutate the closed set
 */
export function isKnownState(s) { return AGENT_STATES.includes(s); }

/**
 * Tests membership in the named input-key closed set.
 * @contract
 * @pre none
 * @post returns true exactly for INPUT_KEYS members
 * @err none
 * @inv does not mutate the closed set
 */
export function isKnownKey(k) { return INPUT_KEYS.includes(k); }

/**
 * Per-type required-field validation (mirror Go Validate). Returns null when
 * the frame is well-formed, else a human reason string. Enforced on both the
 * encode and the decode side so an invalid frame never crosses the wire.
 * @contract
 * @pre type and payload describe a candidate v1 control frame
 * @post returns null for a valid payload, otherwise a human-readable reason
 * @err none; validation failures are returned rather than thrown
 * @inv text and keys remain mutually exclusive and named keys stay closed-set
 */
export function validateFrame(type, p) {
  p = p || {};
  switch (type) {
    case 'auth':
      if (typeof p.token !== 'string' || p.token.length === 0) return 'auth token must be non-empty';
      return null;
    case 'auth_ack':
      if (p.ok === false && !p.reason) return 'rejected auth_ack must carry a reason';
      if (p.ok === true && p.reason) return 'accepted auth_ack must not carry a reason';
      return null;
    case 'list':
      if (!Number.isInteger(p.req_id) || p.req_id < 1) return 'list req_id must be >= 1';
      return null;
    case 'listing':
      if (!Number.isInteger(p.req_id) || p.req_id < 1) return 'listing req_id must be >= 1';
      if (!Number.isInteger(p.seq) || p.seq < 1) return 'listing seq must be >= 1';
      return null;
    case 'list_delta':
      if (!Number.isInteger(p.seq) || p.seq < 1) return 'list_delta seq must be >= 1';
      return null;
    case 'subscribe':
      if (typeof p.ref !== 'string' || p.ref.length === 0) return 'subscribe ref must be non-empty';
      if (p.rows < 1 || p.cols < 1) return 'subscribe rows/cols must be >= 1';
      return null;
    case 'unsubscribe':
      if (typeof p.ref !== 'string' || p.ref.length === 0) return 'unsubscribe ref must be non-empty';
      return null;
    case 'input': {
      if (!Number.isInteger(p.req_id) || p.req_id < 1) return 'input req_id must be >= 1';
      if (typeof p.ref !== 'string' || p.ref.length === 0) return 'input ref must be non-empty';
      const hasText = typeof p.text === 'string' && p.text.length > 0;
      const hasKeys = Array.isArray(p.keys) && p.keys.length > 0;
      // text and keys are mutually exclusive (§4.2): both present is a protocol error.
      if (hasText && hasKeys) return 'input carries both text and keys; at most one is allowed';
      if (hasKeys) {
        for (const k of p.keys) {
          if (!isKnownKey(k)) return `unknown input key: ${k}`;
        }
      }
      return null;
    }
    case 'input_ack':
      if (!Number.isInteger(p.req_id) || p.req_id < 1) return 'input_ack req_id must be >= 1';
      if (p.ok === false && !p.reason) return 'failed input_ack must carry a reason';
      if (p.ok === true && p.reason) return 'accepted input_ack must not carry a reason';
      return null;
    case 'scrollback':
      if (!Number.isInteger(p.req_id) || p.req_id < 1) return 'scrollback req_id must be >= 1';
      if (typeof p.ref !== 'string' || p.ref.length === 0) return 'scrollback ref must be non-empty';
      if (!Number.isInteger(p.count) || p.count < 1) return 'scrollback count must be >= 1';
      return null;
    case 'resize':
      if (typeof p.ref !== 'string' || p.ref.length === 0) return 'resize ref must be non-empty';
      if (p.rows < 1 || p.cols < 1) return 'resize rows/cols must be >= 1';
      return null;
    case 'error':
      if (typeof p.code !== 'string' || p.code.length === 0) return 'error code must be non-empty';
      return null;
    case 'overlay_subscribe':
      if (typeof p.socket !== 'string' || p.socket.length === 0) return 'overlay_subscribe socket must be non-empty';
      return null;
    case 'overlay_unsubscribe':
      return null;
    case 'overlay_frame':
      if (!Number.isInteger(p.seq) || p.seq < 1) return 'overlay_frame seq must be >= 1';
      return null;
    default:
      return `unknown frame type: ${type}`;
  }
}

/**
 * Build the payload object in canonical field order so encoded bytes match the
 * golden fixtures in server/internal/protocol/testdata (field order frozen).
 * Optional empty fields are omitted (Go omitempty semantics).
 */
function canonicalPayload(type, p) {
  p = p || {};
  switch (type) {
    case 'auth': return { token: p.token };
    case 'list': return { req_id: p.req_id };
    case 'subscribe': return { ref: p.ref, rows: p.rows, cols: p.cols };
    case 'unsubscribe': return { ref: p.ref };
    case 'input': {
      const o = { req_id: p.req_id, ref: p.ref };
      if (typeof p.text === 'string' && p.text.length > 0) o.text = p.text;
      if (Array.isArray(p.keys) && p.keys.length > 0) o.keys = p.keys;
      return o;
    }
    case 'scrollback': return { req_id: p.req_id, ref: p.ref, from_line: p.from_line, count: p.count };
    case 'resize': return { ref: p.ref, rows: p.rows, cols: p.cols };
    case 'overlay_subscribe': return { socket: p.socket };
    case 'overlay_unsubscribe': return {};
    case 'overlay_frame': {
      const o = { seq: p.seq, text: p.text || '' };
      if (p.rows) o.rows = p.rows;
      if (p.cols) o.cols = p.cols;
      return o;
    }
    default: return { ...p };
  }
}

/**
 * Encode one control frame as a JSON text message. Throws ProtocolError
 * (code 'invalid_field') when validation fails — an invalid frame never
 * crosses the wire.
 * @contract
 * @pre type is known and payload satisfies validateFrame
 * @post returns the canonical v1 JSON envelope with only documented payload fields
 * @err throws ProtocolError invalid_field when validation fails
 * @inv terminal bytes never enter the JSON control channel
 */
export function encodeControl(type, payload) {
  const err = validateFrame(type, payload);
  if (err) throw new ProtocolError('invalid_field', err);
  return JSON.stringify({ v: VERSION, type, payload: canonicalPayload(type, payload) });
}

/**
 * Decode one JSON text message into { type, payload }. Unknown JSON fields are
 * ignored; unknown type / bad version / missing required fields throw
 * ProtocolError with the appropriate machine code.
 * @contract
 * @pre text is one complete JSON control message
 * @post returns a validated type/payload pair with unknown fields removed
 * @err throws ProtocolError for malformed JSON, version/type errors, or invalid fields
 * @inv decoding never executes input or mutates connection state
 */
export function decodeControl(text) {
  let root;
  try {
    root = JSON.parse(text);
  } catch {
    throw new ProtocolError('bad_frame', 'malformed json');
  }
  if (root === null || typeof root !== 'object' || Array.isArray(root)) {
    throw new ProtocolError('bad_frame', 'envelope must be a JSON object');
  }
  if (root.v === undefined) throw new ProtocolError('missing_version', 'missing protocol version');
  if (!Number.isInteger(root.v)) throw new ProtocolError('bad_frame', 'protocol version must be an integer');
  if (root.v !== VERSION) throw new ProtocolError('unsupported_version', `unsupported protocol version: ${root.v}`);

  const type = root.type;
  if (typeof type !== 'string' || type.length === 0) throw new ProtocolError('invalid_field', 'empty frame type');
  if (!FRAME_TYPES.includes(type)) throw new ProtocolError('unsupported_type', `unknown frame type: ${type}`);

  const payload = root.payload === undefined || root.payload === null ? {} : root.payload;
  if (typeof payload !== 'object' || Array.isArray(payload)) {
    throw new ProtocolError('bad_frame', 'payload must be an object');
  }
  const err = validateFrame(type, payload);
  if (err) throw new ProtocolError('invalid_field', err);
  // Forward compatibility (§4.1): unknown fields inside the envelope/payload
  // are IGNORED — never surfaced, never acted on. Select only the documented
  // fields so future additions cannot leak into the model.
  return { type, payload: pickKnown(type, payload) };
}

/** Field whitelist per frame type — only documented fields cross the model. */
const KNOWN_FIELDS = Object.freeze({
  auth: ['token'],
  auth_ack: ['ok', 'reason'],
  list: ['req_id'],
  listing: ['req_id', 'seq', 'workspaces'],
  list_delta: ['seq', 'added_sessions', 'removed_refs', 'changed_sessions', 'changed_workspaces'],
  subscribe: ['ref', 'rows', 'cols'],
  unsubscribe: ['ref'],
  input: ['req_id', 'ref', 'text', 'keys'],
  input_ack: ['req_id', 'ok', 'reason'],
  scrollback: ['req_id', 'ref', 'from_line', 'count'],
  resize: ['ref', 'rows', 'cols'],
  error: ['code', 'reason'],
  overlay_subscribe: ['socket'],
  overlay_unsubscribe: [],
  overlay_frame: ['seq', 'text', 'rows', 'cols'],
});

function pickKnown(type, payload) {
  const allowed = KNOWN_FIELDS[type];
  if (!allowed) return { ...payload };
  const out = {};
  for (const k of allowed) {
    if (payload[k] !== undefined) out[k] = payload[k];
  }
  return out;
}
