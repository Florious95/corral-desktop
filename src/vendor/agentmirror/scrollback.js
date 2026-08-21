/*
 * AgentMirror web client — scrollback fetch + display.
 *
 * Local scrolling (requirement 006) is an explicit "load older history" action:
 * the button computes a range in tmux capture-pane semantics (0 = current
 * screen top, negative = history above it), sends a scrollback frame, and
 * renders the reply (a binary kind=3 frame carrying a 12-byte header with the
 * ACTUAL converged range + ANSI bytes) as a one-page buffer above the live
 * xterm pane. The live grid keeps following the bottom — history is a separate,
 * non-invasive view (008 state/mirror decoupling has no bearing here, this is
 * purely the mirror channel).
 */

/**
 * Requests the next older history page for a mounted session view.
 * @contract
 * @pre builder returns a view with terminal, client, and session ref, or a falsy value
 * @post successful send records pending reqId/count; falsy view is a no-op
 * @err unsent requests call onError; transport exceptions propagate
 * @inv at most one request record is created per invocation
 */
export function fetchOlder(builder, { onLoading, onError } = {}) {
  const g = builder();
  if (!g) return;
  const rows = g.term.rows;
  const historyLines = Math.max(50, rows * 2);
  const fromLine = Number.isInteger(g.nextScrollbackLine) ? g.nextScrollbackLine : -historyLines;
  const count = historyLines;
  if (onLoading) onLoading(count);
  const reqId = g.client.scrollback(g.ref, fromLine, count);
  if (reqId === null) {
    if (onError) onError('scrollback not sent (connection not ready)');
    return;
  }
  g.pendingScrollback = { reqId, count };
}

/**
 * Applies a matching scrollback reply to the requesting session view.
 * @contract
 * @pre frame is a decoded scrollback frame and g may hold one pending request
 * @post matching replies clear pending state, advance the cursor, and render the page
 * @err none; stale or unrelated replies are ignored
 * @inv a reply never writes into the live terminal grid
 */
export function acceptScrollback(g, frame) {
  if (!g.pendingScrollback || frame.reqId !== g.pendingScrollback.reqId) return;
  g.pendingScrollback = null;
  const { fromLine, lineCount, data } = frame;
  g.nextScrollbackLine = fromLine - lineCount;
  // Render into a small fixed buffer above the live terminal.
  g.showScrollbackPanel(fromLine, lineCount, data);
}
