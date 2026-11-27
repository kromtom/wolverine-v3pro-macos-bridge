/*
 * giptool - userspace Microsoft GIP (Xbox One protocol) reader for macOS via libusb.
 * Target: Razer Wolverine V3 Pro (1532:0a3f, Xbox mode), works for any class FF/47/D0 interface.
 * Thin CLI over src/core/gipcore (protocol, host sequence, decoding), for debugging the pad.
 *
 * Usage: giptool [--raw] [--json] [--seconds N] [--init meta,power,led,auth,rumble] [--vid 0x1532] [--pid 0x0a3f]
 */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>
#include "core/gipcore.h"

static volatile sig_atomic_t stop = 0;
static void on_sigint(int s) { (void)s; stop = 1; }

static int opt_raw = 0, opt_json = 0;
static double opt_seconds = 0;

static double now_s(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec / 1e9; }

static void hexdump(const char *tag, const uint8_t *b, int n) {
    printf("%s (%d):", tag, n);
    for (int i = 0; i < n; i++) printf(" %02x", b[i]);
    printf("\n"); fflush(stdout);
}

static const char *btn_names_lo[8] = { "?", "KEEPALIVE", "MENU", "VIEW", "A", "B", "X", "Y" };
static const char *btn_names_hi[8] = { "DU", "DD", "DL", "DR", "LB", "RB", "LS", "RS" };

static void print_state(const gip_state_t *s, const char *kind) {
    uint8_t lo = s->buttons & 0xff, hi = s->buttons >> 8;
    if (opt_json) {
        printf("{\"kind\":\"%s\",\"lx\":%d,\"ly\":%d,\"rx\":%d,\"ry\":%d,\"lt\":%u,\"rt\":%u,"
               "\"a\":%d,\"b\":%d,\"x\":%d,\"y\":%d,\"lb\":%d,\"rb\":%d,\"ls\":%d,\"rs\":%d,"
               "\"menu\":%d,\"view\":%d,\"guide\":%d,\"du\":%d,\"dd\":%d,\"dl\":%d,\"dr\":%d}\n",
               kind, s->lx, s->ly, s->rx, s->ry, s->lt, s->rt,
               !!(lo&0x10), !!(lo&0x20), !!(lo&0x40), !!(lo&0x80),
               !!(hi&0x10), !!(hi&0x20), !!(hi&0x40), !!(hi&0x80),
               !!(lo&0x04), !!(lo&0x08), s->guide,
               !!(hi&0x01), !!(hi&0x02), !!(hi&0x04), !!(hi&0x08));
        fflush(stdout); return;
    }
    if (opt_raw) return;
    printf("\033[H\033[J");
    printf("Razer Wolverine V3 Pro  (GIP over libusb)   Ctrl-C to quit\n\n");
    printf("LX: %6d    LY: %6d\n", s->lx, s->ly);
    printf("RX: %6d    RY: %6d\n", s->rx, s->ry);
    printf("LT: %4u/1023  RT: %4u/1023\n\n", s->lt, s->rt);
    printf("A: %d  B: %d  X: %d  Y: %d\n", !!(lo&0x10), !!(lo&0x20), !!(lo&0x40), !!(lo&0x80));
    printf("LB: %d RB: %d LS: %d RS: %d\n", !!(hi&0x10), !!(hi&0x20), !!(hi&0x40), !!(hi&0x80));
    printf("D-pad U: %d D: %d L: %d R: %d\n", !!(hi&0x01), !!(hi&0x02), !!(hi&0x04), !!(hi&0x08));
    printf("Menu: %d View: %d Guide: %d\n", !!(lo&0x04), !!(lo&0x08), s->guide);
    printf("\nraw buttons: 0x%04x  [", s->buttons);
    for (int i = 0; i < 8; i++) if (lo & (1 << i)) printf(" %s", btn_names_lo[i]);
    for (int i = 0; i < 8; i++) if (hi & (1 << i)) printf(" %s", btn_names_hi[i]);
    printf(" ]\n"); fflush(stdout);
}

static void cb_state(void *user, gip_event_t ev, const gip_state_t *s, const uint8_t *extra, int extra_len) {
    (void)user;
    if (ev == GIP_EVENT_INPUT) {
        print_state(s, "input");
        if (extra_len > 0 && !opt_json && !opt_raw) hexdump("extra payload bytes", extra, extra_len);
    } else if (!opt_raw) print_state(s, "guide");   /* --raw: the core already traced the packet */
}
static void cb_log(void *user, const char *line) { (void)user; fprintf(stderr, "%s\n", line); }
static void cb_trace(void *user, const char *line) { (void)user; printf("%s\n", line); fflush(stdout); }
static void cb_metadata(void *user, const uint8_t *data, int len) { (void)user; if (!opt_json) hexdump("METADATA", data, len); }
static void cb_packet(void *user, uint8_t cmd, const uint8_t *pkt, int len) {
    (void)user;
    if (opt_raw || !opt_json) { char tag[32]; snprintf(tag, sizeof tag, "RX cmd 0x%02x", cmd); if (!opt_raw) printf("\n"); hexdump(tag, pkt, len); }
}

int main(int argc, char **argv) {
    gip_config_t cfg; gip_config_default(&cfg);
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--raw")) opt_raw = 1;
        else if (!strcmp(argv[i], "--json")) opt_json = 1;
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) opt_seconds = atof(argv[++i]);
        else if (!strcmp(argv[i], "--vid") && i + 1 < argc) cfg.vid = (int)strtol(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--pid") && i + 1 < argc) cfg.pid = (int)strtol(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--init") && i + 1 < argc) cfg.init = argv[++i];
        else if (!strcmp(argv[i], "--restart")) cfg.restart = 1;
        else if (!strcmp(argv[i], "--serial")) cfg.serial = 1;
        else if (!strcmp(argv[i], "--query")) cfg.query = 1;
        else { fprintf(stderr, "usage: %s [--raw] [--json] [--seconds N] [--init meta,power,led,auth,rumble|none] [--vid 0x1532] [--pid 0x0a3f]\n", argv[0]); return 2; }
    }
    cfg.trace = opt_raw;
    signal(SIGINT, on_sigint);

    const gip_callbacks_t cb = { .on_state = cb_state, .on_log = cb_log, .on_trace = cb_trace,
                                 .on_metadata = cb_metadata, .on_packet = cb_packet };
    gip_dev_t *dev = gip_new(&cfg, &cb);
    if (!dev) { fprintf(stderr, "libusb_init failed\n"); return 1; }
    if (gip_open(dev) != GIP_OK) { fprintf(stderr, "device %04x:%04x not found / could not open\n", cfg.vid, cfg.pid); gip_free(dev); return 1; }

    double t0 = now_s();
    if (!opt_json && !opt_raw) { gip_state_t st = {0}; print_state(&st, "input"); }

    while (!stop) {
        if (opt_seconds > 0 && now_s() - t0 > opt_seconds) break;
        if (gip_poll(dev, 100) == GIP_OK) continue;
        /* GIP_ERR_LOST: the core logged "device lost" and closed the handle; reopen every 500 ms. */
        while (!stop && !gip_is_open(dev) && (opt_seconds <= 0 || now_s() - t0 < opt_seconds)) { usleep(500000); gip_open(dev); }
        if (!gip_is_open(dev)) break;
    }
    gip_stats_t s; gip_get_stats(dev, &s);
    fprintf(stderr, "\nreceived %d input reports, %d other packets in %.1fs (metadata %s, auth %s)\n", s.n_input, s.n_other, now_s() - t0, s.metadata_ok ? "ok" : "not received", s.auth ? s.auth : "not attempted");
    gip_free(dev);
    return 0;
}
