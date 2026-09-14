/* Desktop/mobile onboarding payload (corral-core protocol.md §2.1). */

export const PAIRING_VERSION = 1;
const WS_RE = /^wss?:\/\/[^\s]+$/i;

function validWsUrl(value) {
  if (typeof value !== 'string' || !WS_RE.test(value)) return false;
  try {
    const parsed = new URL(value);
    return (parsed.protocol === 'ws:' || parsed.protocol === 'wss:') && parsed.hostname.length > 0;
  } catch {
    return false;
  }
}

function cleanCandidates(url, candidates) {
  const out = [url];
  for (const candidate of Array.isArray(candidates) ? candidates : []) {
    if (!validWsUrl(candidate) || out.includes(candidate)) continue;
    out.push(candidate);
  }
  return out;
}

/**
 * Build the exact v1 wire shape. Token and ts_authkey are returned only when
 * the caller explicitly requests a QR payload; they are never part of UI
 * device projections or diagnostic output.
 */
export function buildPairingPayload({ url, token, candidates = [], ts_authkey = '' } = {}) {
  const primary = typeof url === 'string' ? url.trim() : url;
  if (!validWsUrl(primary)) throw new TypeError('pairing url must be a ws:// or wss:// URL');
  if (typeof token !== 'string' || token.length === 0) throw new TypeError('pairing token required');
  if (typeof ts_authkey !== 'string') throw new TypeError('ts_authkey must be a string');
  return {
    v: PAIRING_VERSION,
    url: primary,
    token,
    ts_authkey,
    candidates: cleanCandidates(primary, candidates),
  };
}

/** Return one-line JSON suitable for the QR byte payload. */
export function serializePairingPayload(payload) {
  return JSON.stringify(buildPairingPayload(payload));
}

/**
 * Parse a QR payload while tolerating malformed optional candidates as the
 * mobile protocol requires. Unknown fields are deliberately ignored.
 */
export function parsePairingPayload(value) {
  let input = value;
  if (typeof value === 'string') {
    try { input = JSON.parse(value); } catch { return null; }
  }
  if (!input || input.v !== PAIRING_VERSION) return null;
  try {
    return buildPairingPayload({
      url: input.url,
      token: input.token,
      ts_authkey: input.ts_authkey === undefined ? '' : input.ts_authkey,
      candidates: input.candidates,
    });
  } catch {
    return null;
  }
}

export { validWsUrl };
