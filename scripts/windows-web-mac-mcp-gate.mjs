#!/usr/bin/env node
/**
 * Windows 5090 WSL + Mac Chrome MCP lifecycle gate.
 *
 * This script owns the destructive half of the test only: exact tmux probing,
 * authenticated WS protocol observation, and the 1-second physical-termination
 * assertion. Chrome DevTools MCP performs the UI action and supplies --ref and
 * --session after the browser receipt identifies the target.
 *
 * Safety:
 * - token is read only from AGENTMIRROR_TOKEN and is never logged;
 * - session names must use the am-e2e- prefix unless --allow-existing is set;
 * - close mode requires --confirm-destructive;
 * - cleanup probes/terminates only the exact session passed by the caller.
 */

import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import process from 'node:process';
import { decodeControl, encodeControl } from '../src/core/protocol.js';

const DEFAULT_HOST = process.env.WINDOWS_SSH_HOST || '5090';
const DEFAULT_DISTRO = process.env.WSL_DISTRO || 'Ubuntu-24.04';
const DEFAULT_TIMEOUT_MS = 2000;
const POLL_MS = 100;
const SAFE_SESSION = /^am-e2e-[A-Za-z0-9._:-]{1,80}$/;
const ANY_SESSION = /^[A-Za-z0-9._:-]{1,96}$/;

function fail(message, details = {}) {
  const error = new Error(message);
  error.details = details;
  throw error;
}

function parseArgs(argv) {
  const out = { mode: 'preflight', host: DEFAULT_HOST, distro: DEFAULT_DISTRO, timeoutMs: DEFAULT_TIMEOUT_MS };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--mode') out.mode = argv[++i];
    else if (a === '--host') out.host = argv[++i];
    else if (a === '--distro') out.distro = argv[++i];
    else if (a === '--session') out.session = argv[++i];
    else if (a === '--ref') out.ref = argv[++i];
    else if (a === '--ws-url') out.wsUrl = argv[++i];
    else if (a === '--timeout-ms') out.timeoutMs = Number(argv[++i]);
    else if (a === '--browser-receipt') out.browserReceipt = argv[++i];
    else if (a === '--allow-existing') out.allowExisting = true;
    else if (a === '--confirm-destructive') out.confirmDestructive = true;
    else if (a === '--help' || a === '-h') out.help = true;
    else fail(`unknown argument: ${a}`);
  }
  return out;
}

function usage() {
  return `Usage:
  windows-web-mac-mcp-gate.mjs --mode preflight --host 5090 --distro Ubuntu-24.04 --session am-e2e-...
  windows-web-mac-mcp-gate.mjs --mode close --host 5090 --distro Ubuntu-24.04 \
    --ws-url ws://100.67.119.102:9900/ws --session am-e2e-... --ref <ref> \
    --confirm-destructive [--browser-receipt receipt.json]

Required environment for --mode close: AGENTMIRROR_TOKEN (never printed).
The browser action is intentionally external: use Chrome DevTools MCP to click
Close, capture the outbound close_session frame, then run this gate with the
same exact session/ref pair.`;
}

function validateConfig(args) {
  if (!args.host || !args.distro) fail('host and distro are required');
  if (!Number.isInteger(args.timeoutMs) || args.timeoutMs < 100 || args.timeoutMs > 10000) {
    fail('timeout-ms must be an integer between 100 and 10000');
  }
  if (args.session !== undefined) {
    if (!ANY_SESSION.test(args.session) || args.session.startsWith('-')) fail('invalid tmux session name');
    if (!args.allowExisting && !SAFE_SESSION.test(args.session)) {
      fail('session must use am-e2e- prefix; pass --allow-existing only for a disposable pre-existing fixture');
    }
  }
  if (args.mode === 'close') {
    if (!args.confirmDestructive) fail('close mode requires --confirm-destructive');
    if (!args.session || !args.ref || !args.wsUrl) fail('close mode requires --session, --ref, and --ws-url');
    if (!process.env.AGENTMIRROR_TOKEN) fail('AGENTMIRROR_TOKEN is required but was not provided');
  }
}

function run(command, args, { timeoutMs = 10000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => {
      child.kill('SIGTERM');
      reject(new Error(`${command} timed out after ${timeoutMs}ms`));
    }, timeoutMs);
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.once('error', (error) => { clearTimeout(timer); reject(error); });
    child.once('close', (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal, stdout, stderr });
    });
  });
}

function psEncodedCommand(text) {
  return Buffer.from(text, 'utf16le').toString('base64');
}

/** Execute a fixed WSL probe through Windows OpenSSH without shell interpolation. */
async function runWsl(host, distro, script) {
  const script64 = Buffer.from(script, 'utf8').toString('base64');
  const ps = [
    `$b='${script64}'`,
    '$s=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b))',
    `$d='${String(distro).replaceAll("'", "''")}'`,
    '& wsl.exe -d $d -e bash -lc $s',
    'exit $LASTEXITCODE',
  ].join(';');
  const result = await run('ssh', ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', host,
    'powershell.exe', '-NoProfile', '-NonInteractive', '-EncodedCommand', psEncodedCommand(ps)], { timeoutMs: 15000 });
  return result;
}

function shellLiteral(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

function parseJsonLines(text) {
  return text.split(/\r?\n/).map((line) => line.trim()).filter(Boolean).flatMap((line) => {
    try { return [JSON.parse(line)]; } catch { return []; }
  });
}

async function probeTmux(args) {
  if (!args.session) fail('preflight requires --session');
  const session = shellLiteral(args.session);
  const script = [
    'set +e',
    `if tmux has-session -t ${session} 2>/dev/null; then`,
    `  printf '%s\\n' '{"exists":true}'`,
    `  tmux list-panes -t ${session} -F '#{pane_id}\\t#{pane_pid}\\t#{pane_current_command}' 2>/dev/null | while IFS=$(printf '\\t') read -r pane pid command; do`,
    `    printf '{"pane":"%s","pid":%s,"command":"%s"}\\n' "$pane" "$pid" "$command"`,
    '  done',
    'else',
    `  printf '%s\\n' '{"exists":false}'`,
    'fi',
  ].join('\n');
  const result = await runWsl(args.host, args.distro, script);
  const rows = parseJsonLines(result.stdout);
  const state = rows.find((row) => Object.hasOwn(row, 'exists')) || { exists: false };
  return { ...state, panes: rows.filter((row) => row.pane), exitCode: result.code, stderr: result.stderr.trim() };
}

async function waitForGone(args) {
  const deadline = Date.now() + args.timeoutMs;
  const samples = [];
  while (Date.now() <= deadline) {
    const sample = await probeTmux(args);
    samples.push({ atMs: Date.now(), exists: sample.exists, paneCount: sample.panes.length });
    if (!sample.exists) return { gone: true, elapsedMs: samples.at(-1).atMs - (samples[0]?.atMs || Date.now()), samples };
    await new Promise((resolve) => setTimeout(resolve, POLL_MS));
  }
  return { gone: false, samples };
}

function waitForMessage(ws, predicate, timeoutMs) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      ws.removeEventListener('message', onMessage);
      reject(new Error(`WS message timeout after ${timeoutMs}ms`));
    }, timeoutMs);
    const onMessage = (event) => {
      let frame;
      try { frame = decodeControl(String(event.data)); } catch { return; }
      if (!predicate(frame)) return;
      clearTimeout(timer);
      ws.removeEventListener('message', onMessage);
      resolve(frame);
    };
    ws.addEventListener('message', onMessage);
  });
}

function sanitizedFrame(frame) {
  if (!frame || typeof frame !== 'object') return { type: 'invalid' };
  const payload = { ...(frame.payload || {}) };
  delete payload.token;
  if (payload.bytes) payload.bytes = `<${String(payload.bytes).length} base64 chars>`;
  return { type: frame.type, payload };
}

async function protocolClose(args) {
  const token = process.env.AGENTMIRROR_TOKEN;
  const ws = new WebSocket(args.wsUrl);
  const outbound = [];
  const inbound = [];
  ws.addEventListener('message', (event) => {
    try { inbound.push(sanitizedFrame(decodeControl(String(event.data)))); } catch { /* non-control/binary */ }
  });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('WS open timeout')), args.timeoutMs);
    ws.addEventListener('open', () => { clearTimeout(timer); resolve(); }, { once: true });
    ws.addEventListener('error', () => { clearTimeout(timer); reject(new Error('WS connection error')); }, { once: true });
  });
  const send = (type, payload) => {
    const wire = encodeControl(type, payload);
    outbound.push(sanitizedFrame({ type, payload }));
    ws.send(wire);
  };

  send('auth', { token });
  const auth = await waitForMessage(ws, (frame) => frame.type === 'auth_ack', args.timeoutMs);
  if (auth.payload?.ok !== true) fail('auth_ack was not accepted', { auth: sanitizedFrame(auth) });

  const listReq = 1;
  send('list', { req_id: listReq });
  const listing = await waitForMessage(ws, (frame) => frame.type === 'listing' && frame.payload?.req_id === listReq, args.timeoutMs);
  const sessions = (listing.payload?.workspaces || []).flatMap((workspace) => workspace.sessions || []);
  const target = sessions.find((session) => session.ref === args.ref);
  if (!target) fail('target ref was not present in authoritative listing', { ref: args.ref, sessionCount: sessions.length });

  const closeReq = 2;
  send('close_session', { req_id: closeReq, ref: args.ref });
  let result;
  try {
    result = await waitForMessage(ws, (frame) => (
      (frame.type === 'close_session_result' || frame.type === 'error')
      && (frame.payload?.req_id === closeReq || frame.payload?.code === 'unsupported_type')
    ), args.timeoutMs);
  } finally {
    try { ws.close(); } catch {}
  }
  return { outbound, inbound, auth: sanitizedFrame(auth), listing: { sessionCount: sessions.length, target }, result: sanitizedFrame(result) };
}

async function loadBrowserReceipt(path) {
  if (!path) return null;
  const raw = await readFile(path, 'utf8');
  const receipt = JSON.parse(raw);
  if (JSON.stringify(receipt).match(/token|authorization/i)) fail('browser receipt contains a forbidden credential field');
  return receipt;
}

function assertBrowserReceipt(receipt) {
  if (!receipt) return null;
  const failures = [];
  const tab = receipt.tab;
  if (tab && tab.clipPx > 0) failures.push(`TAB active capsule is clipped by ${tab.clipPx}px`);
  const colors = receipt.dark?.colors || [];
  const badColors = colors.filter((color) => Number(color.contrast) < 4.5);
  if (badColors.length) failures.push(`COLOR ${badColors.length} foreground colors are below WCAG 4.5:1`);
  if (receipt.paste?.ctrlVDefaultPrevented && receipt.paste?.nativeTextFallback !== true) {
    failures.push('PASTE Ctrl+V suppresses browser paste without a verified native text fallback');
  }
  const mapping = receipt.mapping;
  if (mapping?.silentEvents?.length) failures.push(`INPUT ${mapping.silentEvents.length} mouse/key events are silently dropped`);
  if (failures.length) fail('browser integration gate failed', { failures });
  return { ok: true, checks: ['tab', 'dark', 'paste', 'mapping'].filter((key) => receipt[key]) };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) { console.log(usage()); return; }
  validateConfig(args);

  if (args.browserReceipt) {
    const receipt = await loadBrowserReceipt(args.browserReceipt);
    assertBrowserReceipt(receipt);
  }

  if (args.mode === 'preflight') {
    const tmux = await probeTmux(args);
    if (!tmux.exists) fail('preflight target tmux session does not exist', { tmux });
    console.log(JSON.stringify({ mode: args.mode, host: args.host, distro: args.distro, session: args.session, tmux }, null, 2));
    return;
  }

  if (args.mode !== 'close') fail(`unsupported mode: ${args.mode}`);
  const before = await probeTmux(args);
  if (!before.exists) fail('target tmux session disappeared before close action', { before });
  const protocol = await protocolClose(args);
  const result = protocol.result;
  const accepted = result.type === 'close_session_result' && result.payload?.ok === true;
  const gone = await waitForGone(args);
  const report = { mode: args.mode, session: args.session, ref: args.ref, before, protocol, termination: gone };
  if (!accepted || !gone.gone) {
    const reason = !accepted ? 'close protocol was rejected or not acknowledged' : 'tmux session survived the 1-second termination window';
    const error = new Error(reason);
    error.details = report;
    throw error;
  }
  console.log(JSON.stringify({ ...report, verdict: 'PASS' }, null, 2));
}

if (process.argv[1] && new URL(process.argv[1], 'file:').href === import.meta.url) {
  main().catch((error) => {
    const details = error.details || {};
    console.error(JSON.stringify({ verdict: 'FAIL', reason: error.message, ...details }, null, 2));
    process.exitCode = 1;
  });
}

export { assertBrowserReceipt, parseArgs, probeTmux, waitForGone };
