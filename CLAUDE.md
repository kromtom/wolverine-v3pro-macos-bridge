# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project goal

Make the Razer Wolverine V3 Pro (Xbox mode, USB `1532:0a3f`, wired or 2.4 GHz HyperSpeed receiver, same VID/PID for both) appear to macOS as a real game controller, so Chrome's Gamepad API and xbox.com/play can use it.

```text
Wolverine -> src/core (libgipcore.a: libusb + gipauth.c + GIP 0x20 decoder)
  -> WolverineBridge (Swift) report translator -> CoreHID HIDVirtualDevice
  -> IOHIDManager/GameController -> Chrome -> xbox.com/play
```

- Non-sandboxed Swift userspace menu bar app (AppKit `NSStatusItem` menu updated in place; SwiftUI `MenuBarExtra` rebuilt its items on every change and blanked labels in an open menu; start at login via `SMAppService`). It is not a DriverKit dext. If sandboxing is ever turned on, add `com.apple.security.device.usb`.
- DriverKit USB was rejected: `driverkit.transport.usb` is granted per vendor ID (Razer's `0x1532`), and DriverKit lacks CommonCrypto, which the handshake needs.
- Signing: Apple Development certificate plus a development profile with **HID Virtual Device (development)** (`com.apple.developer.hid.virtual.device`). No notarization. The bundle ID is not committed: `scripts/build-app.sh` reads it from the profile's App ID (or `BUNDLE_ID`) and writes it into the bundle's Info.plist. Swift code uses `appBundleID` (`Bundle.main.bundleIdentifier`). Never hardcode a bundle ID.
- Chrome applies Gamepad `mapping: "standard"` only to VID/PIDs it recognizes, so the virtual device impersonates a Microsoft Bluetooth pad (`045E:0B13` Xbox Series default, `045E:02FD` One S with `--identity ones`) with the Xbox Bluetooth firmware 5.x descriptor. Verified 2026-11-27, Chrome 158: `045E:0B13` gets `mapping: "standard"`. Guide does not reach the Gamepad API (cause unverified, see BACKLOG.md).

## Commands

```bash
brew install libusb pkgconf                 # deps
make                                        # build/libgipcore.a + build/giptool (debug CLI, arm64)
make test-core                              # core unit test (tests/test_rumble.c, fake libusb, no hardware)
make bridge                                 # build + sign build/WolverineBridge.app (needs app/profiles/development.provisionprofile)
make install-bridge                         # bridge copied to ~/Applications (stable path for Start at Login)
open build/WolverineBridge.app              # menu bar app
build/WolverineBridge.app/Contents/MacOS/WolverineBridge --cli   # terminal mode; run from the bundle
./build/giptool | --json | --raw | --query | --seconds N | --init meta,power,led,auth,rumble
```

## Architecture

- **GIP host sequence** (in `src/core/gipcore.c`): wait for Hello (0x02) → Metadata request (0x04, fragmented response must be ACKed) → **security handshake (0x06)** → Set Device State Start (0x05) → LED (0x0A) → rumble init → input reports (0x20) and Guide (0x07). The controller sends **no input at all until the handshake completes**; faking "auth done" does not work.
- **`src/core/gipcore.h`**: `gip_new(cfg, callbacks)` → `gip_open` → loop `gip_poll(d, 100)`. On `GIP_ERR_LOST` the handle is already closed and the caller reopens it. `gip_rumble()` sends 0x09 once the handshake is done (`GIP_ERR_NOT_READY` before then). The core acts only on the first Hello per session; `gip_stats_t.n_hello` counts all of them so a caller can detect a pad reconnect. Callbacks: `on_state`, `on_log`, `on_trace`, `on_metadata`, `on_packet`. Single-threaded, not thread-safe. Swift: `import CGipCore` via `src/core/module.modulemap`; app/Package.swift links `build/libgipcore.a` + libusb + Security + CoreFoundation with unsafeFlags (`LIBUSB_LIBDIR` env overrides the libusb path). Keep the poll timeout at 100 ms: 8 ms broke the handshake in the bridge (cause unverified).
- **`gipauth.c/.h`**: TLS-like handshake ported from medusalix/xone (CommonCrypto/Security.framework). Transport-agnostic: caller supplies a `gip_auth_send_fn` callback and feeds incoming 0x06 payloads to `gip_auth_process`. Prints its own `auth: ...` lines to stderr.
- **Input report 0x20** (payload after 4-byte header): buttons u16 LE (bit1 keep-alive, ignore), LT/RT u16 0..1023, LX/LY/RX/RY s16 LE, Y up positive. M1–M6 paddles are not exposed in Xbox mode.
- **Endpoints**: discovered at runtime (`find_endpoints`). Wired uses 0x81/0x01; the receiver uses 0x84/0x05. Do not hardcode.
- **app/**: `XboxHID` (descriptor + encoder), `WolverineBridge` (`GipReader.swift` reader thread owning all `gip_*` calls and session supervision; `BridgeSession.swift` virtual device; `MenuApp.swift` menu bar UI; `CLI.swift`). Details in app/README.md.

## Gotchas

- **Exclusive USB ownership**: only one reader (bridge, giptool) can claim the device at a time.
- Closing the USB handle makes macOS unconfigure the device; the controller reboots and re-enumerates (~2 s). Holding the Xbox button powers it off — tap only.
- Wireless handshake intermittently fails/stalls after reconnects; root cause unknown. Don't claim this is fixed without evidence.
- Razer Synapse for Mac (if installed) publishes phantom virtual controllers `045E:028E` and `1532:27DB` that never emit data; filter them.
- `giptool --init sdl` mutates `opt_init` and can skip auth on reconnect — experimental.
- License is GPL-2.0-or-later (xone-derived auth code); keep new code compatible.

## Docs

README.md (overview, status, credits), app/README.md (profile, build, menu, supervision, verified results), BACKLOG.md. Docs record verified results with dates; mark unverified claims as unverified.
