import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import {
  attachWebglRenderer,
  silenceRenderLayerAtlas,
  releaseCanvasMemory,
  retireTextureAtlas,
  hookTextureAtlas,
  installAtlasMemoryHygiene,
} from '../src/term/webglRenderer.js';
import { setNativeEngineForTests, resetNativeEngineForTests } from '../src/core/nativeCapabilities.js';
import { DeviceManager } from '../src/core/devices.js';

beforeEach(() => setNativeEngineForTests({ platform: 'macos' }));
afterEach(() => resetNativeEngineForTests());

class FakeCanvas {
  constructor(width = 512, height = 512) {
    this.tagName = 'CANVAS';
    this.width = width;
    this.height = height;
    this.style = {};
    this.classList = {
      classes: new Set(),
      add(c) { this.classes.add(c); },
      contains(c) { return this.classes.has(c); },
    };
    this.removed = false;
  }
  remove() {
    this.removed = true;
  }
  getBoundingClientRect() {
    return { width: this.width || 800, height: this.height || 600 };
  }
  getContext() {
    return {
      fillStyle: '',
      globalCompositeOperation: 'source-over',
      save() {},
      restore() {},
      fillRect() {},
      clearRect() {},
      drawImage() {},
      beginPath() {},
      rect() {},
      clip() {},
      fillText() {},
      measureText: () => ({ width: 8, actualBoundingBoxDescent: 2 }),
      getImageData: (_x, _y, w, h) => ({ data: new Uint8Array(Math.max(4, w * h * 4)) }),
    };
  }
}

test('MVP M1: silenceRenderLayerAtlas blocks 2048 atlas acquisition on instance and prototype while retiring orphan atlas', () => {
  let protoRefreshCalls = 0;
  class FakeBaseRenderLayer {
    _fillBottomLineAtCells() {}
    _refreshCharAtlas() {
      protoRefreshCalls += 1;
    }
  }
  class FakeLinkRenderLayer extends FakeBaseRenderLayer {}

  const orphanTmpCanvas = new FakeCanvas(256, 64);
  const orphanPageCanvas = new FakeCanvas(512, 512);
  let orphanWarmUpDraws = 0;
  const orphanAtlas = {
    _tmpCanvas: orphanTmpCanvas,
    pages: [{ canvas: orphanPageCanvas }],
    _activePages: [{ canvas: orphanPageCanvas }],
    _cacheMap: {
      cleared: false,
      clear() { this.cleared = true; },
      get() { return undefined; },
      set() {},
    },
    _drawToCache() {
      orphanWarmUpDraws += 1;
    },
  };

  const sharedPageCanvas = new FakeCanvas(1024, 1024);
  const sharedAtlas = {
    _tmpCanvas: new FakeCanvas(256, 64),
    pages: [{ canvas: sharedPageCanvas }],
  };

  const layer = new FakeLinkRenderLayer();
  layer._charAtlas = orphanAtlas;

  const addon = {
    _renderer: {
      _charAtlas: sharedAtlas,
      _renderLayers: [layer],
    },
  };

  silenceRenderLayerAtlas(addon);

  // 1. Layer instance and BaseRenderLayer prototype _refreshCharAtlas must be silenced
  layer._refreshCharAtlas();
  const anotherLayer = new FakeLinkRenderLayer();
  anotherLayer._refreshCharAtlas();
  assert.equal(protoRefreshCalls, 0, 'BaseRenderLayer._refreshCharAtlas must be silenced on both instance and prototype');
  assert.equal(layer._charAtlas, undefined, 'layer._charAtlas reference must be cleared');

  // 2. Orphan 2048 atlas canvases must be zeroed and warmUp neutralized
  assert.equal(orphanTmpCanvas.width, 0);
  assert.equal(orphanTmpCanvas.height, 0);
  assert.equal(orphanPageCanvas.width, 0);
  assert.equal(orphanPageCanvas.height, 0);
  assert.equal(orphanAtlas._isRetired, true);

  // Simulate late IdleTaskQueue warmUp callback firing after retirement
  if (!orphanAtlas._cacheMap.get(33, 0, 0, 0)) {
    orphanAtlas._drawToCache(33, 0, 0, 0, false, undefined);
  }
  assert.equal(orphanWarmUpDraws, 0, 'Retired atlas must not execute _drawToCache during late warmUp ticks');

  // 3. Shared main renderer atlas must remain completely intact
  assert.equal(sharedPageCanvas.width, 1024);
  assert.equal(sharedPageCanvas.height, 1024);
});

test('MVP M1: installAtlasMemoryHygiene zeroes retired AtlasPage canvases on mergePages/evictAllPages and on TextureAtlas.dispose', () => {
  const removeListeners = [];
  const atlasRemoveListeners = [];

  class MockTextureAtlas {
    constructor() {
      this._tmpCanvas = new FakeCanvas(128, 32);
      this.pages = [
        { canvas: new FakeCanvas(512, 512) },
        { canvas: new FakeCanvas(512, 512) },
        { canvas: new FakeCanvas(512, 512) },
        { canvas: new FakeCanvas(512, 512) },
      ];
      this._activePages = [...this.pages];
      this._cacheMap = {
        get() { return undefined; },
        set() {},
        clear() {},
      };
      this._onAddTextureAtlasCanvas = { _disposed: false };
      this.onRemoveTextureAtlasCanvas = (fn) => {
        atlasRemoveListeners.push(fn);
        return { dispose() {} };
      };
    }
    _drawToCache() {
      this._tmpCanvas.width = 256;
      return { size: { x: 8, y: 16 } };
    }
    dispose() {
      this._onAddTextureAtlasCanvas._disposed = true;
    }
  }

  const atlas = new MockTextureAtlas();
  const mainCanvas = new FakeCanvas(1600, 1000);
  const linkCanvas = new FakeCanvas(1600, 1000);
  const addon = {
    _renderer: {
      _canvas: mainCanvas,
      _charAtlas: atlas,
      _renderLayers: [{ _canvas: linkCanvas, _refreshCharAtlas() {} }],
    },
    onRemoveTextureAtlasCanvas(fn) {
      removeListeners.push(fn);
      return { dispose() {} };
    },
    dispose() {
      atlas.dispose();
    },
  };

  installAtlasMemoryHygiene(addon);

  // 1. Simulate _mergePages retiring the 4 512x512 pages into a new 1024x1024 page
  const oldPages = [...atlas.pages];
  const mergedPage = { canvas: new FakeCanvas(1024, 1024) };
  atlas.pages = [mergedPage];
  atlas._activePages = [mergedPage];
  for (const p of oldPages) {
    for (const fn of atlasRemoveListeners) fn(p.canvas);
  }

  for (const p of oldPages) {
    assert.equal(p.canvas.width, 0, 'Merged old AtlasPage canvas width must be zeroed');
    assert.equal(p.canvas.height, 0, 'Merged old AtlasPage canvas height must be zeroed');
    assert.equal(p.canvas.removed, true, 'Merged old AtlasPage canvas must be removed');
  }
  assert.equal(mergedPage.canvas.width, 1024, 'Active merged AtlasPage canvas must remain intact');

  // 2. Simulate final addon & atlas disposal when pane closes
  addon.dispose();
  assert.equal(mainCanvas.width, 0, 'Disposed WebGL main canvas width must be zeroed');
  assert.equal(linkCanvas.width, 0, 'Disposed LinkRenderLayer canvas width must be zeroed');
  assert.equal(atlas._tmpCanvas.width, 0, 'Disposed TextureAtlas _tmpCanvas width must be zeroed');
  assert.equal(mergedPage.canvas.width, 0, 'Disposed TextureAtlas active page canvas width must be zeroed');

  // 3. Late warmUp draw after dispose must not re-inflate _tmpCanvas
  const res = atlas._drawToCache(65, 0, 0, 0, false, undefined);
  assert.equal(atlas._tmpCanvas.width, 0, 'Post-dispose _drawToCache must be blocked from re-inflating _tmpCanvas');
  assert.deepEqual(res.size, { x: 0, y: 0 });
});

test('MVP M1: attachWebglRenderer integrates pre-activation LinkRenderLayer guard and atlas hygiene without detaching on tab switch', async () => {
  let linkLayerAtlasAcquisitions = 0;
  let mainRendererAtlasAcquisitions = 0;

  class SharedDisposable {
    _register(d) {
      return d;
    }
    dispose() {}
  }

  class MockBaseRenderLayer extends SharedDisposable {
    constructor() {
      super();
      this._canvas = new FakeCanvas(800, 600);
      this._register({ dispose() {} });
    }
    _fillBottomLineAtCells() {}
    _refreshCharAtlas() {
      linkLayerAtlasAcquisitions += 1;
      this._charAtlas = { id: 'bad-2048-atlas', _tmpCanvas: new FakeCanvas(64, 64), pages: [] };
    }
    resize() {
      this._refreshCharAtlas();
    }
  }

  class MockWebglAddon extends SharedDisposable {
    constructor() {
      super();
      this._removeCbs = [];
    }
    onRemoveTextureAtlasCanvas(cb) {
      this._removeCbs.push(cb);
      return { dispose() {} };
    }
    onContextLoss() {}
    activate(term) {
      const layer = new MockBaseRenderLayer();
      // Simulate WebglRenderer.handleResize() calling layer.resize() during loadAddon
      layer.resize();
      mainRendererAtlasAcquisitions += 1;
      const sharedAtlas = {
        id: 'shared-16384-atlas',
        _tmpCanvas: new FakeCanvas(128, 32),
        pages: [{ canvas: new FakeCanvas(512, 512) }],
      };
      this._renderer = {
        _canvas: new FakeCanvas(800, 600),
        _renderLayers: [layer],
        _charAtlas: sharedAtlas,
        _refreshCharAtlas() {},
      };
      term.element.canvas = this._renderer._canvas;
    }
  }

  const makeFakeTerm = () => ({
    element: {
      canvas: null,
      querySelector(sel) {
        return sel.includes('canvas') ? this.canvas : null;
      },
    },
    loadAddon(addon) {
      addon.activate(this);
    },
  });

  const importer = async () => ({ WebglAddon: MockWebglAddon });
  const term1 = makeFakeTerm();
  const term2 = makeFakeTerm();

  const addon1 = await attachWebglRenderer(term1, importer);
  const addon2 = await attachWebglRenderer(term2, importer);

  assert.ok(addon1);
  assert.ok(addon2);
  assert.equal(
    linkLayerAtlasAcquisitions,
    0,
    'Pre-activation guard must prevent LinkRenderLayer from acquiring 2048 atlas even on the very first terminal',
  );
  assert.equal(mainRendererAtlasAcquisitions, 2);
});

test('MVP M1: DeviceManager purges vanished sessionDetails on full listing and device removal', () => {
  const dm = new DeviceManager({ autoLocal: false, storage: null });
  dm._devices = [{ id: 'dev-1', name: 'Dev 1', url: 'ws://127.0.0.1:9900/ws', token: 'tok', checked: true }];

  dm._recordListingSessions('dev-1', {
    workspaces: [{
      cwd: '/home/user',
      sessions: [{ ref: '%1', name: 's1' }, { ref: '%2', name: 's2' }],
    }],
  });
  assert.equal(dm._sessionDetails.has('dev-1::%1'), true);
  assert.equal(dm._sessionDetails.has('dev-1::%2'), true);

  // Next full listing where %2 vanished
  dm._recordListingSessions('dev-1', {
    workspaces: [{
      cwd: '/home/user',
      sessions: [{ ref: '%1', name: 's1' }],
    }],
  });
  assert.equal(dm._sessionDetails.has('dev-1::%1'), true);
  assert.equal(dm._sessionDetails.has('dev-1::%2'), false, 'Vanished session %2 must be purged from _sessionDetails');

  // Removing device purges all remaining sessionDetails for that device
  dm.removeDevice('dev-1');
  assert.equal(dm._sessionDetails.has('dev-1::%1'), false, 'Removing device must purge all its sessionDetails');
});

test('MVP M1: Resident WebGL & stream invariant — no detachWebgl or background unsubscribe in TerminalView / TerminalPane', async () => {
  const [terminalViewJs, terminalPaneJsx, uiSpec] = await Promise.all([
    readFile(new URL('../src/term/TerminalView.js', import.meta.url), 'utf8'),
    readFile(new URL('../src/components/terminal/TerminalPane.jsx', import.meta.url), 'utf8'),
    readFile(new URL('../docs/UI-SPEC.md', import.meta.url), 'utf8'),
  ]);

  // Must NOT detach WebGL or unsubscribe stream on tab switch
  assert.doesNotMatch(terminalViewJs, /detachWebgl\s*\(/);
  assert.doesNotMatch(terminalPaneJsx, /visibility_resume/);
  assert.doesNotMatch(terminalPaneJsx, /if\s*\(!viewRef\.current\?\.isVisible\)\s*return/);

  // UI-SPEC documents 2026-09-26 Phase M1 ruling
  assert.match(uiSpec, /2026-09-26（WebGL 字符图集所有权收敛与退役 AtlasPage 显存主动回收，MVP Phase M1）/);
});
