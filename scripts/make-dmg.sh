#!/bin/bash
# Notarize build/WolverineBridge.app, then package it into a signed, notarized, stapled DMG.
#
#   ./scripts/make-dmg.sh
#   VERSION=1.0.0-rc.1 ./scripts/make-dmg.sh               # DMG name; default CFBundleShortVersionString
#   NOTARY_PROFILE=my-profile ./scripts/make-dmg.sh        # default wolverine-notary
#
# The app must already be signed for distribution: Developer ID Application certificate,
# hardened runtime (--options runtime), secure timestamp (--timestamp), the Developer ID
# provisioning profile embedded, and libusb bundled in Contents/Frameworks.
# The notary credentials must be stored once with:
#   xcrun notarytool store-credentials wolverine-notary --apple-id <id> --team-id <team> --password <app-specific>
# Output: build/WolverineBridge-<version>.dmg
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PRODUCT=WolverineBridge
APP=${APP:-$ROOT/build/$PRODUCT.app}
NOTARY_PROFILE=${NOTARY_PROFILE:-wolverine-notary}
ENTITLEMENT=com.apple.developer.hid.virtual.device
STAGE=$ROOT/build/dmg
ZIP=$ROOT/build/$PRODUCT-notarize.zip

die() {
    echo "error: $*" >&2
    exit 1
}

command -v create-dmg >/dev/null || die "create-dmg not found; install it with: brew install create-dmg"
[[ -d "$APP" ]] || die "app not found: $APP"

VERSION=${VERSION:-$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")}
DMG=$ROOT/build/$PRODUCT-$VERSION.dmg

# Check the app's signature before uploading anything, so notarization does not fail late.
codesign --verify --strict --deep "$APP" || die "app signature is not valid: $APP"
SIGN_INFO=$(codesign -dv --verbose=2 "$APP" 2>&1)
IDENTITY=$(sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' <<<"$SIGN_INFO" | head -n 1)
[[ -n "$IDENTITY" ]] || die "app is not signed with a Developer ID Application certificate"
grep -q 'flags=0x[0-9a-f]*(.*runtime' <<<"$SIGN_INFO" || die "app is not signed with the hardened runtime (--options runtime)"
grep -q '^Timestamp=' <<<"$SIGN_INFO" || die "app signature has no secure timestamp (--timestamp)"
ENTS=$(codesign -d --entitlements - "$APP" 2>/dev/null)
grep -q "$ENTITLEMENT" <<<"$ENTS" || die "app is not signed with the $ENTITLEMENT entitlement"
if grep -q get-task-allow <<<"$ENTS"; then
    die "app entitlements contain get-task-allow; notarization rejects it"
fi
[[ -f "$APP/Contents/embedded.provisionprofile" ]] || die "app has no embedded provisioning profile"
if otool -L "$APP/Contents/MacOS/$PRODUCT" | grep -q /opt/homebrew; then
    die "app links a library from /opt/homebrew; bundle it in Contents/Frameworks first"
fi
echo "signed by: $IDENTITY"

# Submit a file to the notary service and wait. On rejection, print the notary log and stop.
notarize() {
    local file=$1 out status id
    echo "notarizing $(basename "$file") (this can take several minutes)"
    out=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json) || true
    status=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))' <<<"$out" 2>/dev/null || true)
    id=$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))' <<<"$out" 2>/dev/null || true)
    if [[ "$status" != "Accepted" ]]; then
        echo "$out" >&2
        if [[ -n "$id" ]]; then
            xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        fi
        die "notarization of $(basename "$file") failed (status: ${status:-unknown})"
    fi
    echo "notarization accepted: $id"
}

# 1. Notarize and staple the app, so it passes Gatekeeper even when copied out of the DMG offline.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
rm -f "$ZIP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# 2. Build the DMG from a folder that holds only the stapled app.
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$PRODUCT.app"
create-dmg \
    --volname "$PRODUCT $VERSION" \
    --window-size 540 380 \
    --icon-size 128 \
    --icon "$PRODUCT.app" 140 180 \
    --app-drop-link 400 180 \
    --hide-extension "$PRODUCT.app" \
    "$DMG" "$STAGE"
rm -rf "$STAGE"

# 3. Sign, notarize, and staple the DMG.
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# 4. Gatekeeper checks, as a downloaded file would get them.
spctl -a -t open --context context:primary-signature -vv "$DMG"
spctl -a -vv "$APP"

echo "built $DMG"
shasum -a 256 "$DMG"
