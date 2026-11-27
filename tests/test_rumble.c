/*
 * gip_rumble unit test over tests/fake_libusb.c, no hardware. GPL-2.0-or-later.
 * Checks NOT_READY before open and during the handshake, then the exact 0x09 packet once running.
 * Also checks that gip_stats_t.n_hello counts a second Hello (tests/unit/hello.txt).
 * Usage: tests/test_rumble <scratch dir>   (make test-core builds and runs it)
 */
#include "gipcore.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

/* Last "tx ..." line of the fake libusb log. */
static void last_tx(const char *log, char *out, size_t n) {
    FILE *f = fopen(log, "r"); char line[512]; out[0] = 0;
    if (!f) return;
    while (fgets(line, sizeof line, f)) if (!strncmp(line, "tx ", 3)) { line[strcspn(line, "\n")] = 0; snprintf(out, n, "%s", line); }
    fclose(f);
}

static gip_dev_t *open_dev(const char *init, const char *log) {
    setenv("FAKE_USB_TXLOG", log, 1);
    gip_config_t cfg; gip_config_default(&cfg); cfg.init = init;
    gip_dev_t *d = gip_new(&cfg, NULL);
    if (!d || gip_open(d) != GIP_OK) { printf("FAIL: open\n"); exit(1); }
    return d;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s <scratch dir>\n", argv[0]); return 2; }
    char log[1024], tx[512];
    snprintf(log, sizeof log, "%s/rumble-usb.log", argv[1]);
    setenv("FAKE_USB_SCRIPT", "tests/unit/rumble.txt", 1);

    /* init "none": Hello -> running with no Start/LED/rumble init packets. */
    gip_dev_t *d = open_dev("none", log);
    CHECK(gip_rumble(d, 0x0F, 1, 2, 3, 4, 5, 6, 7) == GIP_ERR_NOT_READY, "rumble before Hello must be NOT_READY");
    CHECK(gip_poll(d, 10) == GIP_OK, "poll Hello");
    CHECK(gip_rumble(d, 0x0F, 10, 20, 30, 40, 0xFF, 0x00, 0xEB) == GIP_OK, "rumble when running");
    last_tx(log, tx, sizeof tx);
    /* cmd 09, opts 00, seq 01 (first packet of the session), len 09, payload 00 + the 8 argument bytes */
    CHECK(!strcmp(tx, "tx 09 00 01 09 00 0f 0a 14 1e 28 ff 00 eb"), "rumble packet: got \"%s\"", tx);
    gip_close(d);
    CHECK(gip_rumble(d, 0x0F, 0, 0, 0, 0, 0, 0, 0) == GIP_ERR_NOT_READY, "rumble after close must be NOT_READY");
    gip_free(d);

    /* init "auth": the script is used up, so after 0.6 s without Hello the core starts the handshake
     * anyway; it never completes here. */
    d = open_dev("auth", log);
    for (int i = 0; i < 8; i++) CHECK(gip_poll(d, 100) == GIP_OK, "poll (auth)");
    last_tx(log, tx, sizeof tx);
    CHECK(!strncmp(tx, "tx 06 ", 6), "handshake must have started: got \"%s\"", tx);
    CHECK(gip_rumble(d, 0x0F, 0, 0, 0, 0, 0, 0, 0) == GIP_ERR_NOT_READY, "rumble during handshake must be NOT_READY");
    gip_free(d);

    /* n_hello: the second Hello does not restart the session, but is counted. */
    setenv("FAKE_USB_SCRIPT", "tests/unit/hello.txt", 1);
    d = open_dev("none", log);
    gip_stats_t st;
    gip_get_stats(d, &st);
    CHECK(st.n_hello == 0, "n_hello before any read: %d", st.n_hello);
    CHECK(gip_poll(d, 10) == GIP_OK, "poll Hello 1");
    gip_get_stats(d, &st);
    CHECK(st.n_hello == 1, "n_hello after first Hello: %d", st.n_hello);
    CHECK(gip_poll(d, 10) == GIP_OK && gip_poll(d, 10) == GIP_OK, "poll input + Hello 2");
    gip_get_stats(d, &st);
    CHECK(st.n_hello == 2 && st.n_input == 1, "after second Hello: n_hello %d, n_input %d", st.n_hello, st.n_input);
    CHECK(gip_rumble(d, 0x0F, 0, 0, 0, 0, 0, 0, 0) == GIP_OK, "second Hello must not reset the running session");
    gip_free(d);

    printf("%s test_rumble (%d failed checks)\n", fails ? "FAIL" : "PASS", fails);
    return fails != 0;
}
