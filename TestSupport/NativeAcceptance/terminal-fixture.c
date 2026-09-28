#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <errno.h>
#include <string.h>
#include <poll.h>

// A real PTY endpoint: all input receipts come from read(STDIN_FILENO), never the client or proxy.
int main(int argc, char **argv) {
    if (argc != 4 && argc != 5) return 2;
    int busy = argc == 5 && !strcmp(argv[4], "busy");
    int empty = argc == 5 && !strcmp(argv[4], "empty");
    struct termios original, raw;
    if (tcgetattr(STDIN_FILENO, &original)) return 3;
    raw = original;
    cfmakeraw(&raw);
    if (tcsetattr(STDIN_FILENO, TCSANOW, &raw)) return 4;
    int log = open(argv[3], O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (log < 0) return 5;
    printf("\033[2J\033[H\033]2;ACCEPT-%s-%s\007", argv[1], argv[2]);
    for (int line = 0; !empty && line < 24; line++) {
        printf("\033[38;2;213;220;230m%s/%s %02d | Corral Native 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ\r\n", argv[1], argv[2], line);
    }
    if (!empty) printf("中文 日本語 한국어 😀 👩‍💻 | READY-%s-%s\033[0m\r\n", argv[1], argv[2]);
    fflush(stdout);
    unsigned char buffer[4096];
    unsigned long sequence = 0;
    for (;;) {
        struct pollfd input = { .fd = STDIN_FILENO, .events = POLLIN };
        int ready = poll(&input, 1, busy ? 10 : -1);
        if (ready < 0) { if (errno == EINTR) continue; break; }
        if (ready == 0) {
            // Sustained real PTY output, including while a preview is abandoned.
            for (int line = 0; line < 8; line++)
                printf("%s/%s LIVE-%08lu 0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ\r\n", argv[1], argv[2], sequence++);
            fflush(stdout);
            continue;
        }
        ssize_t count = read(STDIN_FILENO, buffer, sizeof(buffer));
        if (count <= 0) { if (errno == EINTR) continue; break; }
        for (ssize_t offset = 0; offset < count;) {
            ssize_t written = write(log, buffer + offset, (size_t)(count - offset));
            if (written <= 0) return 6;
            offset += written;
        }
        fsync(log);
        // Test-controlled mode toggle travels through the same PTY input as every key.
        if (memmem(buffer, (size_t)count, "MOUSE-ON", 8)) printf("\033[?1000h\033[?1006h");
        if (memmem(buffer, (size_t)count, "MOUSE-OFF", 9)) printf("\033[?1000l\033[?1006l");
        printf("\r\n%s/%s ECHO-%s:", argv[1], argv[2], argv[1]);
        for (ssize_t i = 0; i < count; i++) printf("%02x", buffer[i]);
        printf("\r\n");
        fflush(stdout);
    }
    tcsetattr(STDIN_FILENO, TCSANOW, &original);
    close(log);
    return 0;
}
