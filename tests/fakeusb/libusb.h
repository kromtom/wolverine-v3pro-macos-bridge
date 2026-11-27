/* Minimal fake libusb-1.0 API: only what giptool/gipcore use. Implemented in tests/fake_libusb.c,
 * which replays a scripted device (see tests/compare-giptool.sh). Test-only. */
#pragma once
#include <stdint.h>

enum libusb_error {
    LIBUSB_SUCCESS = 0, LIBUSB_ERROR_IO = -1, LIBUSB_ERROR_INVALID_PARAM = -2, LIBUSB_ERROR_ACCESS = -3,
    LIBUSB_ERROR_NO_DEVICE = -4, LIBUSB_ERROR_NOT_FOUND = -5, LIBUSB_ERROR_BUSY = -6, LIBUSB_ERROR_TIMEOUT = -7,
    LIBUSB_ERROR_PIPE = -9,
};
enum libusb_transfer_type { LIBUSB_TRANSFER_TYPE_INTERRUPT = 3 };

typedef struct libusb_context libusb_context;
typedef struct libusb_device libusb_device;
typedef struct libusb_device_handle libusb_device_handle;

struct libusb_endpoint_descriptor { uint8_t bEndpointAddress, bmAttributes; };
struct libusb_interface_descriptor {
    uint8_t bInterfaceNumber, bInterfaceClass, bInterfaceSubClass, bInterfaceProtocol, bNumEndpoints;
    const struct libusb_endpoint_descriptor *endpoint;
};
struct libusb_interface { const struct libusb_interface_descriptor *altsetting; int num_altsetting; };
struct libusb_config_descriptor { uint8_t bNumInterfaces; const struct libusb_interface *interface; };

int libusb_init(libusb_context **ctx);
void libusb_exit(libusb_context *ctx);
const char *libusb_error_name(int code);
libusb_device_handle *libusb_open_device_with_vid_pid(libusb_context *ctx, uint16_t vid, uint16_t pid);
void libusb_close(libusb_device_handle *h);
libusb_device *libusb_get_device(libusb_device_handle *h);
int libusb_get_config_descriptor(libusb_device *dev, uint8_t idx, struct libusb_config_descriptor **cfg);
void libusb_free_config_descriptor(struct libusb_config_descriptor *cfg);
int libusb_get_configuration(libusb_device_handle *h, int *config);
int libusb_set_configuration(libusb_device_handle *h, int config);
int libusb_claim_interface(libusb_device_handle *h, int iface);
int libusb_release_interface(libusb_device_handle *h, int iface);
int libusb_set_interface_alt_setting(libusb_device_handle *h, int iface, int alt);
int libusb_interrupt_transfer(libusb_device_handle *h, unsigned char ep, unsigned char *data, int len, int *xfer, unsigned int timeout);
