/* Isolated probe TUI: basename must be a provider whitelist comm (`grok`). */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

static char buf[4096];
static int n;
static FILE *logf;

static void redraw(void) {
	fputs("\r\033[2K> ", stdout);
	fwrite(buf, 1, (size_t)n, stdout);
	fflush(stdout);
}

static void onwinch(int s) {
	(void)s;
	n = 0;
	redraw();
}

int main(int argc, char **argv) {
	struct termios oldt, raw;
	if (argc < 2) return 1;
	logf = fopen(argv[1], "a");
	if (!logf) return 1;
	signal(SIGWINCH, onwinch);
	if (tcgetattr(0, &oldt) != 0) return 1;
	raw = oldt;
	cfmakeraw(&raw);
	raw.c_lflag |= ISIG;
	if (tcsetattr(0, TCSANOW, &raw) != 0) return 1;
	redraw();
	for (;;) {
		char c;
		if (read(0, &c, 1) != 1) break;
		if (c == '\n' || c == '\r') {
			buf[n] = 0;
			if (n > 0) {
				fprintf(logf, "GOT:%s\n", buf);
				fflush(logf);
				fprintf(stdout, "\nGOT:%s\n", buf);
			}
			n = 0;
			redraw();
		} else if ((c == 127 || c == 8) && n > 0) {
			n--;
			redraw();
		} else if (c >= 32 && n < (int)sizeof(buf) - 1) {
			buf[n++] = c;
			redraw();
		}
	}
	tcsetattr(0, TCSANOW, &oldt);
	fclose(logf);
	return 0;
}
