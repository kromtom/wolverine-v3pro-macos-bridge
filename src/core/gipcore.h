/*
 * gipcore - reusable host side of the Microsoft GIP (Xbox One) protocol over libusb.
 * Target: Razer Wolverine V3 Pro (1532:0a3f, Xbox mode); works for any class FF/47/D0 interface.
 * License: GPL-2.0-or-later (links gipauth.c, ported from medusalix/xone).
 *
 * Usage (single thread; none of these functions are thread-safe):
 *
 *   gip_config_t cfg; gip_config_default(&cfg);
 *   gip_dev_t *d = gip_new(&cfg, &callbacks);      // NULL: libusb init failed
 *   if (gip_open(d) == GIP_OK)
 *       while (running && gip_poll(d, 100) == GIP_OK) {}
 *   // GIP_ERR_LOST: handle already closed; caller decides whether to gip_open() again
 *   gip_free(d);
 *
 * gip_poll runs the host init sequence (Hello -> Metadata -> security handshake -> Start/LED/rumble),
 * ACKs packets, and reports decoded 0x20 input and 0x07 Guide state through on_state.
 * State, counters and the --init string persist across gip_close/gip_open (reconnect).
 */
#pragma once
#include <stdint.h>

enum {
    GIP_OK            =  0,
    GIP_ERR_NOT_FOUND = -1,   /* no device with vid:pid, or open failed (silent) */
    GIP_ERR_NO_IFACE  = -2,   /* no FF/47/D0 interface with 2 interrupt endpoints (logged) */
    GIP_ERR_CLAIM     = -3,   /* claim_interface failed (logged) */
    GIP_ERR_LOST      = -4,   /* read error; device closed (logged) */
    GIP_ERR_NOT_READY = -5,   /* gip_rumble: device closed, or host sequence/handshake not finished */
    GIP_ERR_TX        = -6,   /* gip_rumble: OUT transfer failed (traced via on_trace) */
};

/* Bits of gip_state_t.buttons (0x20 payload bytes 0..1, little endian). */
#define GIP_BTN_MENU 0x0004
#define GIP_BTN_VIEW 0x0008
#define GIP_BTN_A    0x0010
#define GIP_BTN_B    0x0020
#define GIP_BTN_X    0x0040
#define GIP_BTN_Y    0x0080
#define GIP_BTN_DU   0x0100
#define GIP_BTN_DD   0x0200
#define GIP_BTN_DL   0x0400
#define GIP_BTN_DR   0x0800
#define GIP_BTN_LB   0x1000
#define GIP_BTN_RB   0x2000
#define GIP_BTN_LS   0x4000
#define GIP_BTN_RS   0x8000

typedef struct {
    int16_t lx, ly, rx, ry;   /* Y up positive */
    uint16_t lt, rt;          /* 0..1023 */
    uint16_t buttons;         /* GIP_BTN_*, keep-alive bit cleared */
    int guide;                /* 0x07 payload bits 0..1 */
} gip_state_t;

typedef enum { GIP_EVENT_INPUT, GIP_EVENT_GUIDE } gip_event_t;

/* Every callback is optional. Lines carry no trailing newline. Pointers are valid only during the call. */
typedef struct {
    void *user;
    /* Input report (extra = payload bytes after the first 14) or Guide change. */
    void (*on_state)(void *user, gip_event_t ev, const gip_state_t *s, const uint8_t *extra, int extra_len);
    /* Status line (giptool writes it to stderr). gipauth.c still
     * writes its own "auth: ..." lines directly to stderr. */
    void (*on_log)(void *user, const char *line);
    /* Packet trace: every RX/TX when cfg.trace is set, failed TX always (giptool writes it to stdout). */
    void (*on_trace)(void *user, const char *line);
    /* Reassembled metadata response. */
    void (*on_metadata)(void *user, const uint8_t *data, int len);
    /* Complete packet with a command the core does not handle (already ACKed if requested). */
    void (*on_packet)(void *user, uint8_t cmd, const uint8_t *pkt, int len);
} gip_callbacks_t;

typedef struct {
    int vid, pid;          /* default 0x1532:0x0a3f */
    const char *init;      /* comma list: meta,power,led,auth,rumble (default), authdone, sdl, none.
                            * Must stay valid for the lifetime of the gip_dev_t. */
    int trace;             /* trace every packet (giptool --raw) */
    int restart;           /* 0.4 s after start: Set Device State Stop, then Start */
    int serial;            /* 0.4 s after start: send serial number request */
    int query;             /* 0.4 s after start: Razer vendor diagnostic state query (read-only) */
} gip_config_t;

typedef struct {
    int n_input, n_other;  /* totals across reconnects */
    int n_hello;           /* Hello (0x02) packets received, total across reconnects. The core acts only on
                            * the first one per session; a later one can mean the pad reconnected to the
                            * receiver and needs a new session (gip_close + gip_open). */
    int metadata_ok;       /* metadata received in the current/last session */
    const char *auth;      /* gip_auth_state_name of the current/last handshake, NULL if not attempted */
} gip_stats_t;

typedef struct gip_dev gip_dev_t;

void gip_config_default(gip_config_t *cfg);
gip_dev_t *gip_new(const gip_config_t *cfg, const gip_callbacks_t *cb);
void gip_free(gip_dev_t *d);                 /* closes the device if open */
int gip_open(gip_dev_t *d);                  /* GIP_OK or GIP_ERR_*; starts the host sequence */
int gip_is_open(const gip_dev_t *d);
int gip_poll(gip_dev_t *d, int timeout_ms);  /* one read (blocks up to timeout_ms) plus timers */
void gip_close(gip_dev_t *d);                /* release + close; macOS then re-enumerates the pad (~2 s) */
void gip_get_state(const gip_dev_t *d, gip_state_t *out);
/* Send a GIP 0x09 rumble command. Byte order matches the payload of Xbox Bluetooth output report 3:
 * mask = motor enable bits (0x01 right/weak, 0x02 left/strong, 0x04 right trigger, 0x08 left trigger),
 * magnitudes 0..100, duration/delay in 10 ms units, repeat = loop count.
 * Call on the gip_poll thread. Returns GIP_OK, GIP_ERR_NOT_READY, or GIP_ERR_TX. */
int gip_rumble(gip_dev_t *d, uint8_t mask, uint8_t lt, uint8_t rt, uint8_t strong, uint8_t weak,
               uint8_t duration, uint8_t delay, uint8_t repeat);
void gip_get_stats(const gip_dev_t *d, gip_stats_t *out);
