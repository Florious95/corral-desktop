/**
 * 逐会话截 **Web 端整个界面**（含左侧 UI），视口对齐桌面端窗口尺寸。
 *
 * 为什么视口要和桌面端一样：客户端按容器像素算 cols，尺寸一致 ⇒ 申报的几何与桌面端一致
 * ⇒ daemon 的 reshape 是 no-op ⇒ ⛔ 不打扰用户正在看的界面。
 *
 * ⛔ 不改产品码。⛔ 不驱动系统键鼠（点击走 CDP Runtime.evaluate → HTMLElement.click）。
 * ⛔ token 不打印：只在进程内从 tauri store 读出后写进页面 localStorage。
 *
 * 用法： node .team/nodes/garble/shots-web.mjs --origin http://localhost:5219 --out <dir> [--w 1400] [--h 860]
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import WebSocket from '/Volumes/nvme/Projects/tmux桌面端/node_modules/ws/index.js';
import { loadPairing, DEVICES_KEY } from '/Volumes/nvme/Projects/tmux桌面端/scripts/garble-sweep.mjs';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 🔴 用户 2026-08-23 令：「我收藏里面的那些会话，在测试过程中都不要点。」
// 收藏的 5 个全是 claude_code 席位（多agent协作 / tmux桌面端 / 本地部署 /
// 讨论team-agent / 远程Agent安卓），含用户正在用的这条对话。⛔ 一律跳过。
const EXCLUDE = (title) => /^claude_code$/i.test((title || '').trim());

function arg(name, dflt) {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : dflt;
}
const ORIGIN = arg('--origin', 'http://localhost:5219');
const OUT = arg('--out', '/Volumes/nvme/Projects/tmux桌面端/.team/nodes/garble/shots-web');
const W = Number(arg('--w', '1400'));
const H = Number(arg('--h', '860'));
const CDP = Number(arg('--cdp', '9411'));
const ROUNDS = Number(arg('--rounds', '1'));
const CHROME_DIR = arg('--chrome-dir', '/Volumes/nvme/Projects/tmux桌面端/.team/nodes/garble/chrome-profile-web');

class Tab {
  constructor(u) { this.u = u; this.id = 0; this.p = new Map(); }
  async open() {
    this.ws = new WebSocket(this.u);
    await new Promise((res, rej) => { this.ws.once('open', res); this.ws.once('error', rej); });
    this.ws.on('message', (raw) => {
      let m; try { m = JSON.parse(raw.toString()); } catch { return; }
      if (m.id && this.p.has(m.id)) {
        const { resolve, reject } = this.p.get(m.id); this.p.delete(m.id);
        m.error ? reject(new Error(m.error.message)) : resolve(m.result);
      }
    });
  }
  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((resolve, reject) => { this.p.set(id, { resolve, reject }); this.ws.send(JSON.stringify({ id, method, params })); });
  }
  async evaluate(expression) {
    const r = await this.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error('evaluate: ' + (r.exceptionDetails.exception?.description || r.exceptionDetails.text));
    return r.result?.value;
  }
}

async function waitOk(url, ms) {
  const t0 = Date.now();
  for (;;) {
    try { const r = await fetch(url); if (r.ok) return; } catch { /* */ }
    if (Date.now() - t0 > ms) throw new Error('timeout ' + url);
    await sleep(250);
  }
}

const main = async () => {
  mkdirSync(OUT, { recursive: true });
  const pairing = loadPairing(); // ⛔ 不打印

  const chrome = spawn(CHROME, [
    `--remote-debugging-port=${CDP}`, `--user-data-dir=${CHROME_DIR}`,
    '--no-first-run', '--no-default-browser-check', '--disable-sync', '--disable-extensions',
    '--headless=new', `--window-size=${W},${H}`, 'about:blank',
  ], { stdio: 'ignore' });

  try {
    await waitOk(`http://127.0.0.1:${CDP}/json/version`, 20000);
    const t = await (await fetch(`http://127.0.0.1:${CDP}/json/new?${ORIGIN}/`, { method: 'PUT' })).json();
    const tab = new Tab(t.webSocketDebuggerUrl);
    await tab.open();
    await tab.send('Runtime.enable');
    await tab.send('Page.enable');
    // 视口逐像素对齐桌面端窗口
    await tab.send('Emulation.setDeviceMetricsOverride', { width: W, height: H, deviceScaleFactor: 1, mobile: false });
    await sleep(400);

    const devicesJson = JSON.stringify([{ id: pairing.id, name: pairing.name, url: pairing.url, token: pairing.token }]);
    await tab.evaluate(`(() => { localStorage.setItem(${JSON.stringify(DEVICES_KEY)}, ${JSON.stringify(devicesJson)}); location.reload(); return 'paired'; })()`);
    await sleep(1500);

    // 等会话列表
    let n = 0;
    for (let i = 0; i < 100; i++) {
      n = await tab.evaluate(`document.querySelectorAll('.agents-row').length`);
      if (n > 0) break;
      await sleep(300);
    }
    if (!n) throw new Error('no .agents-row（配对或 listing 失败）');

    const agents = await tab.evaluate(`([...document.querySelectorAll('.agents-row')].map((el,i)=>({
      i, title: (el.querySelector('.agents-row-title')?.textContent||'').trim(),
      sub: (el.textContent||'').trim().slice(0,120)
    })))`);

    const skipped = agents.filter((a) => EXCLUDE(a.title)).map((a) => a.title);
    const targets = agents.filter((a) => !EXCLUDE(a.title));
    if (skipped.length) console.log('⛔ 跳过收藏会话:', skipped.join(', '));

    const rows = [];
    for (let round = 1; round <= ROUNDS; round++) {
    for (const a of targets) {
      await tab.evaluate(`(()=>{const el=document.querySelectorAll('.agents-row')[${a.i}]; if(!el) return 'miss'; el.scrollIntoView({block:'center'}); el.click(); return 'ok';})()`);
      await sleep(2200); // 等订阅 + 首帧 + 稳定
      const shot = await tab.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false });
      const safe = String(a.i).padStart(2, '0') + '__' + (a.title || 'untitled').replace(/[^\w一-龥.-]+/g, '_').slice(0, 60);
      const file = (ROUNDS > 1 ? `r${round}__` : '') + safe + '.png';
      writeFileSync(join(OUT, file), Buffer.from(shot.data, 'base64'));
      const geom = await tab.evaluate(`(()=>{
        const c=document.querySelector('.xterm-screen'); const r=c&&c.getBoundingClientRect();
        const rowEl=document.querySelector('.xterm-rows>div');
        const cols=(window.__amCols)||null;
        const nrows=document.querySelectorAll('.xterm-rows>div').length||null;
        const ncols=rowEl? (rowEl.querySelectorAll('span').length||null):null;
        return JSON.stringify({canvas: r?Math.round(r.width)+'x'+Math.round(r.height):'n/a', rows:nrows, spans:ncols, vw:innerWidth, vh:innerHeight, dpr:devicePixelRatio});
      })()`);
      rows.push({ round, i: a.i, title: a.title, file, geom });
      console.log(`[r${round} ${a.i + 1}/${agents.length}] ${file}`);
    }
    }

    const md = ['# Web 端逐会话截图（整界面，含左侧 UI）', '',
      `视口 **${W}x${H}**（对齐桌面端窗口），deviceScaleFactor=2，headless Chrome + CDP。`,
      `会话数 **${agents.length}**，实测 **${targets.length}**（⛔ 跳过收藏 ${skipped.length} 个：${skipped.join(', ') || '无'}），截图 **${rows.length}** 张。`, '',
      '| 轮 | # | 会话 | 文件 | 几何读数 |', '|---|---|---|---|---|',
      ...rows.map((r) => `| ${r.round} | ${r.i} | ${r.title} | ${r.file} | \`${r.geom}\` |`)].join('\n');
    writeFileSync(join(OUT, 'index.md'), md + '\n');
    console.log('OK ->', OUT);
  } finally {
    try { chrome.kill('SIGTERM'); } catch { /* */ }
  }
};

main().catch((e) => { console.error('FAIL', e.message); process.exit(1); });
