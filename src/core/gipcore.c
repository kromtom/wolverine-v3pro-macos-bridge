/*
 * gipcore - host side of the Microsoft GIP (Xbox One) protocol over libusb. See gipcore.h.
 *
 * References: MS-GIPUSB (Microsoft open spec, 2024), Linux xpad.c, SDL SDL_hidapi_xboxone.c, medusalix/xone.
 *
 * Host sequence implemented (spec 1.3.1): Hello <- device; Metadata Request -> ; fragmented Metadata
 * Response <- (ACKed); security handshake (0x06, gipauth.c) <-> ; Set Device State: Start -> ; LED -> ;
 * rumble init -> ; then Gamepad Input Reports (0x20) <- and Guide button (0x07) <-, ACKing anything flagged ACME.
 *
 * License: GPL-2.0-or-later.
 */
#include "gipcore.h"
#include "gipauth.h"
#include <libusb.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define GIP_CMD_ACK        0x01
#define GIP_CMD_HELLO      0x02
#define GIP_CMD_STATUS     0x03
#define GIP_CMD_METADATA   0x04
#define GIP_CMD_STATE      0x05
#define GIP_CMD_AUTH       0x06
#define GIP_CMD_GUIDE      0x07
#define GIP_CMD_RUMBLE     0x09
#define GIP_CMD_LED        0x0A
#define GIP_CMD_INPUT      0x20

#define GIP_OPT_ACK        0x10   /* ACME: acknowledge me */
#define GIP_OPT_INTERNAL   0x20   /* system message */
#define GIP_OPT_CHUNK_START 0x40
#define GIP_OPT_CHUNK      0x80

#define GIP_PKT_MAX 58

typedef struct {
    uint8_t cmd, opts, seq;
    uint32_t len;          /* payload length of this packet/fragment */
    uint32_t chunk_offset; /* fragment offset; for the first fragment = total message length */
    int hdr_len;
} gip_hdr_t;

enum { ST_WAIT_HELLO, ST_META, ST_RUNNING };

struct gip_dev {
    gip_config_t cfg;
    gip_callbacks_t cb;
    const char *init;      /* current init string; "sdl" mode rewrites it (persists across reconnects) */
    libusb_context *ctx;
    libusb_device_handle *h;
    int iface;
    uint8_t ep_in, ep_out;
    uint8_t seq;
    int state;
    double t_open, t_last_req, t_started;
    int post_done, meta_retries, auth_started;
    gip_state_t st;
    int n_input, n_other, n_hello;
    /* metadata reassembly */
    uint8_t *meta_buf; uint32_t meta_total, meta_received; int meta_done;
    /* generic chunked receive (one message at a time) */
    uint8_t rx_cmd; uint8_t *rx_buf; uint32_t rx_total, rx_received;
    /* chunked send state (xone gip_send_pkt semantics) */
    struct { int active; uint8_t cmd, opts, seq; uint8_t *data; uint32_t total; } tx;
    gip_auth_t *auth;
};

static double now_s(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec / 1e9; }

static void logf_(gip_dev_t *d, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void logf_(gip_dev_t *d, const char *fmt, ...) {
    if (!d->cb.on_log) return;
    char line[512];
    va_list ap; va_start(ap, fmt); vsnprintf(line, sizeof line, fmt, ap); va_end(ap);
    d->cb.on_log(d->cb.user, line);
}

/* "<tag> (<n>): xx xx ..." */
static void trace_hex(gip_dev_t *d, const char *tag, const uint8_t *b, int n) {
    if (!d->cb.on_trace) return;
    size_t cap = strlen(tag) + 32 + 3 * (size_t)n;
    char *line = malloc(cap);
    if (!line) return;
    int p = snprintf(line, cap, "%s (%d):", tag, n);
    for (int i = 0; i < n; i++) p += snprintf(line + p, cap - p, " %02x", b[i]);
    d->cb.on_trace(d->cb.user, line);
    free(line);
}

static int decode_varint(const uint8_t *b, int len, uint32_t *val) {
    int i; *val = 0;
    for (i = 0; i < 4 && i < len; i++) { *val |= (uint32_t)(b[i] & 0x7f) << (7 * i); if (!(b[i] & 0x80)) break; }
    return i + 1;
}

static int decode_header(gip_hdr_t *h, const uint8_t *b, int len) {
    if (len < 4) return -1;
    h->cmd = b[0]; h->opts = b[1]; h->seq = b[2];
    int p = 3;
    p += decode_varint(b + p, len - p, &h->len);
    h->chunk_offset = 0;
    if (h->opts & GIP_OPT_CHUNK) p += decode_varint(b + p, len - p, &h->chunk_offset);
    h->hdr_len = p;
    return p;
}

static int gip_send(gip_dev_t *d, uint8_t *pkt, int len, const char *what) {
    int xfer = 0;
    int r = libusb_interrupt_transfer(d->h, d->ep_out, pkt, len, &xfer, 250);
    if (d->cfg.trace || r) {
        char tag[64]; snprintf(tag, sizeof tag, "TX %-14s r=%d%s", what, r, r ? libusb_error_name(r) : "");
        trace_hex(d, tag, pkt, len);
    }
    return r;
}

static uint8_t next_seq(gip_dev_t *d) { uint8_t s = d->seq++; if (d->seq == 0) d->seq = 1; return s; }

static int gip_send_cmd(gip_dev_t *d, uint8_t cmd, uint8_t opts, const uint8_t *payload, int plen, const char *what) {
    uint8_t pkt[64];
    pkt[0] = cmd; pkt[1] = opts; pkt[2] = next_seq(d); pkt[3] = (uint8_t)plen;
    if (plen) memcpy(pkt + 4, payload, plen);
    return gip_send(d, pkt, 4 + plen, what);
}

static int encode_varint(uint8_t *b, uint32_t v) { int i; for (i = 0; i < 4; i++) { b[i] = v & 0x7f; v >>= 7; if (v) b[i] |= 0x80; else break; } return i + 1; }
static int encode_header(uint8_t *b, uint8_t cmd, uint8_t opts, uint8_t sq, uint32_t len, uint32_t chunk_offset) {
    int n = 0; b[n++] = cmd; b[n++] = opts; b[n++] = sq;
    n += encode_varint(b + n, len);
    int actual = n + ((opts & GIP_OPT_CHUNK) ? encode_varint((uint8_t[4]){0}, chunk_offset) : 0);
    if (actual % 2) { b[n - 1] |= 0x80; b[n++] = 0; }        /* header length must be even */
    if (opts & GIP_OPT_CHUNK) n += encode_varint(b + n, chunk_offset);
    return n;
}
static int send_raw(gip_dev_t *d, uint8_t cmd, uint8_t opts, uint8_t sq, const uint8_t *data, uint32_t len, uint32_t chunk_offset, const char *what) {
    uint8_t pkt[64]; int hl = encode_header(pkt, cmd, opts, sq, len, chunk_offset);
    if (hl + len > 64) { logf_(d, "send_raw: too long"); return -1; }
    if (len) memcpy(pkt + hl, data, len);
    return gip_send(d, pkt, hl + len, what);
}
/* Send a GIP message of arbitrary size: single packet if it fits, else xone-style chunked transfer driven by ACKs. */
static int gip_send_msg(gip_dev_t *d, uint8_t cmd, uint8_t opts, const uint8_t *data, uint32_t len, const char *what) {
    uint8_t sq = next_seq(d);
    if (len <= GIP_PKT_MAX) return send_raw(d, cmd, opts, sq, data, len, 0, what);
    if (d->tx.active) logf_(d, "warning: chunked send already active, overwriting");
    free(d->tx.data); d->tx.data = malloc(len); memcpy(d->tx.data, data, len);
    d->tx.active = 1; d->tx.cmd = cmd; d->tx.opts = opts & ~(GIP_OPT_ACK | GIP_OPT_CHUNK_START); d->tx.seq = sq; d->tx.total = len;
    return send_raw(d, cmd, opts | GIP_OPT_ACK | GIP_OPT_CHUNK_START | GIP_OPT_CHUNK, sq, data, GIP_PKT_MAX, len, what);
}
static void gip_handle_tx_ack(gip_dev_t *d, const uint8_t *pl, int plen) {
    if (!d->tx.active || plen < 9 || pl[1] != d->tx.cmd) return;
    uint32_t acked = pl[3] | (pl[4] << 8);
    if (acked < d->tx.total) {
        uint32_t remaining = d->tx.total - GIP_PKT_MAX;   /* xone: resend everything after the first chunk */
        while (remaining) {
            uint32_t n = remaining > GIP_PKT_MAX ? GIP_PKT_MAX : remaining;
            uint8_t o = d->tx.opts | GIP_OPT_CHUNK | (remaining <= GIP_PKT_MAX ? GIP_OPT_ACK : 0);
            send_raw(d, d->tx.cmd, o, d->tx.seq, d->tx.data + (d->tx.total - remaining), n, d->tx.total - remaining, "chunk");
            remaining -= n;
        }
    } else {
        send_raw(d, d->tx.cmd, d->tx.opts | GIP_OPT_CHUNK, d->tx.seq, NULL, 0, d->tx.total, "chunk_end");
        d->tx.active = 0;
    }
}
static int auth_send_cb(void *user, const uint8_t *payload, int len, int need_ack) {
    gip_dev_t *d = user;
    return gip_send_msg(d, GIP_CMD_AUTH, GIP_OPT_INTERNAL | (need_ack ? GIP_OPT_ACK : 0), payload, len, "auth");
}

/* Protocol Control ACK (xone gip_acknowledge_pkt / spec 3.1.5.1):
 * 01 20 <seq of acked pkt> 09 | 00 <cmd> <opts=0x20> <received lo> <received hi> 00 00 <remaining lo> <remaining hi> */
static void gip_ack(gip_dev_t *d, const gip_hdr_t *in, uint32_t received, uint32_t remaining) {
    uint8_t pkt[13] = { GIP_CMD_ACK, GIP_OPT_INTERNAL, in->seq, 0x09,
                        0x00, in->cmd, GIP_OPT_INTERNAL, (uint8_t)received, (uint8_t)(received >> 8), 0, 0,
                        (uint8_t)remaining, (uint8_t)(remaining >> 8) };
    gip_send(d, pkt, sizeof pkt, "ack");
}

static void emit_state(gip_dev_t *d, gip_event_t ev, const uint8_t *extra, int extra_len) {
    if (d->cb.on_state) d->cb.on_state(d->cb.user, ev, &d->st, extra, extra_len);
}

static int find_endpoints(gip_dev_t *d, libusb_device *dev) {
    struct libusb_config_descriptor *cfg;
    if (libusb_get_config_descriptor(dev, 0, &cfg) != 0) return -1;
    int found = -1;
    for (int i = 0; i < cfg->bNumInterfaces && found < 0; i++) {
        const struct libusb_interface_descriptor *alt = &cfg->interface[i].altsetting[0];
        if (alt->bInterfaceClass == 0xFF && alt->bInterfaceSubClass == 0x47 && alt->bInterfaceProtocol == 0xD0 && alt->bNumEndpoints == 2) {
            d->ep_in = d->ep_out = 0;
            for (int e = 0; e < alt->bNumEndpoints; e++) {
                const struct libusb_endpoint_descriptor *ep = &alt->endpoint[e];
                if ((ep->bmAttributes & 3) != LIBUSB_TRANSFER_TYPE_INTERRUPT) continue;
                if (ep->bEndpointAddress & 0x80) d->ep_in = ep->bEndpointAddress; else d->ep_out = ep->bEndpointAddress;
            }
            if (d->ep_in && d->ep_out) found = alt->bInterfaceNumber;
        }
    }
    libusb_free_config_descriptor(cfg);
    return found;
}

static void send_metadata_request(gip_dev_t *d) {
    gip_send_cmd(d, GIP_CMD_METADATA, GIP_OPT_INTERNAL, NULL, 0, "meta_request");
    d->state = ST_META;
}

static void send_start_led_rumble(gip_dev_t *d) {
    const uint8_t start[] = { 0x00 };                 /* Set Device State: Start */
    const uint8_t led[]   = { 0x00, 0x01, 0x14 };     /* LED on, brightness 0x14 */
    const uint8_t rmb[]   = { 0x00, 0x0F, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xEB };
    if (strstr(d->init, "power"))  gip_send_cmd(d, GIP_CMD_STATE,  GIP_OPT_INTERNAL, start, sizeof start, "state_start");
    if (strstr(d->init, "led"))    gip_send_cmd(d, GIP_CMD_LED,    GIP_OPT_INTERNAL, led, sizeof led, "led_on");
    if (strstr(d->init, "rumble")) gip_send_cmd(d, GIP_CMD_RUMBLE, 0x00, rmb, sizeof rmb, "rumble_init");
    d->state = ST_RUNNING; d->t_started = now_s(); d->post_done = 0;
}

static void start_auth(gip_dev_t *d, const char *msg) {
    gip_auth_free(d->auth); d->auth = gip_auth_new(auth_send_cb, d); d->auth_started = 1;
    logf_(d, "%s", msg); gip_auth_start(d->auth);
    d->state = ST_RUNNING; d->t_started = now_s(); d->post_done = 1;
}

/* Spec order (MS-GIPUSB 1.3.1): Hello -> Metadata -> Security -> Set Device State: Start -> ... -> input */
static void start_device(gip_dev_t *d) {
    const uint8_t auth_done[] = { 0x01, 0x00 };       /* fake "security passed" (xpad xboxone_auth_done) */
    if (strstr(d->init, "sdl")) {  /* SDL-driver order: Start/LED/rumble first, then security, then Start/LED again */
        d->init = "power,led,rumble"; send_start_led_rumble(d); d->init = "power,led";
        start_auth(d, "auth: starting security handshake (after Start)");
        return;
    }
    if (strstr(d->init, "authdone")) { gip_send_cmd(d, GIP_CMD_AUTH, GIP_OPT_INTERNAL, auth_done, sizeof auth_done, "auth_done"); send_start_led_rumble(d); }
    else if (strstr(d->init, "auth")) start_auth(d, "auth: starting security handshake");
    else send_start_led_rumble(d);
}
static void begin_init(gip_dev_t *d) {
    if (strstr(d->init, "meta") && !strstr(d->init, "sdl")) send_metadata_request(d); else start_device(d);
}

static void auth_feed(gip_dev_t *d, const uint8_t *data, int len) {
    if (gip_auth_process(d->auth, data, len)) logf_(d, "auth: processing failed (%s)", gip_auth_state_name(d->auth));
    if (gip_auth_complete(d->auth) && d->auth_started) { d->auth_started = 0; send_start_led_rumble(d); }
}

static void post_start(gip_dev_t *d) {
    d->post_done = 1;
    if (d->cfg.restart) {
        const uint8_t stp[] = { 0x01 }, strt[] = { 0x00 };
        gip_send_cmd(d, GIP_CMD_STATE, GIP_OPT_INTERNAL, stp, 1, "state_stop");
        usleep(100000);
        gip_send_cmd(d, GIP_CMD_STATE, GIP_OPT_INTERNAL, strt, 1, "state_start2");
    }
    if (d->cfg.serial) { uint8_t sp[] = { 0x1E, 0x30, 0x07, 0x01, 0x04 }; gip_send(d, sp, sizeof sp, "serial_req"); }
    if (d->cfg.query) {  /* Razer vendor frame: diagnostic-mode state query (class 0x00, sub 0x84), read-only */
        uint8_t q[64] = {0}; q[0] = 0x0F; q[1] = 0x00; q[2] = 0x00; q[3] = 0x01; q[0x0A] = 0x00; q[0x0B] = 0x84;
        uint8_t x = 0; for (int k = 0x06; k <= 0x3D; k++) x ^= q[k]; q[0x3E] = x;
        gip_send(d, q, sizeof q, "razer_query");
    }
}

static void handle_packet(gip_dev_t *d, uint8_t *buf, int xfer, double now) {
    gip_hdr_t hd;
    if (decode_header(&hd, buf, xfer) < 0) return;
    const uint8_t *pl = buf + hd.hdr_len;
    int plen = xfer - hd.hdr_len; if ((uint32_t)plen > hd.len) plen = hd.len;

    /* Generic reassembly of chunked messages other than metadata (e.g. auth certificates). */
    if ((hd.opts & GIP_OPT_CHUNK) && hd.cmd != GIP_CMD_METADATA) {
        if (hd.opts & GIP_OPT_CHUNK_START) { d->rx_cmd = hd.cmd; d->rx_total = hd.chunk_offset; hd.chunk_offset = 0; d->rx_received = 0; free(d->rx_buf); d->rx_buf = calloc(1, d->rx_total + 64); }
        if (d->rx_buf && hd.cmd == d->rx_cmd) {
            if (hd.len) { if (hd.chunk_offset + plen <= d->rx_total + 64) { memcpy(d->rx_buf + hd.chunk_offset, pl, plen); d->rx_received = hd.chunk_offset + plen; } }
            if (hd.opts & GIP_OPT_ACK) gip_ack(d, &hd, d->rx_received, d->rx_total > d->rx_received ? d->rx_total - d->rx_received : 0);
            if (hd.len == 0) {   /* completion */
                if (d->cfg.trace) { char tag[40]; snprintf(tag, sizeof tag, "RX chunked cmd 0x%02x complete", hd.cmd); trace_hex(d, tag, d->rx_buf, d->rx_received); }
                if (hd.cmd == GIP_CMD_AUTH && d->auth) auth_feed(d, d->rx_buf, d->rx_received);
                else d->n_other++;
                free(d->rx_buf); d->rx_buf = NULL;
            }
        }
        return;
    }
    if (hd.cmd == GIP_CMD_ACK) { if (d->cfg.trace) trace_hex(d, "RX ack", buf, xfer); gip_handle_tx_ack(d, pl, plen); return; }
    if (hd.cmd == GIP_CMD_AUTH) {
        if (d->cfg.trace) trace_hex(d, "RX auth", buf, xfer);
        if (hd.opts & GIP_OPT_ACK) gip_ack(d, &hd, hd.len, 0);
        if (d->auth) auth_feed(d, pl, plen);
        return;
    }
    switch (hd.cmd) {
    case GIP_CMD_HELLO:
        d->n_hello++;
        if (d->cfg.trace) trace_hex(d, "RX hello", buf, xfer);
        if (d->state == ST_WAIT_HELLO) {
            logf_(d, "Hello: vid=%02x%02x pid=%02x%02x fw=%u.%u.%u.%u", pl[9], pl[8], pl[11], pl[10],
                  pl[12] | pl[13] << 8, pl[14] | pl[15] << 8, pl[16] | pl[17] << 8, pl[18] | pl[19] << 8);
            d->t_last_req = now; begin_init(d);
        }
        break;
    case GIP_CMD_METADATA:
        if (d->cfg.trace) trace_hex(d, "RX metadata", buf, xfer);
        if (hd.opts & GIP_OPT_CHUNK) {
            if (hd.opts & GIP_OPT_CHUNK_START) {
                d->meta_total = hd.chunk_offset; hd.chunk_offset = 0; d->meta_received = 0;
                free(d->meta_buf); d->meta_buf = calloc(1, d->meta_total + 64);
                logf_(d, "metadata: total %u bytes", d->meta_total);
            }
            if (hd.len == 0 && d->meta_buf) {   /* Metadata Complete: empty fragment */
                logf_(d, "metadata complete (%u/%u bytes)", d->meta_received, d->meta_total);
                if (d->cb.on_metadata) d->cb.on_metadata(d->cb.user, d->meta_buf, d->meta_received);
                d->meta_done = 1;
                if (hd.opts & GIP_OPT_ACK) gip_ack(d, &hd, d->meta_received, 0);
                start_device(d);
                break;
            }
            if (d->meta_buf && hd.chunk_offset + plen <= d->meta_total + 64) { memcpy(d->meta_buf + hd.chunk_offset, pl, plen); d->meta_received = hd.chunk_offset + plen; }
            if (hd.opts & GIP_OPT_ACK) gip_ack(d, &hd, d->meta_received, d->meta_total > d->meta_received ? d->meta_total - d->meta_received : 0);
        } else if (hd.opts & GIP_OPT_ACK) gip_ack(d, &hd, hd.len, 0);
        break;
    case GIP_CMD_INPUT:
        if (hd.opts & GIP_OPT_ACK) gip_ack(d, &hd, hd.len, 0);
        if (plen >= 14) {
            d->n_input++;
            d->st.buttons = (uint16_t)(pl[0] | (pl[1] << 8)) & ~0x0002;
            d->st.lt = (uint16_t)(pl[2] | (pl[3] << 8)) & 0x3FF;
            d->st.rt = (uint16_t)(pl[4] | (pl[5] << 8)) & 0x3FF;
            d->st.lx = (int16_t)(pl[6] | (pl[7] << 8));
            d->st.ly = (int16_t)(pl[8] | (pl[9] << 8));
            d->st.rx = (int16_t)(pl[10] | (pl[11] << 8));
            d->st.ry = (int16_t)(pl[12] | (pl[13] << 8));
            if (d->cfg.trace) trace_hex(d, "RX input", buf, xfer);
            emit_state(d, GIP_EVENT_INPUT, pl + 14, plen - 14);
        }
        break;
    case GIP_CMD_GUIDE:
        if (hd.opts & GIP_OPT_ACK) gip_ack(d, &hd, hd.len, 0);
        d->st.guide = pl[0] & 0x03;
        if (d->cfg.trace) trace_hex(d, "RX guide", buf, xfer);
        emit_state(d, GIP_EVENT_GUIDE, NULL, 0);
        break;
    default:
        d->n_other++;
        if (hd.opts & GIP_OPT_ACK) gip_ack(d, &hd, hd.len, 0);
        if (d->cb.on_packet) d->cb.on_packet(d->cb.user, hd.cmd, buf, xfer);
        break;
    }
}

/* ---- public API ---- */

void gip_config_default(gip_config_t *cfg) {
    memset(cfg, 0, sizeof *cfg);
    cfg->vid = 0x1532; cfg->pid = 0x0a3f;
    cfg->init = "meta,power,led,auth,rumble";
}

gip_dev_t *gip_new(const gip_config_t *cfg, const gip_callbacks_t *cb) {
    gip_dev_t *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    if (cfg) d->cfg = *cfg; else gip_config_default(&d->cfg);
    if (!d->cfg.init) d->cfg.init = "meta,power,led,auth,rumble";
    if (cb) d->cb = *cb;
    d->init = d->cfg.init;
    d->iface = -1;
    if (libusb_init(&d->ctx)) { free(d); return NULL; }
    return d;
}

void gip_free(gip_dev_t *d) {
    if (!d) return;
    gip_close(d);
    gip_auth_free(d->auth);
    free(d->meta_buf); free(d->rx_buf); free(d->tx.data);
    libusb_exit(d->ctx);
    free(d);
}

int gip_open(gip_dev_t *d) {
    if (d->h) return GIP_OK;
    libusb_device_handle *h = libusb_open_device_with_vid_pid(d->ctx, d->cfg.vid, d->cfg.pid);
    if (!h) return GIP_ERR_NOT_FOUND;
    int iface = find_endpoints(d, libusb_get_device(h));
    if (iface < 0) { logf_(d, "no GIP interface (FF/47/D0) with 2 interrupt endpoints"); libusb_close(h); return GIP_ERR_NO_IFACE; }
    int cur = 0; libusb_get_configuration(h, &cur);
    if (cur != 1) { int r = libusb_set_configuration(h, 1); logf_(d, "set_configuration(1): %s (was %d)", r ? libusb_error_name(r) : "ok", cur); }
    int r = libusb_claim_interface(h, iface);
    if (r) { logf_(d, "claim_interface failed: %s", libusb_error_name(r)); libusb_close(h); return GIP_ERR_CLAIM; }
    /* Like Linux xpad: explicitly select alt-setting 0 of the GIP audio interface (#1); some
     * third-party pads need this before they report properly. */
    if (libusb_claim_interface(h, 1) == 0) {
        int ra = libusb_set_interface_alt_setting(h, 1, 0);
        logf_(d, "audio interface #1 alt 0: %s", ra ? libusb_error_name(ra) : "ok");
    } else logf_(d, "could not claim audio interface #1 (ignored)");
    logf_(d, "opened %04x:%04x, GIP interface #%d, EP IN 0x%02x, EP OUT 0x%02x", d->cfg.vid, d->cfg.pid, iface, d->ep_in, d->ep_out);
    d->h = h; d->iface = iface;
    d->seq = 1; d->state = ST_WAIT_HELLO; d->tx.active = 0; gip_auth_free(d->auth); d->auth = NULL;
    d->meta_done = 0; d->meta_total = d->meta_received = 0; free(d->meta_buf); d->meta_buf = NULL;
    d->t_open = now_s(); d->meta_retries = 0;
    return GIP_OK;
}

int gip_is_open(const gip_dev_t *d) { return d->h != NULL; }

void gip_close(gip_dev_t *d) {
    if (!d->h) return;
    libusb_release_interface(d->h, d->iface); libusb_close(d->h);
    d->h = NULL;
}

int gip_poll(gip_dev_t *d, int timeout_ms) {
    if (!d->h) return GIP_ERR_LOST;
    double now = now_s();
    /* If no Hello shows up (device already active from a previous host), kick off init after 0.6 s. */
    if (d->state == ST_WAIT_HELLO && now - d->t_open > 0.6) { logf_(d, "no Hello yet; sending init anyway"); d->t_last_req = now; begin_init(d); }
    /* Spec: host resends Metadata Request every 500 ms, up to 4 times. */
    if (d->state == ST_META && !d->meta_received && now - d->t_last_req > 0.5) {
        if (++d->meta_retries >= 4) { logf_(d, "no metadata response; continuing without it"); start_device(d); }
        else { d->t_last_req = now; send_metadata_request(d); }
    }
    if (d->state == ST_RUNNING && !d->post_done && now - d->t_started > 0.4) post_start(d);

    uint8_t buf[64];
    int xfer = 0;
    int r = libusb_interrupt_transfer(d->h, d->ep_in, buf, sizeof buf, &xfer, timeout_ms);
    if (r == LIBUSB_ERROR_TIMEOUT) return GIP_OK;
    if (r) {
        logf_(d, "read error: %s -- device lost, waiting for reconnect...", libusb_error_name(r));
        gip_close(d);
        return GIP_ERR_LOST;
    }
    handle_packet(d, buf, xfer, now);
    return GIP_OK;
}

void gip_get_state(const gip_dev_t *d, gip_state_t *out) { *out = d->st; }

int gip_rumble(gip_dev_t *d, uint8_t mask, uint8_t lt, uint8_t rt, uint8_t strong, uint8_t weak,
               uint8_t duration, uint8_t delay, uint8_t repeat) {
    if (!d->h || d->state != ST_RUNNING || d->auth_started) return GIP_ERR_NOT_READY;
    const uint8_t p[] = { 0x00, mask, lt, rt, strong, weak, duration, delay, repeat };
    return gip_send_cmd(d, GIP_CMD_RUMBLE, 0x00, p, sizeof p, "rumble") ? GIP_ERR_TX : GIP_OK;
}

void gip_get_stats(const gip_dev_t *d, gip_stats_t *out) {
    out->n_input = d->n_input; out->n_other = d->n_other; out->n_hello = d->n_hello; out->metadata_ok = d->meta_done;
    out->auth = d->auth ? gip_auth_state_name(d->auth) : NULL;
}
