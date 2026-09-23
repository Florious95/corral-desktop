export const AGENT_ROW_HEIGHT = 34;
export const AGENT_OVERSCAN = 4;

export function visibleWindow(total, scrollTop, viewportHeight) {
  const count = Math.max(0, Number.isFinite(total) ? Math.floor(total) : 0);
  const top = Math.max(0, Number.isFinite(scrollTop) ? scrollTop : 0);
  const height = Math.max(AGENT_ROW_HEIGHT, Number.isFinite(viewportHeight) ? viewportHeight : AGENT_ROW_HEIGHT);
  const first = Math.floor(top / AGENT_ROW_HEIGHT);
  const start = Math.max(0, first - AGENT_OVERSCAN);
  const maxItems = Math.ceil(height / AGENT_ROW_HEIGHT) + (AGENT_OVERSCAN * 2);
  const visibleEnd = Math.min(count, Math.ceil((top + height) / AGENT_ROW_HEIGHT) + AGENT_OVERSCAN);
  const end = Math.min(visibleEnd, start + maxItems);
  return { start, end };
}

export function sortAgents(agents) {
  return [...agents].sort((a, b) => (b.fav ? 1 : 0) - (a.fav ? 1 : 0));
}
