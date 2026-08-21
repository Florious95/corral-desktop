/*
 * 历史面板的 ANSI → 片段解析（只解 SGR 颜色/加粗，其余 ESC 序列吞掉）。
 * 参照 web 版 app.js 的 renderAnsi()，但返回结构化片段而不是 HTML 字符串 ——
 * React 渲染片段天然转义，不需要 dangerouslySetInnerHTML，也就没有转义遗漏的可能。
 * ⛔ 只用于只读历史面板；活的 xterm 网格永远是原始字节直喂。
 */

// 亮色主题下的 8 色/亮 8 色（比终端默认色调暗一档，保证在 #fbfaf8 上可读）。
const COLORS = ['#3a3835', '#c0392b', '#3f7a4c', '#a4542e', '#3b6ea5', '#8054a8', '#2b7a78', '#6d6a63'];
const BRIGHT = ['#6d6a63', '#d64b3a', '#4f9660', '#b08a1e', '#4f86c6', '#9a6ac0', '#3a938f', '#8a867e'];

/**
 * @param {string} text 含 ANSI 转义的历史文本
 * @returns {Array<{text:string, fg:string|null, bg:string|null, bold:boolean}>}
 */
export function parseAnsi(text) {
  const out = [];
  let fg = null;
  let bg = null;
  let bold = false;
  let buf = '';
  let i = 0;
  const flush = () => {
    if (buf) { out.push({ text: buf, fg, bg, bold }); buf = ''; }
  };
  while (i < text.length) {
    if (text[i] === '\x1b' && text[i + 1] === '[') {
      let j = i + 2;
      while (j < text.length && !'m@HKABCDJ'.includes(text[j])) j++;
      if (j < text.length && text[j] === 'm') {
        flush();
        const codes = text.slice(i + 2, j).split(';').map((c) => parseInt(c, 10));
        for (const c of codes) {
          if (!Number.isFinite(c) || c === 0) { fg = null; bg = null; bold = false; }
          else if (c === 1) bold = true;
          else if (c === 22) bold = false;
          else if (c === 39) fg = null;
          else if (c === 49) bg = null;
          else if (c >= 30 && c <= 37) fg = COLORS[c - 30];
          else if (c >= 90 && c <= 97) fg = BRIGHT[c - 90];
          else if (c >= 40 && c <= 47) bg = COLORS[c - 40];
          else if (c >= 100 && c <= 107) bg = BRIGHT[c - 100];
        }
      }
      i = j + 1;
    } else if (text[i] === '\x1b') {
      i += 2; // 非颜色 ESC 序列在只读视图里不可见
    } else {
      buf += text[i];
      i++;
    }
  }
  flush();
  return out;
}
