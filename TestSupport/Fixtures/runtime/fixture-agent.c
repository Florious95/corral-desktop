#include <stdio.h>
#include <string.h>
#include <time.h>

static void pause_ms(long ms) {
    struct timespec ts = { .tv_sec = ms / 1000, .tv_nsec = (ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

static void hold(void) {
    for (;;) pause_ms(1000);
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "static";
    if (strcmp(mode, "static") == 0) {
        printf("\033]2;fixture-static-long-text\007");
        for (int i = 1; i <= 60; i++) printf("STATIC-LINE-%02d | Corral Native isolated fixture | 9919\n", i);
    } else if (strcmp(mode, "ansi") == 0) {
        printf("\033]2;fixture-ansi-color\007");
        printf("\033[38;5;196mANSI-256-RED\033[0m\n");
        printf("\033[48;2;12;34;56mTRUECOLOR-12-34-56\033[0m\n");
        printf("\033[1;38;5;201mANSI-256-MAGENTA-BOLD\033[0m\n");
    } else if (strcmp(mode, "unicode") == 0) {
        printf("\033]2;fixture-cjk-emoji\007");
        printf("CJK: 中文简体 / 繁體中文 / 日本語 / 한국어\n");
        printf("Emoji: 😀 🧪 🛰️  ZWJ: 👩‍💻 👨‍👩‍👧‍👦 🏳️‍🌈\n");
    } else if (strcmp(mode, "stream") == 0) {
        printf("\033]2;fixture-streaming-output\007");
        unsigned long i = 0;
        for (;;) {
            printf("\033[32mSTREAM-%08lu\033[0m | 流式输出 | 🚀\n", ++i);
            fflush(stdout);
            pause_ms(250);
        }
    } else if (strcmp(mode, "split-left") == 0) {
        printf("\033]2;fixture-split-left\007SPLIT-WORKSPACE LEFT | pane A\n");
    } else if (strcmp(mode, "split-right") == 0) {
        printf("\033]2;fixture-split-right\007SPLIT-WORKSPACE RIGHT | pane B\n");
    }
    fflush(stdout);
    hold();
}
