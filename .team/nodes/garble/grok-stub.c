/* Named "grok" so agentmirrord's provider whitelist lists this pane.
 * Echoes stdin (tmux send-keys) and stays alive. Not a real Agent CLI.
 */
#include <unistd.h>

int main(void) {
  char buf[4096];
  ssize_t n;
  while ((n = read(0, buf, sizeof buf)) > 0) {
    if (write(1, buf, (size_t)n) < 0) return 1;
  }
  pause();
  return 0;
}
