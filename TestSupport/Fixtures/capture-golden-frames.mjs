import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync, renameSync, writeFileSync } from 'node:fs';
import { setTimeout as delay } from 'node:timers/promises';
import { resolve } from 'node:path';

const root = new URL('.', import.meta.url).pathname.replace(/\/$/, '');
const home = '/tmp/corral-gw-test-home';
const token = readFileSync(`${home}/test-token`, 'utf8').trim();
const socket = `${home}/tmux-${process.getuid()}/test-corral-gw-9919`;
const endpoint = 'ws://127.0.0.1:9919/ws';
const daemonPath = `${root}/bin/agentmirrord`;
const daemonHash = createHash('sha256').update(readFileSync(daemonPath)).digest('hex');
const tmuxShimHash = createHash('sha256').update(readFileSync(`${root}/runtime/nodeprobe/tmux`)).digest('hex');
const ws = new WebSocket(endpoint);
ws.binaryType = 'arraybuffer';
const queue = [];
const waiters = [];
let closed = false;
ws.addEventListener('message', event => {
  const raw = typeof event.data === 'string' ? Buffer.from(event.data, 'utf8') : Buffer.from(event.data);
  const item = { binary: typeof event.data !== 'string', raw };
  const waiter = waiters.shift();
  if (waiter) waiter.resolve(item); else queue.push(item);
});
ws.addEventListener('close', () => { closed = true; });

function nextMessage(timeoutMs = 10000) {
  if (queue.length) return Promise.resolve(queue.shift());
  if (closed) return Promise.reject(new Error('WebSocket closed before required frame arrived'));
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      const i = waiters.indexOf(waiter);
      if (i >= 0) waiters.splice(i, 1);
      reject(new Error('timed out waiting for daemon frame'));
    }, timeoutMs);
    const waiter = {
      resolve: item => { clearTimeout(timer); resolve(item); },
      reject: error => { clearTimeout(timer); reject(error); },
    };
    waiters.push(waiter);
  });
}
async function nextJson(predicate, timeoutMs = 10000) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    const msg = await nextMessage(end - Date.now());
    if (msg.binary) continue;
    let value;
    try { value = JSON.parse(msg.raw.toString('utf8')); } catch { continue; }
    if (predicate(value)) return { msg, value };
    if (value.type === 'error') throw new Error(`daemon protocol error: ${value.payload?.reason ?? 'unspecified'}`);
  }
  throw new Error('timed out waiting for matching control frame');
}
function rawFrame(msg, type, extra = {}) {
  if (msg.raw.includes(Buffer.from(token, 'utf8'))) throw new Error('test token leaked into a captured server frame');
  return { semantic_name: type, raw_utf8: msg.raw.toString('utf8'), raw_hex: msg.raw.toString('hex'), raw_base64: msg.raw.toString('base64'), byte_length: msg.raw.length, ...extra };
}
function rawBinary(msg, kind, ref) {
  const b = msg.raw;
  if (msg.raw.includes(Buffer.from(token, 'utf8'))) throw new Error('test token leaked into a captured server frame');
  if (b.length < 5 || b[0] !== 0x52 || b[1] !== 0x41 || b[2] !== 1 || b[3] !== kind) {
    throw new Error(`unexpected RA v1 binary header for kind ${kind}: ${b.subarray(0, 8).toString('hex')}`);
  }
  const refLength = b[4];
  const frameRef = b.subarray(5, 5 + refLength).toString('utf8');
  if (frameRef !== ref) throw new Error('binary frame ref does not match the subscribed fixture pane');
  return { semantic_name: kind === 1 ? 'SNAPSHOT' : 'DELTA', opcode: 'binary', version: b[2], kind: b[3], ref_length: refLength, ref: frameRef, raw_hex: b.toString('hex'), raw_base64: b.toString('base64'), byte_length: b.length };
}

try {
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve, { once: true });
    ws.addEventListener('error', () => reject(new Error('cannot connect to the isolated 9919 WebSocket')), { once: true });
  });
  ws.send(JSON.stringify({ v: 1, type: 'auth', payload: { token } }));
  const auth = await nextJson(value => value.type === 'auth_ack');
  if (auth.value.payload?.ok !== true) throw new Error('isolated daemon rejected the fixture token');
  const frames = { auth_ok: rawFrame(auth.msg, 'auth_ack') };

  let listing;
  let listFrame;
  for (let reqId = 1; reqId <= 6; reqId++) {
    ws.send(JSON.stringify({ v: 1, type: 'list', payload: { req_id: reqId } }));
    const received = await nextJson(value => value.type === 'listing' && value.payload?.req_id === reqId, 8000);
    const sessions = (received.value.payload?.workspaces ?? []).flatMap(workspace => workspace.sessions ?? []);
    if (sessions.length >= 6) {
      listing = received.value;
      listFrame = received.msg;
      break;
    }
    await delay(700);
  }
  if (!listing) throw new Error('real session listing did not include all six isolated fixture panes');
  const paneId = execFileSync('/opt/homebrew/bin/tmux', ['-S', socket, 'list-panes', '-t', 'streaming-output', '-F', '#{pane_id}'], {
    encoding: 'utf8', timeout: 5000,
    env: { PATH: '/usr/bin:/bin:/opt/homebrew/bin', HOME: `${home}/home`, TMPDIR: `${home}/tmp`, TMUX_TMPDIR: home },
  }).trim();
  const streamRef = `${socket}\u001f${paneId}`;
  const stream = listing.payload.workspaces.flatMap(workspace => workspace.sessions ?? []).find(session => session.ref === streamRef);
  if (!stream?.ref || !stream.ref.startsWith(`${socket}\u001f`)) throw new Error('stream fixture ref is not rooted at the isolated tmux socket');
  frames.session_list = rawFrame(listFrame, 'listing', { fixture_session_count: listing.payload.workspaces.reduce((n, workspace) => n + (workspace.sessions?.length ?? 0), 0) });

  ws.send(JSON.stringify({ v: 1, type: 'subscribe', payload: { ref: stream.ref, rows: 24, cols: 80 } }));
  let snapshot;
  let delta;
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline && (!snapshot || !delta)) {
    const msg = await nextMessage(deadline - Date.now());
    if (!msg.binary) {
      const control = JSON.parse(msg.raw.toString('utf8'));
      if (control.type === 'error') throw new Error(`subscribe failed: ${control.payload?.reason ?? 'unspecified'}`);
      continue;
    }
    if (msg.raw.length < 5 || msg.raw[0] !== 0x52 || msg.raw[1] !== 0x41 || msg.raw[2] !== 1) continue;
    if (msg.raw[3] === 1 && !snapshot) snapshot = rawBinary(msg, 1, stream.ref);
    if (msg.raw[3] === 2 && snapshot && !delta) delta = rawBinary(msg, 2, stream.ref);
  }
  if (!snapshot || !delta) throw new Error('real daemon did not deliver both binary SNAPSHOT and DELTA frames');
  frames.snapshot = snapshot;
  frames.delta = delta;
  ws.send(JSON.stringify({ v: 1, type: 'unsubscribe', payload: { ref: stream.ref } }));

  const build = execFileSync('go', ['version', '-m', daemonPath], { encoding: 'utf8' });
  const output = {
    schema_version: 1,
    protocol_version: 1,
    captured_at_utc: new Date().toISOString(),
    endpoint,
    producer: {
      daemon_binary_sha256: daemonHash,
      nodeprobe_tmux_query_shim_sha256: tmuxShimHash,
      go_vcs_revision: build.match(/\bvcs\.revision=([^\s]+)/)?.[1] ?? null,
      go_vcs_time: build.match(/\bvcs\.time=([^\s]+)/)?.[1] ?? null,
      go_vcs_modified: build.match(/\bvcs\.modified=([^\s]+)/)?.[1] ?? null,
      frozen_source_copy_head: 'a472d4437885060bc0eaf1838c9149e5242948cb',
    },
    actual_wire_names: { auth_ok: 'auth_ack', session_list: 'listing', snapshot: 'RA v1 kind 1', delta: 'RA v1 kind 2' },
    fixtures: { tmux_socket: socket, selected_session: 'streaming-output', pane_id: paneId, session_ref: stream.ref },
    frames,
    credential_policy: 'server-to-client samples only; auth token and auth request are excluded',
  };
  const destination = resolve(root, 'golden-frames.json');
  const temporary = `${destination}.tmp-${process.pid}`;
  writeFileSync(temporary, JSON.stringify(output, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
  renameSync(temporary, destination);
  console.log(`Captured real auth_ack/listing/SNAPSHOT/DELTA frames to ${destination} (${frames.snapshot.byte_length} / ${frames.delta.byte_length} binary bytes).`);
} catch (error) {
  console.error(`Golden capture failed: ${error.message}`);
  process.exitCode = 1;
} finally {
  try { ws.close(1000, 'fixture capture complete'); } catch {}
}
