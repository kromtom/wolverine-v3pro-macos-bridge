CC ?= clang
LIBUSB_CFLAGS := $(shell pkg-config --cflags libusb-1.0 2>/dev/null || echo -I/opt/homebrew/opt/libusb/include/libusb-1.0)
LIBUSB_LIBS   := $(shell pkg-config --libs libusb-1.0 2>/dev/null || echo -L/opt/homebrew/opt/libusb/lib -lusb-1.0)

# 15.0 matches the Swift app's deployment target (app/Package.swift), which links libgipcore.a.
CFLAGS_CORE := -O2 -Wall -Wextra -Wno-deprecated-declarations -mmacosx-version-min=15.0
CORE_SRCS := src/core/gipcore.c src/core/gipauth.c
CORE_HDRS := src/core/gipcore.h src/core/gipauth.h
CORE_OBJS := $(CORE_SRCS:src/core/%.c=build/core/%.o)
# Link line for anything using libgipcore.a (giptool; app/Package.swift repeats it for WolverineBridge)
CORE_LIBS := $(LIBUSB_LIBS) -framework Security -framework CoreFoundation

all: build/giptool

# Reusable GIP host core (libusb + handshake + 0x20/0x07 decoding), see src/core/gipcore.h
build/core/%.o: src/core/%.c $(CORE_HDRS)
	@mkdir -p build/core
	$(CC) $(CFLAGS_CORE) $(LIBUSB_CFLAGS) -c -o $@ $<

build/libgipcore.a: $(CORE_OBJS)
	rm -f $@
	ar rcs $@ $^

build/giptool: src/giptool.c src/core/gipcore.h build/libgipcore.a
	$(CC) $(CFLAGS_CORE) -o $@ src/giptool.c build/libgipcore.a $(CORE_LIBS)

# Core unit test (tests/test_rumble.c): replays scripted USB traffic (tests/unit/*.txt) through a
# fake libusb and checks gip_rumble and the Hello counter. No hardware.
test-core:
	@mkdir -p build/test-core
	$(CC) -O2 -Wall -Wno-deprecated-declarations -Itests/fakeusb -Isrc/core -o build/test-core/test_rumble \
		tests/test_rumble.c src/core/gipcore.c src/core/gipauth.c tests/fake_libusb.c -framework Security -framework CoreFoundation
	./build/test-core/test_rumble build/test-core

clean:
	rm -rf build/giptool build/libgipcore.a build/core build/test-core

.PHONY: all clean bridge install-bridge test-core

# Bridge app: real Wolverine input -> virtual Xbox gamepad (needs a development provisioning profile,
# see app/README.md)
bridge: build/libgipcore.a
	./scripts/build-app.sh

# Copy the signed bridge to ~/Applications, where "Start at Login" can point at a stable path.
# Quit the running bridge first (menu bar icon > Quit WolverineBridge).
install-bridge: bridge
	@if pgrep -f "$(HOME)/Applications/WolverineBridge.app/" >/dev/null; then \
		echo "error: ~/Applications/WolverineBridge.app is running; quit it from its menu first" >&2; exit 1; fi
	mkdir -p "$(HOME)/Applications"
	rm -rf "$(HOME)/Applications/WolverineBridge.app"
	ditto build/WolverineBridge.app "$(HOME)/Applications/WolverineBridge.app"
	codesign --verify --strict "$(HOME)/Applications/WolverineBridge.app"
	@echo "installed $(HOME)/Applications/WolverineBridge.app (open it, then tick Start at Login)"
