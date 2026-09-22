/**
 * Global Font Metrics Cache & Pure Mathematical Grid Projector (Issue #211 / Benchmark).
 *
 * Measures monospace font dimensions once and keeps them in an in-memory dictionary.
 * Subsequent grid fit calculations perform pure mathematical divisions (O(1)),
 * completely eliminating forced synchronous layout reads (Layout Thrashing) caused by
 * `element.getBoundingClientRect()`.
 */

const metricsCache = new Map();

/**
 * Build a canonical cache key for font typography.
 */
function cacheKey(fontFamily, fontSize, lineHeight) {
  return `${fontFamily}:${fontSize}:${lineHeight}`;
}

/**
 * Measure single character width and line height for a monospace font.
 * Uses OffscreenCanvas where available, falls back to DOM canvas, and finally to
 * standard deterministic monospace ratio (0.6 * fontSize).
 *
 * @param {Object} [opts]
 * @param {string} [opts.fontFamily]
 * @param {number} [opts.fontSize]
 * @param {number} [opts.lineHeight]
 * @returns {{ cellWidth: number, cellHeight: number, w: number, h: number }}
 */
export function getFontMetrics({
  fontFamily = 'ui-monospace, SF Mono, Menlo, monospace',
  fontSize = 13,
  lineHeight = 1.25,
} = {}) {
  const normFamily = typeof fontFamily === 'string' && fontFamily.trim() ? fontFamily.trim() : 'monospace';
  const normSize = Number.isFinite(fontSize) && fontSize > 0 ? Number(fontSize) : 13;
  const normLineHeight = Number.isFinite(lineHeight) && lineHeight > 0 ? Number(lineHeight) : 1.25;

  const key = cacheKey(normFamily, normSize, normLineHeight);
  const cached = metricsCache.get(key);
  if (cached) return cached;

  let measuredWidth = null;

  // 1. OffscreenCanvas (fastest, off-DOM, worker-safe)
  if (typeof OffscreenCanvas !== 'undefined') {
    try {
      const canvas = new OffscreenCanvas(200, 100);
      const ctx = canvas.getContext('2d');
      if (ctx) {
        ctx.font = `${normSize}px ${normFamily}`;
        const m = ctx.measureText('0123456789');
        if (m && m.width > 0) {
          measuredWidth = m.width / 10;
        }
      }
    } catch {}
  }

  // 2. DOM Canvas fallback
  if (!measuredWidth && typeof document !== 'undefined' && typeof document.createElement === 'function') {
    try {
      const canvas = document.createElement('canvas');
      const ctx = canvas.getContext('2d');
      if (ctx) {
        ctx.font = `${normSize}px ${normFamily}`;
        const m = ctx.measureText('0123456789');
        if (m && m.width > 0) {
          measuredWidth = m.width / 10;
        }
      }
    } catch {}
  }

  // 3. Deterministic standard monospace fallback
  const cellWidth = measuredWidth && Number.isFinite(measuredWidth) && measuredWidth > 0
    ? measuredWidth
    : normSize * 0.6;
  const cellHeight = Math.round(normSize * normLineHeight);

  const result = {
    cellWidth,
    cellHeight,
    w: cellWidth,
    h: cellHeight,
  };

  metricsCache.set(key, result);
  return result;
}

/**
 * Pure mathematical grid dimension calculation.
 * Computes exact target cols and rows without touching DOM geometry.
 *
 * @param {Object} params
 * @param {number} params.width - Container pixel width
 * @param {number} params.height - Container pixel height
 * @param {string} [params.fontFamily]
 * @param {number} [params.fontSize]
 * @param {number} [params.lineHeight]
 * @param {number} [params.paddingX] - Total horizontal padding in px
 * @param {number} [params.paddingY] - Total vertical padding in px
 * @returns {{ cols: number, rows: number, cellWidth: number, cellHeight: number }}
 */
export function computeGridDimensions({
  width,
  height,
  fontFamily,
  fontSize,
  lineHeight = 1.25,
  paddingX = 0,
  paddingY = 0,
} = {}) {
  const metrics = getFontMetrics({ fontFamily, fontSize, lineHeight });
  const usableWidth = Math.max(0, (Number(width) || 0) - paddingX);
  const usableHeight = Math.max(0, (Number(height) || 0) - paddingY);

  const cols = Math.max(2, Math.floor(usableWidth / metrics.cellWidth));
  const rows = Math.max(2, Math.floor(usableHeight / metrics.cellHeight));

  return {
    cols,
    rows,
    cellWidth: metrics.cellWidth,
    cellHeight: metrics.cellHeight,
  };
}

/**
 * Test helper: inject or clear cached font metrics.
 */
export function setCachedFontMetrics(keyOrMetrics, metrics) {
  if (typeof keyOrMetrics === 'string') {
    metricsCache.set(keyOrMetrics, metrics);
  } else if (keyOrMetrics && typeof keyOrMetrics === 'object') {
    const key = cacheKey(
      keyOrMetrics.fontFamily || 'monospace',
      keyOrMetrics.fontSize || 13,
      keyOrMetrics.lineHeight || 1.25,
    );
    metricsCache.set(key, { ...keyOrMetrics, w: keyOrMetrics.cellWidth, h: keyOrMetrics.cellHeight });
  }
}

export function clearFontMetricsCache() {
  metricsCache.clear();
}
