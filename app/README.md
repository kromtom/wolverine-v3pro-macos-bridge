# WolverineBridge app

`WolverineBridge` reads the Razer Wolverine V3 Pro (`1532:0a3f`, wired or 2.4 GHz receiver) through `src/core` (`libgipcore.a`, `import CGipCore`). It publishes the controller as a virtual Xbox Wireless Controller through CoreHID's `HIDVirtualDevice`. Host rumble (output report 3) goes back to the pad as GIP 0x09 through `gip_rumble()`.

By default it starts as a menu bar app. `--cli` runs it in the terminal instead.

## Create the provisioning profile

`HIDVirtualDevice` needs the `com.apple.developer.hid.virtual.device` entitlement. Without it, `HIDVirtualDevice(properties:)` returns nil. The entitlement comes from a development provisioning profile. In the Apple Developer portal, under Certificates, Identifiers & Profiles:

1. **Identifiers:** create an explicit App ID of your own, for example `com.<you>.wolverinebridge`. Enable **HID Virtual Device (development)**.
2. **Devices:** register this Mac. Get its Provisioning UDID with `system_profiler SPHardwareDataType`.
3. **Profiles:** create a **macOS App Development** profile for that App ID, with your Apple Development certificate and this Mac.
4. Download the profile to `app/profiles/development.provisionprofile`. The folder is git-ignored.

The profile and certificate expire yearly. When they expire, regenerate the profile and run `make bridge` again.

## Build

```bash
make bridge                                         # builds build/libgipcore.a first
PROFILE=/path/to/x.provisionprofile make bridge     # profile in another location
BUNDLE_ID=com.<you>.wolverinebridge make bridge     # only needed for a wildcard App ID
make install-bridge                                 # make bridge, then copy to ~/Applications
```

`scripts/build-app.sh` reads the bundle ID from the profile's App ID, unless `BUNDLE_ID` is set. It checks the profile's entitlement, expiry, and device list. It picks the keychain identity that matches a certificate in the profile, assembles `build/WolverineBridge.app`, writes the bundle ID into its `Info.plist`, and signs it. App Sandbox is off. If sandboxing is ever turned on, add `com.apple.security.device.usb`.

## Run

```bash
open ~/Applications/WolverineBridge.app             # installed copy; Start at Login works here
open build/WolverineBridge.app                      # development copy; Start at Login stays disabled
build/WolverineBridge.app/Contents/MacOS/WolverineBridge --cli    # terminal mode; Ctrl-C quits
build/WolverineBridge.app/Contents/MacOS/WolverineBridge --help   # --identity, --version, --transport, --no-rumble, --seconds, --verbose
```

Run the binary from inside the signed bundle, or the entitlement does not apply. The first launch right after signing once returned nil; a second launch worked. The cause is unknown.

Only one reader can claim the pad. Stop `giptool` and any other USB reader first. A second copy of the bridge shows an alert and exits.

## Verify

1. `hidutil list | grep -i 0x45e` should list the virtual device, transport `Virtual`.
2. Open `web/gamepad.html` in Chrome and press a button to wake the Gamepad API. Expected: id `Xbox Wireless Controller (STANDARD GAMEPAD)`, mapping `standard`.
3. Open xbox.com/play and check menu navigation with the D-pad and A/B.

An empty mapping means Chrome does not map this VID/PID. Try `--identity ones` (`045E:02FD`), then other `--version` values.

## Menu bar app

Without `--cli`, `WolverineBridge` is a menu bar app (`LSUIElement`, SwiftUI `MenuBarExtra`). It starts bridging at launch with the default options (`045E:0B13`, rumble on).

- Status: waiting for the pad, connected with the handshake state, or released. Handshake state and retry count, pad updates and reports, rumble sent/dropped/failed.
- **Release USB Device**: closes the USB device so `giptool` or another reader can claim it. The virtual pad stays and sends neutral reports, so Chrome keeps its gamepad. Untick to claim the pad again. Every launch starts claimed.
- **Rumble**: forwards host rumble when on (runtime `--no-rumble`).
- **Start at Login**: `SMAppService.mainApp`, off until ticked. Enabled only when the app runs from `/Applications` or `~/Applications`, because `make bridge` deletes and rebuilds `build/WolverineBridge.app`.
- **Recent Log**: the last 20 status lines (newest first; repeats are counted, not repeated) and Copy Log. The same lines go to os_log, with the app's bundle ID as subsystem. The `auth: ...` lines from `gipauth.c` go to stderr only, so they are not shown.
- **Quit**: stops the reader (neutral report, USB released) and quits after at most 3 s.

View the os_log lines with:

```bash
/usr/bin/log show --last 2m --info --predicate 'subsystem == "<your bundle id>"' --style compact
```

## How the bridge works

- One reader thread (`GipReader.swift`) makes every `gip_*` call.
- Translation: GIP s16 sticks become 0..65535 with Y flipped for HID. Triggers 0..1023 pass through. The 0x07 Guide state sets button bit 12.
- The bridge sends a report on every pad update, and repeats the last one every 100 ms.
- Rumble bytes pass through unchanged: mask, LT, RT, strong, weak, duration, delay, loop. A newer request replaces one that has not been sent. Requests that arrive before the handshake completes are dropped.
- Poll timeout is 100 ms, as in `giptool`. With 8 ms, the handshake did not complete (0/2 runs; 1/1 at 100 ms). The cause is unverified. While the pad is idle, rumble can wait up to 100 ms.
- The CLI status line shows `pad` (handshake complete), `hs.` (open, handshake not complete), or `---`, then pad updates (`in`), reports sent (`rep`), and rumble commands sent (`rmb`).

Session supervision (`GipReader.swift`, reader thread):

- Device lost: reopen every 0.5 s, then send a neutral report, so no control stays held.
- Handshake `failed` (for example `auth: handshake failed: 0x05`): close and reopen at once.
- Handshake not complete within the timeout after open: close and reopen. The timeout starts at 10 s and grows to 20, 40, then 60 s while no handshake completes. A completed handshake, a lost device, or Resume resets it to 10 s. With the receiver plugged in and the pad off, the receiver is therefore reopened at those intervals. The reopen is also what gives a pad switched on later its handshake, because the core acts only on the first Hello of a session.
- Hello after the handshake completed (`gip_stats_t.n_hello` grew): close and reopen. This is meant for a pad that power-cycles while the receiver stays plugged in. Unverified: it is not known whether the receiver forwards that Hello.
- Each close makes macOS re-enumerate the pad (~2 s); the reader logs `waiting for 1532:0a3f` until it is back.

## Report format

`Sources/XboxHID/XboxBluetoothReport.swift` holds the HID descriptor and encoder. It uses the Xbox Bluetooth firmware 5.x layout: input report 1 has 16-bit sticks, 10-bit triggers, a hat switch, 15 buttons, and Share; output report 3 carries rumble.

## Verified results

2026-11-27, macOS 27.2.1, Chrome 158.0.8127.38, 2.4 GHz receiver, identity `045E:0B13` version `0x0513`:

| Check | Result |
| --- | --- |
| Virtual device | `hidutil list` shows `0x45e 0xb13`, transport `Virtual` (requested `bluetooth` is not kept) |
| Chrome Gamepad API | id `Xbox Wireless Controller (STANDARD GAMEPAD)`, mapping `standard`; sticks, triggers, buttons, and D-pad working |
| Handshake via the bridge | Completed |
| Rumble | Chrome sent `0f 00 00 64 64 0a 00 00` (100 ms pieces); 14 commands sent for the 0.5 s test; the pad vibrated |
| xbox.com/play Remote Play window | Working |
| Guide | The virtual pad sends HID button 13 (IOHIDManager, 3/3 taps); Chrome shows no change, also with Home Button Actions off. Cause unverified; see [BACKLOG.md](../BACKLOG.md) |
| Wired mode | Not checked |

Not verified with hardware: handshake retry, Hello restart, Release/Resume with `giptool`, Start at Login.
