/* Desktop/mobile onboarding payload (corral-core protocol.md §2.1). */

import { isLocalUrl } from './local.js';

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
  const out = [];
  if (validWsUrl(url)) out.push(url);
  for (const candidate of Array.isArray(candidates) ? candidates : []) {
    if (!validWsUrl(candidate) || out.includes(candidate)) continue;
    out.push(candidate);
  }
  return out;
}

/** Replace only the host while retaining the daemon's protocol, port, and path. */
export function wsUrlForHost(baseUrl, host) {
  if (!validWsUrl(baseUrl) || typeof host !== 'string') return null;
  const value = host.trim();
  if (!value) return null;
  if (/^wss?:\/\//i.test(value)) return validWsUrl(value) ? value : null;
  if (/[\s/?#]/.test(value)) return null;
  try {
    const endpoint = new URL(baseUrl);
    endpoint.hostname = value;
    return validWsUrl(endpoint.href) ? endpoint.href : null;
  } catch {
    return null;
  }
}

/** Candidates shown in the mobile QR must never point back to the scanner. */
export function reachableWsUrls(baseUrl, hosts) {
  const out = [];
  for (const host of Array.isArray(hosts) ? hosts : []) {
    const endpoint = wsUrlForHost(baseUrl, host);
    if (!endpoint || isLocalUrl(endpoint) || out.includes(endpoint)) continue;
    out.push(endpoint);
  }
  return out;
}

/**
 * Build the exact v1 wire shape. Token and ts_authkey are returned only when
 * the caller explicitly requests a QR payload; they are never part of UI
 * device projections or diagnostic output.
 *
 * Supports both legacy candidate-URL payloads and upgraded host_id payloads (Issue #207).
 */
export function buildPairingPayload({
  url = '',
  token,
  candidates = [],
  ts_authkey = '',
  host_id,
  port,
  name,
  ts_node_id,
} = {}) {
  const primary = typeof url === 'string' ? url.trim() : '';
  const hostId = typeof host_id === 'string' ? host_id.trim() : '';
  const hasValidUrl = validWsUrl(primary);
  const hasValidHostId = hostId.length > 0;

  if (!hasValidUrl && !hasValidHostId) {
    throw new TypeError('pairing payload requires a valid host_id or ws:// URL');
  }
  if (typeof token !== 'string' || token.length === 0) throw new TypeError('pairing token required');
  if (typeof ts_authkey !== 'string') throw new TypeError('ts_authkey must be a string');

  const payload = {
    v: PAIRING_VERSION,
    url: primary,
    token,
    ts_authkey,
    candidates: cleanCandidates(primary, candidates),
  };

  if (hostId) {
    payload.host_id = hostId;
  }
  if (port !== undefined && port !== null && Number.isInteger(Number(port)) && Number(port) > 0) {
    payload.port = Number(port);
  }
  if (typeof name === 'string' && name.trim().length > 0) {
    payload.name = name.trim();
  }
  if (typeof ts_node_id === 'string' && ts_node_id.trim().length > 0) {
    payload.ts_node_id = ts_node_id.trim();
  }

  return payload;
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
      host_id: input.host_id,
      port: input.port,
      name: input.name,
      ts_node_id: input.ts_node_id,
    });
  } catch {
    return null;
  }
}

export { validWsUrl };
