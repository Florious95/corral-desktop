/**
 * Safe RFC4122 v4 UUID generator.
 *
 * `crypto.randomUUID()` is restricted by W3C specification to secure contexts
 * (HTTPS or localhost). When accessing the desktop web client remotely over plain
 * HTTP (e.g. Tailscale IP or LAN IP), `crypto.randomUUID` is undefined.
 *
 * Fallback chain:
 * 1. `crypto.randomUUID()` when available (native secure context).
 * 2. `crypto.getRandomValues()` RFC4122 v4 generator (CSPRNG, available in non-secure contexts in modern browsers).
 * 3. Pseudo-random Math.random() RFC4122 v4 generator (last-resort deterministic fallback).
 *
 * @param {Object} [injectedCrypto] - Optional injectable crypto object for tests or non-global scopes.
 */
export function safeRandomUUID(injectedCrypto = (typeof globalThis !== 'undefined' ? globalThis.crypto : undefined)) {
  const cryptoObj = injectedCrypto;

  if (typeof cryptoObj?.randomUUID === 'function') {
    try {
      return cryptoObj.randomUUID();
    } catch {
      // In case native call fails or throws unexpectedly
    }
  }

  if (typeof cryptoObj?.getRandomValues === 'function') {
    try {
      const bytes = new Uint8Array(16);
      cryptoObj.getRandomValues(bytes);
      // Set version 4: bits 12-15 of time_hi_and_version to 0100
      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      // Set variant: bits 6-7 of clock_seq_hi_and_reserved to 10
      bytes[8] = (bytes[8] & 0x3f) | 0x80;

      const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
      return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
    } catch {
      // Fall through to Math.random
    }
  }

  // Fallback RFC4122 v4 implementation using Math.random
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}
