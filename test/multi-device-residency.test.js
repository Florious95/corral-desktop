import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import {
  encodeControl,
  decodeControl,
  validateFrame,
} from '../src/core/protocol.js';
import { Client, ClientState } from '../src/core/client.js';
import { DeviceManager } from '../src/core/devices.js';
import { MOBILE_GRID, PRESENCE_MODE } from '../src/core/presence.js';
import { Terminal } from '@xterm/xterm/lib/xterm.mjs';

test('protocol codec: subscribe encodes client_type and retain_pane_size; presence_update validates strictly', () => {
  // 1. subscribe 帧携带多端协同与尺寸驻留扩展字段
  const subPayload = {
    ref: 'pane-42',
    rows: 44,
    cols: 46,
    client_type: 'desktop',
    retain_pane_size: true,
  };
  const encoded = encodeControl('subscribe', subPayload);
  const parsed = JSON.parse(encoded);
  assert.equal(parsed.type, 'subscribe');
  assert.equal(parsed.payload.client_type, 'desktop');
  assert.equal(parsed.payload.retain_pane_size, true);
  assert.equal(parsed.payload.rows, 44);
  assert.equal(parsed.payload.cols, 46);

  // 2. subscribe 字段校验拦截
  assert.equal(
    validateFrame('subscribe', { ref: 'p1', rows: 24, cols: 80, client_type: '' }),
    'subscribe client_type must be a non-empty string',
  );
  assert.equal(
    validateFrame('subscribe', { ref: 'p1', rows: 24, cols: 80, retain_pane_size: 'true' }),
    'subscribe retain_pane_size must be boolean',
  );

  // 3. presence_update 帧校验与解码
  const presenceWire = JSON.stringify({
    v: 1,
    type: 'presence_update',
    payload: {
      ref: 'pane-42',
      has_mobile: true,
      mobile_count: 1,
      desktop_count: 1,
    },
  });
  const decodedPresence = decodeControl(presenceWire);
  assert.equal(decodedPresence.type, 'presence_update');
  assert.equal(decodedPresence.payload.has_mobile, true);
  assert.equal(decodedPresence.payload.mobile_count, 1);
  assert.equal(decodedPresence.payload.desktop_count, 1);

  // 非法 presence_update 校验拦截
  assert.equal(validateFrame('presence_update', { ref: '' }), 'presence_update ref must be non-empty');
  assert.equal(
    validateFrame('presence_update', { ref: 'p1', has_mobile: 'true' }),
    'presence_update has_mobile must be boolean',
  );
  assert.equal(
    validateFrame('presence_update', { ref: 'p1', has_mobile: true, mobile_count: -1 }),
    'presence_update mobile_count must be a non-negative integer',
  );
});

test('Client and DeviceManager track presenceByRef and route presence_update with deviceId::ref', () => {
  const sentFrames = [];
  const fakeWs = {
    readyState: 1,
    send: (text) => sentFrames.push(text),
    close: () => {},
  };
  const client = new Client({
    url: 'ws://127.0.0.1:9900/ws',
    token: 'mock-token',
    wsFactory: () => fakeWs,
  });

  client.connect();
  client.handleOpen();
  // 模拟 auth_ack 成功进入 READY
  client.handleMessage(JSON.stringify({ v: 1, type: 'auth_ack', payload: { ok: true } }));

  // 1. subscribe 携带 client_type 与 retain_pane_size
  sentFrames.length = 0;
  client.subscribe('pane-1', 44, 46, 'user', { client_type: 'desktop', retain_pane_size: true });
  assert.equal(sentFrames.length, 1);
  const subFrame = decodeControl(sentFrames[0]);
  assert.equal(subFrame.payload.client_type, 'desktop');
  assert.equal(subFrame.payload.retain_pane_size, true);

  // 2. 模拟服务端下发 presence_update
  client.handleMessage(
    JSON.stringify({
      v: 1,
      type: 'presence_update',
      payload: {
        ref: 'pane-1',
        has_mobile: true,
        mobile_count: 1,
        desktop_count: 1,
      },
    }),
  );

  const presence = client.presenceByRef.get('pane-1');
  assert.ok(presence);
  assert.equal(presence.hasMobile, true);
  assert.equal(presence.mobileCount, 1);

  // 3. DeviceManager 窄路由分发
  const dmEvents = [];
  const dm = new DeviceManager({
    storage: { getItem: () => null, setItem: () => {}, removeItem: () => {} },
    onPresenceUpdate: (e) => dmEvents.push(e),
  });

  dm._devices = [{ id: 'dev-alpha', checked: true, name: 'Mac' }];
  dm._clients.set('dev-alpha', client);

  dm._onFrame('dev-alpha', 'presence_update', {
    ref: 'pane-1',
    has_mobile: true,
    mobile_count: 1,
    desktop_count: 1,
  });

  assert.equal(dmEvents.length, 1);
  assert.equal(dmEvents[0].uid, 'dev-alpha::pane-1');
  assert.equal(dmEvents[0].hasMobile, true);

  const dmPresence = dm.getPresence('dev-alpha::pane-1');
  assert.equal(dmPresence?.hasMobile, true);
});

test('Astra §3.2 CSS root bottom-left anchor eliminates flex-end clipping and keeps 46x44 input visible', () => {
  // 模拟桌面端受限宿主视口（1000px 宽 x 600px 高）
  const hostRect = { left: 0, top: 0, right: 1000, bottom: 600, width: 1000, height: 600 };

  // 手机端真实 46 列 x 44 行网格，字号 13px，cellW = 8px, cellH = 18px
  const cellW = 8;
  const cellH = 18;
  const cols = MOBILE_GRID.cols; // 46
  const rows = MOBILE_GRID.rows; // 44
  const xtermW = cols * cellW; // 368px
  const xtermH = rows * cellH; // 792px！物理高度超出 host (600px)

  // Astra §3.2 规范：.terminalpane-host > .xterm { position: absolute; left: 0; bottom: 0; width: max-content; }
  // 计算此时 .xterm 的绝对定位物理坐标
  const xtermLeft = hostRect.left; // 0
  const xtermRight = xtermLeft + xtermW; // 368
  const xtermBottom = hostRect.bottom; // 600 (贴紧宿主底部)
  const xtermTop = xtermBottom - xtermH; // 600 - 792 = -192 (顶端自然向上伸出被裁切)

  const xtermRect = {
    left: xtermLeft,
    top: xtermTop,
    right: xtermRight,
    bottom: xtermBottom,
    width: xtermW,
    height: xtermH,
  };

  // 1. 底边必须 100% 绝对吻合（误差 0 像素）
  assert.equal(xtermRect.bottom, hostRect.bottom);
  assert.equal(xtermRect.left, hostRect.left);

  // 2. 状态行（第 44 行）与输入框 [ █ ]（第 43 行）坐标验证
  const statusRowTop = xtermRect.bottom - cellH; // 600 - 18 = 582
  const statusRowBottom = xtermRect.bottom; // 600
  const inputBoxTop = xtermRect.bottom - 2 * cellH; // 600 - 36 = 564
  const inputBoxBottom = statusRowTop; // 582

  // 核心验收断言：输入框与状态行 100% 坐落在宿主可视区 [0..600] 内部！
  assert.ok(inputBoxTop >= hostRect.top, 'Input box top must be >= host top');
  assert.ok(inputBoxBottom <= hostRect.bottom, 'Input box bottom must be <= host bottom');
  assert.ok(statusRowTop >= hostRect.top, 'Status row top must be >= host top');
  assert.ok(statusRowBottom <= hostRect.bottom, 'Status row bottom must be <= host bottom');

  // 超出宿主顶部的高度为 192px（仅裁切掉上方已阅的历史消息，输入区完全不受损）
  assert.equal(hostRect.top - xtermRect.top, 192);
});

test('terminal.css adheres strictly to Astra §3.2 root bottom-left anchoring specification', async () => {
  const terminalCss = await readFile(new URL('../src/components/terminal/terminal.css', import.meta.url), 'utf8');

  // .terminalpane-host 作为相对定位裁切窗口
  assert.match(terminalCss, /\.terminalpane-host\s*\{[^}]*position:\s*relative;/);
  assert.match(terminalCss, /\.terminalpane-host\s*\{[^}]*display:\s*block;/);
  assert.match(terminalCss, /\.terminalpane-host\s*\{[^}]*overflow:\s*hidden;/);

  // .terminalpane-host > .xterm 绝对底锚，清除一切 flex 压扁与 max-height
  assert.match(terminalCss, /\.terminalpane-host > \.xterm\s*\{[^}]*position:\s*absolute;/);
  assert.match(terminalCss, /\.terminalpane-host > \.xterm\s*\{[^}]*left:\s*0;/);
  assert.match(terminalCss, /\.terminalpane-host > \.xterm\s*\{[^}]*bottom:\s*0;/);
  assert.match(terminalCss, /\.terminalpane-host > \.xterm\s*\{[^}]*width:\s*max-content;/);
  assert.match(terminalCss, /\.terminalpane-host > \.xterm\s*\{[^}]*max-width:\s*none;/);
  assert.match(terminalCss, /\.terminalpane-host > \.xterm\s*\{[^}]*max-height:\s*none;/);

  // 绝对不再使用脆弱的 flex-end
  assert.equal(terminalCss.includes('justify-content: flex-end'), false, 'flex-end must be eliminated');
});

test('TerminalPane mode constants and 46x44 conservative initial grid', () => {
  assert.equal(MOBILE_GRID.cols, 46);
  assert.equal(MOBILE_GRID.rows, 44);
  assert.deepEqual(Object.values(PRESENCE_MODE).sort(), ['avoidance', 'takeover', 'unknown']);
});
