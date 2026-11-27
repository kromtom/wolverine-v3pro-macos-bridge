#!/bin/bash
# Build, bundle, and sign build/WolverineBridge.app (make bridge; links build/libgipcore.a).
#
#   ./scripts/build-app.sh
#   PROFILE=path/to/profile.provisionprofile ./scripts/build-app.sh
#   BUNDLE_ID=com.example.wolverinebridge ./scripts/build-app.sh   # needed only for a wildcard App ID
#
# The profile must be a macOS App Development profile for your own App ID with the
# "HID Virtual Device (development)" capability, and must include this Mac.
# The bundle ID is taken from the profile's App ID unless BUNDLE_ID is set.
# The signing identity is the Apple Development certificate listed in the profile.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PRODUCT=WolverineBridge
BUNDLE_ID=${BUNDLE_ID:-}
PROFILE=${PROFILE:-$ROOT/app/profiles/development.provisionprofile}
APP=$ROOT/build/$PRODUCT.app
WORK=$ROOT/build/$PRODUCT-sign
ENTITLEMENT=com.apple.developer.hid.virtual.device

if [[ ! -f "$PROFILE" ]]; then
    cat >&2 <<EOF
error: provisioning profile not found: $PROFILE

Create it in the Apple Developer portal (Certificates, Identifiers & Profiles):
  1. Identifiers: an explicit App ID of your own (for example com.<you>.wolverinebridge),
     capability "HID Virtual Device (development)".
  2. Devices: register this Mac (Provisioning UDID from: system_profiler SPHardwareDataType).
  3. Profiles: macOS App Development, that App ID, your Apple Development certificate, this Mac.
Download it to app/profiles/development.provisionprofile, or pass PROFILE=<path>.
EOF
    exit 1
fi

mkdir -p "$WORK"
security cms -D -i "$PROFILE" > "$WORK/profile.plist"
UDID=$(system_profiler SPHardwareDataType | awk -F': ' '/Provisioning UDID/ {print $2}')

# Validate the profile, write entitlements, and print "<team id> <bundle id> <certificate SHA-1s>".
read -r TEAM BUNDLE_ID CERT_HASHES < <(/usr/bin/python3 -I - "$WORK/profile.plist" "$WORK/entitlements.plist" \
    "$BUNDLE_ID" "$ENTITLEMENT" "$UDID" <<'PY'
import datetime, hashlib, plistlib, sys
profile_path, ent_path, bundle_id, entitlement, udid = sys.argv[1:]
with open(profile_path, "rb") as f:
    p = plistlib.load(f)
def die(msg):
    sys.stderr.write(f"error: {msg}\n")
    sys.exit(1)
team = p["TeamIdentifier"][0]
ents = p.get("Entitlements", {})
app_id = ents.get("com.apple.application-identifier", "")
if not app_id.startswith(f"{team}."):
    die(f"profile App ID {app_id!r} does not start with team {team}")
profile_id = app_id[len(team) + 1:]
if not bundle_id:
    if profile_id.endswith("*"):
        die(f"profile has wildcard App ID {app_id!r}; set BUNDLE_ID=<your bundle id>")
    bundle_id = profile_id
elif not (bundle_id == profile_id or (profile_id.endswith("*") and bundle_id.startswith(profile_id[:-1]))):
    die(f"BUNDLE_ID {bundle_id!r} does not match profile App ID {app_id!r}")
if entitlement not in ents:
    die(f"profile does not grant {entitlement}; enable HID Virtual Device on the App ID and regenerate it")
if p["ExpirationDate"] < datetime.datetime.now(p["ExpirationDate"].tzinfo):
    die(f"profile expired on {p['ExpirationDate']}")
devices = p.get("ProvisionedDevices", [])
if udid and devices and udid not in devices:
    sys.stderr.write(f"warning: this Mac ({udid}) is not in the profile's ProvisionedDevices\n")
out = {
    "com.apple.application-identifier": f"{team}.{bundle_id}",
    "com.apple.developer.team-identifier": team,
    entitlement: ents[entitlement],
}
with open(ent_path, "wb") as f:
    plistlib.dump(out, f)
hashes = [hashlib.sha1(c).hexdigest().upper() for c in p.get("DeveloperCertificates", [])]
sys.stderr.write(f"profile: {p.get('Name')} team {team}, bundle {bundle_id}, expires {p['ExpirationDate']:%Y-%m-%d}\n")
print(team, bundle_id, ",".join(hashes))
PY
)
[[ -n "${TEAM:-}" ]] || exit 1

IDENTITY=""
for h in ${CERT_HASHES//,/ }; do
    if security find-identity -v -p codesigning | grep -q "$h"; then IDENTITY=$h; break; fi
done
if [[ -z "$IDENTITY" ]]; then
    echo "error: no keychain signing identity matches a certificate in the profile" >&2
    exit 1
fi

# Package.swift links the bridge against libusb from this directory.
LIBUSB_LIBDIR=$(pkg-config --variable=libdir libusb-1.0 2>/dev/null || echo /opt/homebrew/opt/libusb/lib)
export LIBUSB_LIBDIR
swift build -c release --package-path "$ROOT/app" --product "$PRODUCT"
BIN=$(swift build -c release --package-path "$ROOT/app" --show-bin-path)/$PRODUCT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/app/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/app/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"   # from scripts/make-icon.swift
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

codesign --force --timestamp=none --sign "$IDENTITY" \
    --entitlements "$WORK/entitlements.plist" "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "$ENTITLEMENT"
echo "built $APP (team $TEAM, bundle $BUNDLE_ID)"
echo "run:  $APP/Contents/MacOS/$PRODUCT --help"
