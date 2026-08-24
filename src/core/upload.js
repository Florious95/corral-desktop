/* Shared image upload boundary. Web tests may inject fetch/invoke; the .app
 * path uses the Tauri command so the WebView never opens the daemon socket. */

export class UploadError extends Error {
  constructor(code, message, status = 0) {
    super(message);
    this.name = 'UploadError';
    this.code = code;
    this.status = status;
  }
}

export function wsToHttpOrigin(wsUrl) {
  let u;
  try { u = new URL(wsUrl); } catch { throw new UploadError('invalid_url', '上传地址无效'); }
  if (u.protocol !== 'ws:' && u.protocol !== 'wss:') {
    throw new UploadError('invalid_url', '上传地址必须是 WebSocket');
  }
  u.protocol = u.protocol === 'wss:' ? 'https:' : 'http:';
  u.pathname = '';
  u.search = '';
  u.hash = '';
  return u.toString().replace(/\/$/, '');
}

function filenameOf(name) {
  const safe = String(name || 'image').split(/[\\/]/).pop().replace(/[\r\n"']/g, '_');
  return safe || 'image';
}

function asBytes(bytes) {
  if (bytes instanceof Uint8Array) return bytes;
  if (bytes instanceof ArrayBuffer) return new Uint8Array(bytes);
  if (Array.isArray(bytes)) return Uint8Array.from(bytes);
  throw new UploadError('invalid_file', '图片字节无效');
}

function checkPath(path) {
  if (typeof path !== 'string' || path.length === 0 || !path.startsWith('/')) {
    throw new UploadError('invalid_response', '上传响应缺少绝对路径');
  }
  return path;
}

function endpointFor(url) { return `${wsToHttpOrigin(url)}/upload`; }

function classifyStatus(status) {
  return status === 401 ? 'unauthorized' : 'http_status';
}

/**
 * Upload one image. Native invoke is selected by the Tauri runtime; injected
 * functions make the same branch directly testable without a desktop app.
 */
export async function uploadImage({ url, token, name, mime, bytes, nativeInvoke, fetchImpl } = {}) {
  const data = asBytes(bytes);
  if (data.length === 0) throw new UploadError('invalid_file', '图片为空');
  const endpoint = endpointFor(url);
  const filename = filenameOf(name);
  const contentType = typeof mime === 'string' && mime.startsWith('image/') ? mime : 'application/octet-stream';

  let invokeFn = nativeInvoke;
  if (!invokeFn && typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window) {
    ({ invoke: invokeFn } = await import('@tauri-apps/api/core'));
  }
  if (invokeFn) {
    try {
      const result = await invokeFn('upload_http', {
        url: endpoint,
        token,
        filename,
        mime: contentType,
        bytes: Array.from(data),
      });
      return checkPath(typeof result === 'string' ? result : result?.path);
    } catch (e) {
      if (e instanceof UploadError) throw e;
      const message = String(e?.message || e || '上传失败');
      if (/401|unauthorized|token/i.test(message)) throw new UploadError('unauthorized', '上传认证失败', 401);
      if (/connect|network|timeout|refused|unreachable/i.test(message)) {
        throw new UploadError('unreachable', '无法连接 daemon');
      }
      throw new UploadError('upload_failed', '上传失败');
    }
  }

  const fetcher = fetchImpl || globalThis.fetch;
  if (typeof fetcher !== 'function') throw new UploadError('unreachable', '无法连接 daemon');
  const body = new FormData();
  body.append('file', new Blob([data], { type: contentType }), filename);
  let response;
  try {
    response = await fetcher(endpoint, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}` },
      body,
    });
  } catch {
    throw new UploadError('unreachable', '无法连接 daemon');
  }
  if (!response.ok) throw new UploadError(classifyStatus(response.status), `上传失败（HTTP ${response.status}）`, response.status);
  let payload;
  try { payload = await response.json(); } catch { throw new UploadError('invalid_response', '上传响应无法解析', response.status); }
  return checkPath(payload?.path);
}

export async function fileToAttachment(file) {
  if (!file || typeof file.arrayBuffer !== 'function') throw new UploadError('invalid_file', '图片文件无效');
  return {
    name: file.name || 'image',
    mime: file.type || 'application/octet-stream',
    bytes: new Uint8Array(await file.arrayBuffer()),
  };
}
