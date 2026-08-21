/*
 * AgentMirror web client — protocol layer: binary stream frames.
 *
 * Wire layout (docs/protocol.md §6, server/internal/protocol/binary.go):
 *
 *   +0  magic      "R" "A"
 *   +2  version    1 byte (= VERSION)
 *   +3  kind       1 byte (1=snapshot, 2=delta, 3=scrollback)
 *   +4  reflen     1 byte session-ref byte length (0..255, non-zero)
 *   +5  ref        reflen bytes, UTF-8
 *   +5+reflen      payload (kind-specific)
 *
 * KindScrollback carries a 12-byte metadata header describing the ACTUAL line
 * range the server converged to (it clamps the request): req_id (4, big-endian
 * unsigned), from_line (4, big-endian signed), line_count (4, big-endian
 * unsigned), then the ANSI bytes. Snapshot/Delta carry no header.
 *
 * One binary WebSocket message = one frame. Raw ANSI/VT bytes, never JSON.
 * Decoding is strict (bad magic/version, unknown kind, truncation, empty ref
 * all throw) so a malformed mirror stream surfaces instead of corrupting the
 * terminal grid — same stance as Go DecodeBinary and Kotlin BinaryFrameCodec.
 */

import {
  BINARY_MAGIC, BINARY_VERSION, MAX_REF_LEN, MAX_BINARY_PAYLOAD, ProtocolError,
} from './protocol.js';

export const BINARY_KIND = Object.freeze({
  SNAPSHOT: 1, // full screen, sent first on subscribe / after resize
  DELTA: 2,    // incremental terminal bytes (pipe-pane)
  SCROLLBACK: 3, // one history page, answering a scrollback request
});

const HEADER_LEN = 5;
const SCROLLBACK_HEADER_LEN = 12;

const te = new TextEncoder();
const td = new TextDecoder('utf-8');

/**
 * Decode one binary WebSocket message into a BinaryFrame object:
 * { kind, ref, reqId, fromLine, lineCount, data } where data is a Uint8Array
 * of raw terminal bytes. reqId/fromLine/lineCount are meaningful only for
 * kind=3 (else 0).
 * @contract
 * @pre bytes contains one complete binary WebSocket message
 * @post returns a validated frame whose data is the unescaped terminal payload
 * @err throws ProtocolError for truncation, bad magic/version/kind/ref, or invalid metadata
 * @inv snapshot/delta expose zero scrollback metadata; source bytes are not mutated
 */
export function decodeBinary(bytes) {
  const u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  if (u8.length < HEADER_LEN) {
    throw new ProtocolError('truncated', `frame shorter than 5-byte header: ${u8.length}`);
  }
  if (u8[0] !== 0x52 || u8[1] !== 0x41) { // "R" "A"
    throw new ProtocolError('bad_magic', `bad magic: ${u8[0]} ${u8[1]}`);
  }
  if (u8[2] !== BINARY_VERSION) {
    throw new ProtocolError('unsupported_version', `binary version ${u8[2]}, want ${BINARY_VERSION}`);
  }
  const kind = u8[3];
  if (kind !== BINARY_KIND.SNAPSHOT && kind !== BINARY_KIND.DELTA && kind !== BINARY_KIND.SCROLLBACK) {
    throw new ProtocolError('unknown_kind', `unknown kind: ${kind}`);
  }
  const reflen = u8[4];
  if (reflen === 0) throw new ProtocolError('invalid_ref', 'empty ref');
  if (u8.length < HEADER_LEN + reflen) {
    throw new ProtocolError('truncated', `ref of ${reflen} bytes but frame has ${u8.length}`);
  }
  const ref = td.decode(u8.subarray(HEADER_LEN, HEADER_LEN + reflen));
  const body = u8.subarray(HEADER_LEN + reflen);

  if (kind === BINARY_KIND.SCROLLBACK) {
    if (body.length < SCROLLBACK_HEADER_LEN) {
      throw new ProtocolError('truncated', 'scrollback metadata header');
    }
    const dv = new DataView(body.buffer, body.byteOffset, body.byteLength);
    const reqId = dv.getUint32(0);
    const fromLine = dv.getInt32(4);
    const lineCount = dv.getUint32(8);
    if (reqId === 0) throw new ProtocolError('invalid_field', 'scrollback req_id must be >= 1');
    if (lineCount === 0) throw new ProtocolError('invalid_field', 'scrollback line_count must be >= 1');
    return {
      kind, ref, reqId, fromLine, lineCount, data: body.subarray(SCROLLBACK_HEADER_LEN),
    };
  }
  return { kind, ref, reqId: 0, fromLine: 0, lineCount: 0, data: body };
}

/**
 * Encode one BinaryFrame into a complete binary WebSocket message (Uint8Array).
 * Encode-side bounds mirror Go validateBinaryPayload: non-empty ref within 255
 * bytes, payload within 1 MiB, and a scrollback reply needs reqId/lineCount >= 1.
 * @contract
 * @pre kind is known, ref is non-empty, data fits the protocol bounds
 * @post returns one complete v1 binary message with raw payload bytes preserved
 * @err throws ProtocolError for invalid kind/ref/bounds or scrollback metadata
 * @inv input data and ref are not mutated
 */
export function encodeBinary({ kind, ref, data, reqId = 0, fromLine = 0, lineCount = 0 }) {
  const u8 = data instanceof Uint8Array ? data : new Uint8Array(data || []);
  if (kind !== BINARY_KIND.SNAPSHOT && kind !== BINARY_KIND.DELTA && kind !== BINARY_KIND.SCROLLBACK) {
    throw new ProtocolError('unknown_kind', `unknown kind: ${kind}`);
  }
  if (typeof ref !== 'string' || ref.length === 0) throw new ProtocolError('invalid_ref', 'empty ref');
  const refBytes = te.encode(ref);
  if (refBytes.length > MAX_REF_LEN) throw new ProtocolError('ref_too_long', `ref exceeds 255 bytes`);
  if (u8.length > MAX_BINARY_PAYLOAD) throw new ProtocolError('invalid_field', `payload exceeds 1 MiB`);
  if (kind === BINARY_KIND.SCROLLBACK) {
    if (!Number.isInteger(reqId) || reqId < 1) throw new ProtocolError('invalid_field', 'scrollback req_id must be >= 1');
    if (!Number.isInteger(lineCount) || lineCount < 1) throw new ProtocolError('invalid_field', 'scrollback line_count must be >= 1');
  }

  const extra = kind === BINARY_KIND.SCROLLBACK ? SCROLLBACK_HEADER_LEN : 0;
  const out = new Uint8Array(HEADER_LEN + refBytes.length + u8.length + extra);
  out[0] = 0x52; out[1] = 0x41; out[2] = BINARY_VERSION; out[3] = kind; out[4] = refBytes.length;
  out.set(refBytes, HEADER_LEN);

  let off = HEADER_LEN + refBytes.length;
  if (kind === BINARY_KIND.SCROLLBACK) {
    const dv = new DataView(out.buffer, out.byteOffset, out.byteLength);
    dv.setUint32(off, reqId >>> 0);
    dv.setInt32(off + 4, fromLine | 0);
    dv.setUint32(off + 8, lineCount >>> 0);
    off += SCROLLBACK_HEADER_LEN;
  }
  out.set(u8, off);
  return out;
}
