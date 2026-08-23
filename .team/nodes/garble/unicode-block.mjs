/**
 * Unicode block labels for diagnostic codepoints only (no surrounding text).
 */
export function unicodeBlock(cp) {
  const ranges = [
    [0x0000, 0x007F, 'Basic Latin'],
    [0x0080, 0x00FF, 'Latin-1 Supplement'],
    [0x2000, 0x206F, 'General Punctuation'],
    [0x2190, 0x21FF, 'Arrows'],
    [0x2200, 0x22FF, 'Mathematical Operators'],
    [0x2300, 0x23FF, 'Miscellaneous Technical'],
    [0x2460, 0x24FF, 'Enclosed Alphanumerics'],
    [0x2500, 0x257F, 'Box Drawing'],
    [0x2580, 0x259F, 'Block Elements'],
    [0x25A0, 0x25FF, 'Geometric Shapes'],
    [0x2600, 0x26FF, 'Miscellaneous Symbols'],
    [0x2700, 0x27BF, 'Dingbats'],
    [0x2E80, 0x2EFF, 'CJK Radicals Supplement'],
    [0x3000, 0x303F, 'CJK Symbols and Punctuation'],
    [0x3040, 0x309F, 'Hiragana'],
    [0x30A0, 0x30FF, 'Katakana'],
    [0x4E00, 0x9FFF, 'CJK Unified Ideographs'],
    [0xAC00, 0xD7AF, 'Hangul Syllables'],
    [0xF900, 0xFAFF, 'CJK Compatibility Ideographs'],
    [0xFE00, 0xFE0F, 'Variation Selectors'],
    [0xFE10, 0xFE1F, 'Vertical Forms'],
    [0xFF00, 0xFFEF, 'Halfwidth and Fullwidth Forms'],
    [0x1F300, 0x1F5FF, 'Miscellaneous Symbols and Pictographs'],
    [0x1F600, 0x1F64F, 'Emoticons'],
    [0x1F680, 0x1F6FF, 'Transport and Map Symbols'],
    [0x1F900, 0x1F9FF, 'Supplemental Symbols and Pictographs'],
  ];
  for (const [a, b, name] of ranges) {
    if (cp >= a && cp <= b) return name;
  }
  return 'Other';
}

export function uPlus(cp) {
  return `U+${cp.toString(16).toUpperCase().padStart(4, '0')}`;
}
