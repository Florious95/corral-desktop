/*
 * Fake Agent TUI named "grok" (provider whitelist).
 * Redraws on SIGWINCH from TIOCGWINSZ.
 * AM_TUI_WIDE_AS_1=1 → treat CJK as 1 column (破坏齿).
 * Default → CJK is 2 columns.
 * Box drawing + CJK on the inner width boundary.
 * Not a real Agent CLI. No secrets.
 */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static volatile sig_atomic_t got_winch = 0;
static int wide_as_1 = 0;

static void on_winch(int sig) {
  (void)sig;
  got_winch = 1;
}

static void put_utf8(const char *s) {
  fputs(s, stdout);
}

static int winsize(int *cols, int *rows) {
  struct winsize ws;
  if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) != 0 || ws.ws_col < 4 || ws.ws_row < 3) {
    *cols = 80;
    *rows = 24;
    return -1;
  }
  *cols = (int)ws.ws_col;
  *rows = (int)ws.ws_row;
  return 0;
}

/* Inner payload: fake-width == inner. Wrong algo → real displayWidth inner+1. */
static void put_payload(int inner) {
  int i;
  if (inner < 2) {
    for (i = 0; i < inner; i++) putchar('x');
    return;
  }
  if (wide_as_1) {
    /* (inner-1) ASCII + CJK; fake=inner, real=inner+1 */
    for (i = 0; i < inner - 1; i++) putchar('x');
    put_utf8("中");
  } else {
    /* (inner-2) ASCII + CJK; fake=inner, real=inner */
    for (i = 0; i < inner - 2; i++) putchar('x');
    put_utf8("中");
  }
}

static void draw(void) {
  int cols = 80, rows = 24, r, i, inner;
  winsize(&cols, &rows);
  inner = cols - 2;
  /* Grid paint only (\\r\\n). CUP is omitted: capture-pane -e may keep
   * host CUP that would cup_clamp against the 39-row client grid and
   * paint both E and F red, hiding the width-algorithm tooth. */
  fputs("\x1b[2J\x1b[H", stdout);
  put_utf8("┌");
  for (i = 0; i < inner; i++) put_utf8("─");
  put_utf8("┐");
  fputs("\r\n", stdout);
  put_utf8("│");
  put_payload(inner);
  put_utf8("│");
  fputs("\r\n", stdout);
  for (r = 3; r < rows; r++) {
    put_utf8("│");
    for (i = 0; i < inner; i++) putchar(' ');
    put_utf8("│");
    fputs("\r\n", stdout);
  }
  put_utf8("└");
  for (i = 0; i < inner; i++) put_utf8("─");
  put_utf8("┘");
  fflush(stdout);
}

int main(void) {
  const char *env = getenv("AM_TUI_WIDE_AS_1");
  wide_as_1 = env && env[0] == '1';
  signal(SIGWINCH, on_winch);
  draw();
  for (;;) {
    pause();
    if (got_winch) {
      got_winch = 0;
      draw();
    }
  }
  return 0;
}
