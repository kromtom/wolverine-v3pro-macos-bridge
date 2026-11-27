/*
 * Fake libusb for hardware-free giptool tests. Test-only, GPL-2.0-or-later.
 *
 * Environment:
 *   FAKE_USB_SCRIPT  file with one directive per line, consumed by IN reads (blank lines and # comments skipped):
 *                      rx <hex bytes>   next IN read returns these bytes
 *                      wait <ms>        next IN read sleeps <ms>, then times out
 *                      lost <n>         next IN read fails with NO_DEVICE; the following <n> opens fail
 *                    When the script is exhausted, IN reads sleep their timeout and time out.
 *   FAKE_USB_TXLOG   file that receives "tx <hex>" for every OUT transfer and open/claim/close events
 *   FAKE_USB_ABSENT=1     every open fails
 *   FAKE_USB_CLAIMFAIL=1  claiming interface 0 fails with ACCESS
 *   FAKE_USB_CONFIG=<n>   value reported by libusb_get_configuration (default 1)
 */
#include "libusb.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct libusb_device { int dummy; };
struct libusb_device_handle { libusb_device dev; };

static FILE *script, *txlog;
static char script_path[1024]; /* a new FAKE_USB_SCRIPT at the next libusb_init replaces the script */
static int absent_opens;

static const struct libusb_endpoint_descriptor eps0[2] = { { 0x84, 3 }, { 0x05, 3 } };
static const struct libusb_endpoint_descriptor eps1[2] = { { 0x86, 1 }, { 0x07, 1 } };
static const struct libusb_interface_descriptor alt0 = { 0, 0xFF, 0x47, 0xD0, 2, eps0 };
static const struct libusb_interface_descriptor alt1 = { 1, 0xFF, 0x47, 0xD0, 0, eps1 };
static const struct libusb_interface ifaces[2] = { { &alt0, 1 }, { &alt1, 1 } };
static struct libusb_config_descriptor cfgdesc = { 2, ifaces };

static void tlog(const char *fmt, const char *arg) { if (txlog) { fprintf(txlog, fmt, arg); fflush(txlog); } }

int libusb_init(libusb_context **ctx) {
    if (ctx) *ctx = NULL;
    const char *s = getenv("FAKE_USB_SCRIPT"), *t = getenv("FAKE_USB_TXLOG");
    if (s && strcmp(s, script_path)) {
        if (script) fclose(script);
        snprintf(script_path, sizeof script_path, "%s", s);
        script = fopen(s, "r");
    }
    if (t && !txlog) txlog = fopen(t, "w");
    return 0;
}
void libusb_exit(libusb_context *ctx) { (void)ctx; }

const char *libusb_error_name(int code) {
    switch (code) {
    case LIBUSB_SUCCESS: return "LIBUSB_SUCCESS";
    case LIBUSB_ERROR_IO: return "LIBUSB_ERROR_IO";
    case LIBUSB_ERROR_ACCESS: return "LIBUSB_ERROR_ACCESS";
    case LIBUSB_ERROR_NO_DEVICE: return "LIBUSB_ERROR_NO_DEVICE";
    case LIBUSB_ERROR_TIMEOUT: return "LIBUSB_ERROR_TIMEOUT";
    case LIBUSB_ERROR_PIPE: return "LIBUSB_ERROR_PIPE";
    default: return "LIBUSB_ERROR_OTHER";
    }
}

libusb_device_handle *libusb_open_device_with_vid_pid(libusb_context *ctx, uint16_t vid, uint16_t pid) {
    (void)ctx;
    if (getenv("FAKE_USB_ABSENT") || vid != 0x1532 || pid != 0x0a3f) return NULL;
    if (absent_opens > 0) { absent_opens--; tlog("%s\n", "open: absent"); return NULL; }
    tlog("%s\n", "open");
    return calloc(1, sizeof(libusb_device_handle));
}
void libusb_close(libusb_device_handle *h) { tlog("%s\n", "close"); free(h); }
libusb_device *libusb_get_device(libusb_device_handle *h) { return &h->dev; }
int libusb_get_config_descriptor(libusb_device *dev, uint8_t idx, struct libusb_config_descriptor **cfg) { (void)dev; (void)idx; *cfg = &cfgdesc; return 0; }
void libusb_free_config_descriptor(struct libusb_config_descriptor *cfg) { (void)cfg; }
int libusb_get_configuration(libusb_device_handle *h, int *config) { (void)h; const char *c = getenv("FAKE_USB_CONFIG"); *config = c ? atoi(c) : 1; return 0; }
int libusb_set_configuration(libusb_device_handle *h, int config) { (void)h; (void)config; return LIBUSB_ERROR_PIPE; }
int libusb_claim_interface(libusb_device_handle *h, int iface) {
    (void)h; char b[16]; snprintf(b, sizeof b, "%d", iface); tlog("claim %s\n", b);
    return (iface == 0 && getenv("FAKE_USB_CLAIMFAIL")) ? LIBUSB_ERROR_ACCESS : 0;
}
int libusb_release_interface(libusb_device_handle *h, int iface) { (void)h; char b[16]; snprintf(b, sizeof b, "%d", iface); tlog("release %s\n", b); return 0; }
int libusb_set_interface_alt_setting(libusb_device_handle *h, int iface, int alt) { (void)h; (void)iface; (void)alt; return 0; }

static int hexval(char c) { return c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10; }

int libusb_interrupt_transfer(libusb_device_handle *h, unsigned char ep, unsigned char *data, int len, int *xfer, unsigned int timeout) {
    (void)h;
    *xfer = 0;
    if (!(ep & 0x80)) {
        if (txlog) { fprintf(txlog, "tx"); for (int i = 0; i < len; i++) fprintf(txlog, " %02x", data[i]); fprintf(txlog, "\n"); fflush(txlog); }
        *xfer = len;
        return 0;
    }
    char line[1024];
    while (script && fgets(line, sizeof line, script)) {
        char *p = line; while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == 0) continue;
        if (!strncmp(p, "wait ", 5)) { usleep(atoi(p + 5) * 1000); return LIBUSB_ERROR_TIMEOUT; }
        if (!strncmp(p, "lost", 4)) { absent_opens = atoi(p + 4); return LIBUSB_ERROR_NO_DEVICE; }
        if (!strncmp(p, "rx ", 3)) {
            int n = 0;
            for (p += 3; *p && n < len; ) {
                while (*p == ' ') p++;
                if (!p[0] || !p[1] || p[0] == '\n') break;
                data[n++] = (unsigned char)(hexval(p[0]) << 4 | hexval(p[1])); p += 2;
            }
            *xfer = n;
            return 0;
        }
        fprintf(stderr, "fake_libusb: bad directive: %s", line);
        exit(3);
    }
    usleep(timeout * 1000);
    return LIBUSB_ERROR_TIMEOUT;
}
