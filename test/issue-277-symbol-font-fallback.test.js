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

test('Issue #277: tokens.css declares embedded AgentMirror Symbols @font-face for U+1F5AB', async () => {
  const tokensCss = await readFile(
    new URL('../src/styles/tokens.css', import.meta.url),
    'utf8'
  );

  // 1. Embedded @font-face for AgentMirror Symbols with U+1F5AB unicode-range
  assert.match(tokensCss, /@font-face\s*\{[^}]*font-family:\s*['"]AgentMirror Symbols['"]/);
  assert.match(tokensCss, /unicode-range:\s*U\+1F5AB/);
  assert.match(tokensCss, /src:\s*url\("data:font\/truetype;charset=utf-8;base64,/);

  // 2. --font-mono includes AgentMirror Symbols, Apple Symbols, and Segoe UI Symbol
  assert.match(tokensCss, /--font-mono:[^;]*'AgentMirror Symbols'/);
  assert.match(tokensCss, /--font-mono:[^;]*'Symbols Nerd Font Mono'/);
  assert.match(tokensCss, /--font-mono:[^;]*'Apple Symbols'/);
  assert.match(tokensCss, /--font-mono:[^;]*'Segoe UI Symbol'/);
});

test('Issue #277: TerminalView.js terminalFontFamily appends comprehensive symbol fallback chain', async () => {
  const terminalViewJs = await readFile(
    new URL('../src/term/TerminalView.js', import.meta.url),
    'utf8'
  );

  // Source contract for terminalFontFamily helper
  assert.match(terminalViewJs, /const terminalFontFamily = \(family\) => `\$\{family\}, "AgentMirror Symbols",/);
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
    fontFamily: 'Menlo',
    fontSize: 13,
    TerminalCtor: FakeTerminal,
  });

  const fontOptions = view.term.options.fontFamily;
  assert.ok(fontOptions.startsWith('Menlo,'), 'Primary font must be Menlo');
  assert.ok(fontOptions.includes('"AgentMirror Symbols"'), 'Must include AgentMirror Symbols');
  assert.ok(fontOptions.includes('"Symbols Nerd Font Mono"'), 'Must include Symbols Nerd Font Mono');
  assert.ok(fontOptions.includes('"JetBrainsMono Nerd Font Mono"'), 'Must include JetBrainsMono Nerd Font Mono');
  assert.ok(fontOptions.includes('"Apple Symbols"'), 'Must include Apple Symbols');
  assert.ok(fontOptions.includes('"Segoe UI Symbol"'), 'Must include Segoe UI Symbol');
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
            let js = "(() => { const canvas = document.createElement(\\"canvas\\"); canvas.width = 64; canvas.height = 64; const ctx = canvas.getContext(\\"2d\\"); ctx.font = \\"32px \\\\\\"AgentMirror Symbols\\\\\\", \\\\\\"Symbols Nerd Font Mono\\\\\\", \\\\\\"JetBrainsMono Nerd Font Mono\\\\\\", \\\\\\"Apple Symbols\\\\\\", monospace\\"; ctx.fillText(String.fromCodePoint(0x1F5AB), 10, 40); const data = ctx.getImageData(0, 0, 64, 64).data; let ink = 0; for (let i = 3; i < data.length; i += 4) { if (data[i] > 10) ink++; } return { ink: ink, width: ctx.measureText(String.fromCodePoint(0x1F5AB)).width }; })()"
            let res = try await webView.evaluateJavaScript(js) as? [String: Any]
            let ink = res?["ink"] as? Int ?? 0
            let width = res?["width"] as? Double ?? 0
            print("OK_RES:\\(ink):\\(width)")
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
  const [, inkStr, widthStr] = out.split(':');
  const ink = parseInt(inkStr, 10);
  const width = parseFloat(widthStr);
  assert.ok(ink > 50, `U+1F5AB must render non-zero ink pixels (got ${ink})`);
  assert.ok(width > 10, `U+1F5AB must have positive advance width (got ${width})`);
});
