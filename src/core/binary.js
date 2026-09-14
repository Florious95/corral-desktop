/* Desktop binary-frame guard around the shared corral-core codec. */

import {
  BINARY_KIND,
  decodeBinary as decodeCoreBinary,
  encodeBinary,
} from '../../deps/corral-core/web/js/binary.js';
import { MAX_BINARY_PAYLOAD, ProtocolError } from '../../deps/corral-core/web/js/protocol.js';

export { BINARY_KIND, encodeBinary, MAX_BINARY_PAYLOAD };

/**
 * Decode one binary frame and reject terminal payloads over the shared 1 MiB
 * wire bound. The core decoder owns framing/metadata validation; this desktop
 * guard owns the inbound payload limit until the bound lands in core.
 */
export function decodeBinary(bytes) {
  const frame = decodeCoreBinary(bytes);
  if (frame.data.byteLength > MAX_BINARY_PAYLOAD) {
    throw new ProtocolError('invalid_field', 'payload exceeds 1 MiB');
  }
  return frame;
}
