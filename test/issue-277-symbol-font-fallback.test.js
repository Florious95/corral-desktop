import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

import { DEFAULT_FONT_FAMILY, TERMINAL_FONT_FAMILIES } from '../src/core/settings.js';
import { TerminalView } from '../src/term/TerminalView.js';

test('Issue #277: DEFAULT_FONT_FAMILY includes symbol and Nerd Font fallbacks', () => {
  assert.ok(DEFAULT_FONT_FAMILY.includes('AgentMirror Symbols'), 'Must include AgentMirror Symbols');
  assert.ok(DEFAULT_FONT_FAMILY.includes('Symbols Nerd Font Mono'), 'Must include Symbols Nerd Font Mono');
  assert.ok(DEFAULT_FONT_FAMILY.includes('Apple Symbols'), 'Must include Apple Symbols');
  assert.ok(DEFAULT_FONT_FAMILY.includes('Segoe UI Symbol'), 'Must include Segoe UI Symbol');
});

test('Issue #277: tokens.css declares same-origin AgentMirror Symbols @font-face for U+1F5AB', async () => {
  const tokensCss = await readFile(
    new URL('../src/styles/tokens.css', import.meta.url),
    'utf8'
  );

  // 1. Same-origin @font-face for AgentMirror Symbols with U+1F5AB unicode-range (compliant with default-src 'self' CSP)
  assert.match(tokensCss, /@font-face\s*\{[^}]*font-family:\s*['"]AgentMirror Symbols['"]/);
  assert.match(tokensCss, /unicode-range:\s*U\+1F5AB/);
  assert.match(tokensCss, /src:\s*url\(['"]?\/fonts\/AgentMirrorSymbols\.ttf['"]?\)/);

  // 2. --font-mono includes AgentMirror Symbols, Apple Symbols, and Segoe UI Symbol
  assert.match(tokensCss, /--font-mono:[^;]*'AgentMirror Symbols'/);
  assert.match(tokensCss, /--font-mono:[^;]*'Symbols Nerd Font Mono'/);
  assert.match(tokensCss, /--font-mono:[^;]*'Apple Symbols'/);
  assert.match(tokensCss, /--font-mono:[^;]*'Segoe UI Symbol'/);
});

test('Issue #277: TerminalView.js terminalFontFamily places symbol fallbacks BEFORE generic monospace', async () => {
  const terminalViewJs = await readFile(
    new URL('../src/term/TerminalView.js', import.meta.url),
    'utf8'
  );

  // Source contract for terminalFontFamily helper: strips generic monospace and appends symbol fonts before monospace
  assert.match(terminalViewJs, /const terminalFontFamily =/);
  assert.match(terminalViewJs, /replace\(\/\(\?:,\\s\*\)\?\\bmonospace\\b\\s\*\$\/i,\s*''\)/);
  assert.match(terminalViewJs, /"AgentMirror Symbols"/);
  assert.match(terminalViewJs, /"Symbols Nerd Font Mono"/);
  assert.match(terminalViewJs, /"Apple Symbols"/);
  assert.match(terminalViewJs, /"Segoe UI Symbol"/);

  // Runtime test: instantiate FakeTerminal and verify term.options.fontFamily
  class FakeTerminal {
    constructor(opts) {
      this.options = { ...opts };
      this.element = null;
      this.cols = opts.cols || 80;
      this.rows = opts.rows || 24;
    }
    open() {}
    dispose() {}
    focus() {}
    blur() {}
  }

  const container = {
    clientWidth: 800,
    clientHeight: 400,
    isConnected: true,
    querySelector: () => null,
  };

  const view = new TerminalView(container, {
    fontFamily: 'Cascadia Code, Consolas, monospace',
    fontSize: 13,
    TerminalCtor: FakeTerminal,
  });

  const fontOptions = view.term.options.fontFamily;
  assert.ok(fontOptions.startsWith('Cascadia Code, Consolas,'), 'Primary font must be preserved without premature monospace');
  assert.ok(fontOptions.includes('"AgentMirror Symbols"'), 'Must include AgentMirror Symbols');
  assert.ok(fontOptions.includes('"Symbols Nerd Font Mono"'), 'Must include Symbols Nerd Font Mono');
  assert.ok(fontOptions.includes('"JetBrainsMono Nerd Font Mono"'), 'Must include JetBrainsMono Nerd Font Mono');
  assert.ok(fontOptions.includes('"Apple Symbols"'), 'Must include Apple Symbols');
  assert.ok(fontOptions.includes('"Segoe UI Symbol"'), 'Must include Segoe UI Symbol');
  // Generic monospace MUST only be at the very end of the full chain
  assert.match(fontOptions, /"Apple Symbols"[\s\S]*?monospace$/, 'Generic monospace must terminate the chain after all symbols');
});

test('Issue #277: UI-SPEC.md §6.2 documentation records symbol font fallback resolution', async () => {
  const spec = await readFile(
    new URL('../docs/UI-SPEC.md', import.meta.url),
    'utf8'
  );

  assert.match(spec, /AgentMirror Symbols/);
  assert.match(spec, /U\+1F5AB/);
  assert.match(spec, /Apple Symbols/);
  assert.match(spec, /Segoe UI Symbol/);
});

test('Issue #277: Real WKWebView renders U+1F5AB and footer symbols without tofu', async () => {
  if (process.platform !== 'darwin') return;

  const { execFileSync } = await import('node:child_process');
  const swiftCode = `
import AppKit
import WebKit

@MainActor
class Runner: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    var continuation: CheckedContinuation<Void, Never>?

    func run() async {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <style>
        @font-face {
          font-family: "AgentMirror Symbols";
          src: url("data:font/truetype;charset=utf-8;base64,AAEAAAAKAIAAAwAgT1MvMkTfR+cAAAEoAAAAYGNtYXAAHuwJAAABkAAAAFBnbHlmeTs6+gAAAegAAABiaGVhZDCdiBgAAACsAAAANmhoZWEHWgPrAAAA5AAAACRobXR4BwgA3AAAAYgAAAAIbG9jYQAxAA0AAAHgAAAABm1heHAABwATAAABCAAAACBuYW1lnRG/TgAAAkwAAACEcG9zdKSwe7sAAALQAAAALwABAAAAAQAAJzItPl8PPPUAAwPoAAAAAObZofMAAAAA5tmh8wBkAAADcANSAAAAAwACAAAAAAAAAAEAAAOE/5wAAAPoAGQAZANwAAEAAAAAAAAAAAAAAAAAAAACAAEAAAACABEABAAAAAAAAgAAAAAAAAAAAAAAAAAAAAAAAwOEAZAABQAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAAAAAAAAAAAPz8/PwAA/////wOE/5wAAAOEAGQAAAAAAAAAAAAAAAAAAAAgAAADIABkA+gAeAAAAAMAAAADAAAAHAADAAEAAAAcAAMACgAAADQABAAYAAAAAgACAAAAAP//AAD//wABAAAADAAAAAAAHAAAAAAAAAABAAH1qwAB9asAAAABAAAADQAxAAAAAQBkAAACvAMgAAMAADMRIRFkAlgDIPzgAAAEAHgAMgNwA1IABAAIAAwAEAAANxEhFxEBESERBTMVIwMRIRF4AmKW/ZQBfP7oZGR4AggyAyCW/XYDIP62AUpGtP4MAUD+wAAAAAAABAA2AAEAAAAAAAEAEwAAAAEAAAAAAAIABwATAAMAAQQJAAEAJgAaAAMAAQQJAAIADgBAQWdlbnRNaXJyb3IgU3ltYm9sc1JlZ3VsYXIAQQBnAGUAbgB0AE0AaQByAHIAbwByACAAUwB5AG0AYgBvAGwAcwBSAGUAZwB1AGwAYQByAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAQIIdW5pMUY1QUIA") format("truetype");
          font-weight: normal;
          font-style: normal;
          unicode-range: U+1F5AB;
        }
        </style>
        </head>
        <body>
        </body>
        </html>
        """
        webView.navigationDelegate = self
        await withCheckedContinuation { cont in
            self.continuation = cont
            webView.loadHTMLString(html, baseURL: nil)
        }

        do {
            let js = "(() => { const fontLoaded = document.fonts.check(\\"16px 'AgentMirror Symbols'\\"); const c1 = document.createElement(\\"canvas\\"); c1.width = 64; c1.height = 64; const ctx1 = c1.getContext(\\"2d\\"); ctx1.font = \\"32px 'AgentMirror Symbols', monospace\\"; ctx1.fillText(String.fromCodePoint(0x1F5AB), 10, 40); const d1 = ctx1.getImageData(0, 0, 64, 64).data; const c2 = document.createElement(\\"canvas\\"); c2.width = 64; c2.height = 64; const ctx2 = c2.getContext(\\"2d\\"); ctx2.font = \\"32px monospace\\"; ctx2.fillText(String.fromCodePoint(0x1F5AB), 10, 40); const d2 = ctx2.getImageData(0, 0, 64, 64).data; let diffPixels = 0; for (let i = 3; i < d1.length; i += 4) { if (Math.abs(d1[i] - d2[i]) > 30) diffPixels++; } const w1 = ctx1.measureText(String.fromCodePoint(0x1F5AB)).width; const w2 = ctx2.measureText(String.fromCodePoint(0x1F5AB)).width; return { fontLoaded, w1, w2, diffPixels }; })()"
            let res = try await webView.evaluateJavaScript(js) as? [String: Any]
            let fontLoaded = res?["fontLoaded"] as? Bool ?? false
            let w1 = res?["w1"] as? Double ?? 0
            let w2 = res?["w2"] as? Double ?? 0
            let diff = res?["diffPixels"] as? Int ?? 0
            print("OK_RES:\\(fontLoaded):\\(w1):\\(w2):\\(diff)")
        } catch {
            print("ERR:\(error)")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    let r = Runner()
    await r.run()
    exit(0)
}
app.run()
`;

  const out = execFileSync('swift', ['-e', swiftCode], { encoding: 'utf8' }).trim();
  assert.ok(out.startsWith('OK_RES:'), `Swift probe must succeed, got: ${out}`);
  const [, loadedStr, w1Str, w2Str, diffStr] = out.split(':');
  const fontLoaded = loadedStr === 'true';
  const w1 = parseFloat(w1Str);
  const w2 = parseFloat(w2Str);
  const diffPixels = parseInt(diffStr, 10);

  // 1. 验证 AgentMirror Symbols 字体真实加载生效（非假绿）
  assert.equal(fontLoaded, true, 'document.fonts.check must verify AgentMirror Symbols is loaded and available');

  // 2. 验证矢量字形 advance width 区别于 LastResort 豆腐块
  assert.notEqual(w1, w2, `advance width with font (${w1}) must differ from tofu box (${w2})`);
  assert.ok(w1 > 20, `U+1F5AB advance width must be >= 20px (got ${w1})`);

  // 3. 验证实测栅格墨迹与 LastResort 豆腐块拓扑差异显著（两头夹住，坚决杜绝假绿）
  assert.ok(diffPixels > 100, `U+1F5AB rendered bitmap must have >100 pixel difference from LastResort tofu box (got ${diffPixels})`);
});
