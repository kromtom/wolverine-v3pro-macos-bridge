#!/bin/bash
# Build build/WolverineBridge.app for distribution: bundle libusb and sign with Developer ID.
# Run scripts/make-dmg.sh afterwards to notarize the app and build the DMG.
#
#   ./scripts/sign-release.sh
#   PROFILE=path/to/profile.provisionprofile ./scripts/sign-release.sh   # default app/profiles/developerid.provisionprofile
#   LIBUSB_PREFIX=path/to/libusb ./scripts/sign-release.sh               # default build/libusb
#
# PROFILE must be a Developer ID provisioning profile for your App ID with the HID Virtual Device
# capability. Its Developer ID Application certificate must be in your keychain.
# LIBUSB_PREFIX must hold a libusb built for the app's deployment target (macOS 15.0), for example:
#   ./configure --prefix="$PWD/../../build/libusb" ac_cv_func_pipe2=no \
#       CFLAGS="-O2 -mmacosx-version-min=15.0 -Werror=unguarded-availability-new" \
#       LDFLAGS="-mmacosx-version-min=15.0" && make && make install
# ac_cv_func_pipe2=no is required: pipe2 exists only on macOS 27+, see BUILD.md.
# Homebrew's libusb is built for the macOS version it was installed on, so it is not used.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PRODUCT=WolverineBridge
PROFILE=${PROFILE:-$ROOT/app/profiles/developerid.provisionprofile}
LIBUSB_PREFIX=${LIBUSB_PREFIX:-$ROOT/build/libusb}
MIN_MACOS=15.0   # matches app/Package.swift and LSMinimumSystemVersion
APP=$ROOT/build/$PRODUCT.app
BIN=$APP/Contents/MacOS/$PRODUCT
FRAMEWORKS=$APP/Contents/Frameworks
DYLIB_NAME=libusb-1.0.0.dylib
ENTITLEMENTS=$ROOT/build/$PRODUCT-sign/entitlements.plist   # written by scripts/build-app.sh

die() {
    echo "error: $*" >&2
    exit 1
}

[[ -f "$PROFILE" ]] || die "provisioning profile not found: $PROFILE"
LIBUSB_DYLIB=$LIBUSB_PREFIX/lib/$DYLIB_NAME
[[ -f "$LIBUSB_DYLIB" ]] || die "libusb not found: $LIBUSB_DYLIB (build it for macOS $MIN_MACOS first)"
[[ -f "$LIBUSB_PREFIX/lib/pkgconfig/libusb-1.0.pc" ]] || die "libusb pkg-config file not found in $LIBUSB_PREFIX/lib/pkgconfig"

# The bundled libusb must not need a newer macOS than the app does.
LIBUSB_MINOS=$(vtool -show-build "$LIBUSB_DYLIB" | awk '/minos/ {print $2; exit}')
if [[ "$(printf '%s\n%s\n' "$MIN_MACOS" "$LIBUSB_MINOS" | sort -V | tail -n 1)" != "$MIN_MACOS" ]]; then
    die "$LIBUSB_DYLIB is built for macOS $LIBUSB_MINOS; rebuild it with -mmacosx-version-min=$MIN_MACOS"
fi

# A weak import is a symbol newer than the deployment target. libusb calls such symbols without a
# runtime check, so on older macOS the call jumps to NULL (pipe2 crashed the app on macOS 15).
LIBUSB_WEAK=$(dyld_info -imports "$LIBUSB_DYLIB" | grep 'weak-import' || true)
if [[ -n "$LIBUSB_WEAK" ]]; then
    die "$LIBUSB_DYLIB has weak imports that may be missing on macOS $MIN_MACOS; rebuild it (see BUILD.md):
$LIBUSB_WEAK"
fi

# 1. Build and assemble the app against this libusb. build-app.sh validates the profile, embeds it,
#    writes the entitlements, and signs; that signature is replaced below.
PKG_CONFIG_PATH="$LIBUSB_PREFIX/lib/pkgconfig" PROFILE="$PROFILE" make -C "$ROOT" bridge

# SwiftPM can reuse a binary linked against another libusb, so check what was linked.
OLD_INSTALL_NAME=$(otool -L "$BIN" | awk '/libusb/ {print $1; exit}')
[[ -n "$OLD_INSTALL_NAME" ]] || die "$BIN does not link libusb"
# The install name can hold "..", as libusb's configure --prefix was given, so compare resolved paths.
LINKED_DIR=$(cd "$(dirname "$OLD_INSTALL_NAME")" 2>/dev/null && pwd -P || true)
if [[ "$LINKED_DIR" != "$(cd "$LIBUSB_PREFIX/lib" && pwd -P)" ]]; then
    die "$BIN links $OLD_INSTALL_NAME, not the libusb in $LIBUSB_PREFIX; run: rm -rf app/.build, then retry"
fi

# 2. Copy libusb into the bundle and point the binary at it through @rpath.
mkdir -p "$FRAMEWORKS"
cp "$LIBUSB_DYLIB" "$FRAMEWORKS/$DYLIB_NAME"
chmod u+w "$FRAMEWORKS/$DYLIB_NAME"
install_name_tool -id "@rpath/$DYLIB_NAME" "$FRAMEWORKS/$DYLIB_NAME"
install_name_tool -change "$OLD_INSTALL_NAME" "@rpath/$DYLIB_NAME" "$BIN"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN"

# 3. Sign with the Developer ID certificate from the profile: inner library first, then the app.
#    Hardened runtime and a secure timestamp are required for notarization.
IDENTITY=$(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -n 1)
[[ -n "$IDENTITY" ]] || die "the profile's certificate is not a Developer ID Application certificate; use a Developer ID profile"
[[ -f "$ENTITLEMENTS" ]] || die "entitlements not found: $ENTITLEMENTS"
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$FRAMEWORKS/$DYLIB_NAME"
codesign --force --timestamp --options runtime --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$APP"

# 4. Verify the signature and that the binary loads the bundled libusb.
codesign --verify --strict --deep --verbose=2 "$APP"
if otool -L "$BIN" | grep -q /opt/homebrew; then
    die "$BIN still links a library from /opt/homebrew"
fi
"$BIN" --help >/dev/null || die "$BIN failed to start; check that it can load $FRAMEWORKS/$DYLIB_NAME"

echo "signed $APP for distribution ($IDENTITY)"
echo "next: VERSION=<version> ./scripts/make-dmg.sh"
