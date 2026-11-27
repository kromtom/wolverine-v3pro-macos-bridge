# Backlog

Open items kept for future consideration. Each entry records what is verified, what is not, and possible next steps.

## Guide button does not reach Chrome's Gamepad API

Status: open, not blocking. On xbox.com/play, Guide only opens the stream overlay.

Verified 2026-11-27, macOS 27.2.1, Chrome 158.0.8127.38, 2.4 GHz receiver, WolverineBridge, identity `045E:0B13`:

- The bridge sends Guide. An IOHIDManager listener on `045E:0B13` saw button page usage `0x0D` (button 13, report bit 12) go 1/0 on 3 of 3 taps. A (usage `0x01`) was the control.
- `web/gamepad.html` shows no button change for Guide. Mapping is `standard`; all other inputs work.
- System Settings → Gaming Controllers → Home Button → "Enable Home Button Actions" is off. With it off, the Games app no longer opens and nothing else happens on screen. Chrome still shows nothing.
- An earlier test app that fed the same virtual pad synthetic input (no hardware) had the same result.

Cause: unverified. The input is dropped after IOHID: either the GameController framework withholds `buttonHome`, or Chrome does not map it. The Gamepad id has no `Vendor:`/`Product:` suffix, which suggests Chrome reads the pad through the GameController framework.

Next steps to consider:

1. Split the cause. Write a small GameController app that prints `GCExtendedGamepad.buttonHome` for the virtual pad, with Home Button Actions on and off. Try `preferredSystemGestureState = .disabled` on the button.
2. If GameController reports it, Chrome drops it. Check Chromium's macOS GameController data fetcher for `buttonHome` handling. A bridge-side workaround would be to map Guide to another button, which breaks the standard layout. Do this only as an opt-in.
3. If GameController does not report it, macOS drops it. Test the other identity `045E:02FD` and other descriptor layouts (for example, Guide as Consumer page AC Home `0x0223`. Real Xbox BT firmware may report it this way; unverified).
