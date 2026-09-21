export const DEFAULT_LOCAL_URL = 'ws://localhost:9900/ws';
export const DEFAULT_LOCAL_DEVICE = Object.freeze({
  id: 'local',
  name: 'Local',
  url: DEFAULT_LOCAL_URL,
  token: '',
});

export function isLocalUrl(url) {
  try {
    const hostname = new URL(url).hostname.toLowerCase();
    return hostname === 'localhost' || hostname === '127.0.0.1'
      || hostname === '::1' || hostname === '[::1]';
  } catch {
    return false;
  }
}
