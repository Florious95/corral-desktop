import qrcode from 'qrcode-generator';

/**
 * Generate a QR matrix for React/SVG rendering. The dependency is a tiny
 * browser-side encoder; no canvas, image URL, or HTML injection is needed.
 */
export function createQrMatrix(text) {
  if (typeof text !== 'string' || text.length === 0) return null;
  const code = qrcode(0, 'M');
  code.addData(text, 'Byte');
  code.make();
  const size = code.getModuleCount();
  const modules = Array.from({ length: size }, (_, row) => (
    Array.from({ length: size }, (_, col) => code.isDark(row, col))
  ));
  return { size, modules };
}
