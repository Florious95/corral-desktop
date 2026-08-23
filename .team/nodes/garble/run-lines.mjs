#!/usr/bin/env node
/**
 * t.lines: same pane, same instant — capture-pane -e / -p / -J structure only.
 * ⛔ no pane text in artifacts. ⛔ no send-keys to user panes.
 */
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import WebSocket from '/Volumes/nvme/Projects/tmux桌面端/node_modules/ws/index.js';
import { Client } from '../../../src/vendor/agentmirror/client.js';
import { detectGarble } from '../../../src/term/garbleDetect.js';
import { parseSessionRef } from './tmux-pane-query.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const TERM_ROWS = 39;
const TERM_COLS = 114;
const CSI_OR_ESC = /\x1b(?:\[[0-?]*[ -/]*[@-~]|].*?(?:\x07|\x1b\\)|[PX^_].*?\x1b\\|[\[\]()#%][0-9;]*[0-9A-Za-z]|.)/gs;
const CSI_NO_DOTALL = /\x1b(?:\[[0-?]*[ -/]*[@-~]|].*?(?:\x07|\x1b\\)|[PX^_].*?\x1b\\|[\[\]()#%][0-9;]*[0-9A-Za-z]|.)/g;

function loadPairing() {
  const store = JSON.parse(readFileSync(
    `${homedir()}/Library/Application Support/com.agentmirror.desktop/devices.json`,
    'utf8',
  ));
  const devs = Array.isArray(store) ? store : (store.devices ?? []);
  const dev = Array.isArray(devs) ? devs[0] : devs;
  if (!dev?.url || !dev?.token) throw new Error('pairing missing');
  return { url: dev.url, token: dev.token };
}

function envNoTmux() {
  const env = { ...process.env };
  delete env.TMUX;
  return env;
}

function cap(ref, extraArgs) {
  const p = parseSessionRef(ref);
  if (!p) return { ok: false, err: 'bad_ref' };
  const r = spawnSync(
    'tmux',
    ['-S', p.socket, 'capture-pane', ...extraArgs, '-t', p.pane],
    { encoding: 'utf8', env: envNoTmux(), timeout: 1500 },
  );
  if (r.status !== 0) return { ok: false, err: `tmux_${r.status}` };
  return { ok: true, text: r.stdout };
}

function strip(text, re) {
  return String(text || '').replace(re, '');
}

function lineWidths(text, re) {
  const stripped = strip(text, re).replace(/\r/g, '');
  const lines = stripped.split('\n').map((l) => l.replace(/\s+$/g, ''));
  const widths = lines.map((l) => detectGarble({ snapshot: l, termCols: TERM_COLS }).metrics.maxLineWidth);
  const cps = lines.map((l) => [...l].length);
  return {
    raw_nl: (String(text || '').match(/\n/g) || []).length,
    n_lines: lines.length,
    overwide: widths.filter((w) => w > TERM_COLS).length,
    max_w: widths.reduce((a, b) => Math.max(a, b), 0),
    n_eq_115: widths.filter((w) => w === 115).length,
    n_gt_115: widths.filter((w) => w > 115).length,
    widths,
    cps,
    lines,
  };
}

function classifyOverwide(e, p) {
  const out = { glued: 0, real115: 0, unmatched: 0, glue_how: { concat: 0, prefix_suffix: 0 } };
  for (let ei = 0; ei < e.lines.length; ei++) {
    if (e.widths[ei] <= TERM_COLS) continue;
    const el = e.lines[ei];
    const exact = p.lines.findIndex((pl, i) => pl === el && p.widths[i] > TERM_COLS);
    if (exact >= 0) {
      out.real115 += 1;
      continue;
    }
    let glued = false;
    for (let i = 0; i < p.lines.length - 1; i++) {
      if (p.widths[i] > TERM_COLS || p.widths[i + 1] > TERM_COLS) continue;
      const a = p.lines[i];
      const b = p.lines[i + 1];
      if (a + b === el) {
        out.glued += 1;
        out.glue_how.concat += 1;
        glued = true;
        break;
      }
      if (el.startsWith(a) && el.endsWith(b) && a.length + b.length === el.length) {
        out.glued += 1;
        out.glue_how.prefix_suffix += 1;
        glued = true;
        break;
      }
    }
    if (!glued) out.unmatched += 1;
  }
  return out;
}

function statsOf(text) {
  const withS = lineWidths(text, CSI_OR_ESC);
  const noS = lineWidths(text, CSI_NO_DOTALL);
  return {
    raw_nl: withS.raw_nl,
    n_lines_dotall: withS.n_lines,
    n_lines_nodotall: noS.n_lines,
    overwide_dotall: withS.overwide,
    overwide_nodotall: noS.overwide,
    max_w_dotall: withS.max_w,
    max_w_nodotall: noS.max_w,
    n_eq_115_dotall: withS.n_eq_115,
    strip_ate_lines: withS.n_lines < withS.raw_nl + 1,
    strip_dotall_vs_g: withS.n_lines !== noS.n_lines,
    _lw: withS,
  };
}

function collectSessions(workspaces) {
  const out = [];
  for (const w of workspaces || []) {
    for (const s of w.sessions || []) {
      if (s?.ref) out.push({ ref: s.ref });
    }
  }
  return out;
}

async function waitReady(client, ms) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (client.workspaces?.length) return true;
    await sleep(50);
  }
  return false;
}

async function liveScan() {
  const pairing = loadPairing();
  const client = new Client({
    url: pairing.url,
    token: pairing.token,
    wsFactory: (u) => new WebSocket(u),
    onFrame: () => {},
    onBinary: () => {},
    onLocalError: (c) => { process.stderr.write(`localError ${c}\n`); },
  });
  client.connect();
  if (!await waitReady(client, 15000)) {
    try { client.disconnect(); } catch { /* */ }
    return { ok: false, step: 'listing' };
  }
  const sessions = collectSessions(client.workspaces);
  const per = [];
  const tot = {
    n: 0,
    snap_overwide: 0,
    e_overwide: 0,
    p_overwide: 0,
    j_overwide: 0,
    glued: 0,
    real115: 0,
    unmatched: 0,
    glue_how: { concat: 0, prefix_suffix: 0 },
    strip_dotall_joins: 0,
    e_fewer_nl_than_p: 0,
  };
  try {
    for (const session of sessions) {
      let snap = null;
      const prev = client.onBinary;
      client.onBinary = (frame) => {
        if (!snap && frame.kind === 1 && frame.ref === session.ref) snap = frame;
        prev(frame);
      };
      client.subscribe(session.ref, TERM_ROWS, TERM_COLS);
      const t0 = Date.now();
      while (Date.now() - t0 < 4000 && !snap) await sleep(20);
      const e = cap(session.ref, ['-e', '-p']);
      const p = cap(session.ref, ['-p']);
      const j = cap(session.ref, ['-J', '-p']);
      client.unsubscribe(session.ref);
      client.onBinary = prev;
      if (!e.ok || !p.ok || !j.ok) continue;
      tot.n += 1;
      const se = statsOf(e.text);
      const sp = statsOf(p.text);
      const sj = statsOf(j.text);
      const snapText = snap ? new TextDecoder('utf-8', { fatal: false }).decode(snap.data) : '';
      const ss = snap ? statsOf(snapText) : null;
      const cls = classifyOverwide(se._lw, sp._lw);
      tot.e_overwide += se.overwide_dotall;
      tot.p_overwide += sp.overwide_dotall;
      tot.j_overwide += sj.overwide_dotall;
      if (ss) tot.snap_overwide += ss.overwide_dotall;
      tot.glued += cls.glued;
      tot.real115 += cls.real115;
      tot.unmatched += cls.unmatched;
      tot.glue_how.concat += cls.glue_how.concat;
      tot.glue_how.prefix_suffix += cls.glue_how.prefix_suffix;
      if (se.strip_dotall_vs_g) tot.strip_dotall_joins += 1;
      if (se.raw_nl < sp.raw_nl) tot.e_fewer_nl_than_p += 1;
      per.push({
        e: dropLines(se),
        p: dropLines(sp),
        j: dropLines(sj),
        snap: ss ? dropLines(ss) : null,
        classify: cls,
        snap_bytes: snap ? snap.data.length : 0,
      });
      await sleep(40);
    }
  } finally {
    try { client.disconnect(); } catch { /* */ }
  }
  return { ok: true, sessions: tot.n, tot, per };
}

function dropLines(s) {
  const { _lw, ...rest } = s;
  return rest;
}

function isolatedWrap() {
  const SOCK = '/tmp/tmux-501/aml';
  const env = envNoTmux();
  const tmux = (args, input) => spawnSync('tmux', ['-S', SOCK, ...args], {
    encoding: 'utf8', env, input, timeout: 2000,
  });
  spawnSync('mkdir', ['-p', '/tmp/tmux-501']);
  tmux(['kill-server']);
  const ns = tmux([
    'new-session', '-d', '-s', 'iso', '-x', '114', '-y', '8',
    '-e', 'PS1=',
    'bash', '--noprofile', '--norc',
  ]);
  if (ns.status !== 0) return { ok: false, err: ns.stderr };
  const line = `${'x'.repeat(113)}中`;
  tmux(['send-keys', '-t', 'iso', '-l', '--', line]);
  tmux(['send-keys', '-t', 'iso', 'Enter']);
  const e = tmux(['capture-pane', '-e', '-p', '-t', 'iso']);
  const p = tmux(['capture-pane', '-p', '-t', 'iso']);
  const j = tmux(['capture-pane', '-J', '-p', '-t', 'iso']);
  const se = statsOf(e.stdout);
  const sp = statsOf(p.stdout);
  const sj = statsOf(j.stdout);
  const cls = classifyOverwide(se._lw, sp._lw);
  tmux(['kill-server']);
  return {
    ok: true,
    fixture: '113 ASCII x + U+4E2D in 114-col own pane (not user)',
    e: dropLines(se),
    p: dropLines(sp),
    j: dropLines(sj),
    classify: cls,
  };
}

async function main() {
  const iso = isolatedWrap();
  const live = await liveScan();
  const out = { iso, live };
  writeFileSync(join(here, 'lines-run.json'), JSON.stringify(out, null, 2));
  process.stderr.write(`${JSON.stringify({
    iso_cls: iso.classify,
    iso_e_ow: iso.e && iso.e.overwide_dotall,
    iso_p_ow: iso.p && iso.p.overwide_dotall,
    iso_j_ow: iso.j && iso.j.overwide_dotall,
    live: live.tot,
  }, null, 2)}\n`);
}

main().catch((e) => {
  writeFileSync(join(here, 'lines-run.json'), JSON.stringify({ ok: false, error: String(e && e.message) }));
  process.exit(4);
});
