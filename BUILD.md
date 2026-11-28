# Building a release

This document describes how to build a WolverineBridge release: a notarized DMG that anyone can download from GitHub Releases and run without a provisioning profile of their own.

For a local development build, see [README.md](README.md#build-and-install) instead.

## What a release is

- `WolverineBridge.app`, signed with a **Developer ID Application** certificate, with the hardened runtime and a secure timestamp.
- A **Developer ID** provisioning profile embedded in the app. It grants `com.apple.developer.hid.virtual.device` on any Mac, so users do not need to register their Mac.
- libusb bundled in `Contents/Frameworks`, built for macOS 15.0. The app does not need Homebrew on the user's Mac.
- The app and the DMG are both notarized and stapled.
- Apple Silicon only, macOS 15.0 or later. macOS 15 is the lowest version possible, because CoreHID `HIDVirtualDevice` first shipped in macOS 15.

Two scripts do the work:

| Script | Does |
| --- | --- |
| [scripts/sign-release.sh](scripts/sign-release.sh) | Builds the app against `build/libusb`, bundles libusb, and signs the app with Developer ID. |
| [scripts/make-dmg.sh](scripts/make-dmg.sh) | Notarizes and staples the app, then builds, signs, notarizes, and staples the DMG. |

## One-time setup

Do these steps once per Mac that builds releases.

### 1. Install the tools

```bash
brew install libusb pkgconf create-dmg gh
gh auth login
```

Homebrew's libusb is used only for development builds. Releases use the libusb from step 6.

### 2. Get a Developer ID Application certificate

Only the Account Holder of the Apple Developer team can create this certificate.

1. Open Xcode, then **Xcode → Settings → Accounts**, and select your team.
2. Click **Manage Certificates**, click **+**, and select **Developer ID Application**.

Check that the certificate is in your keychain:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 3. Check the App ID capabilities

Apple must approve the **HID Virtual Device** capability for distribution before you can use it. Then:

1. Go to [Identifiers](https://developer.apple.com/account/resources/identifiers/list) and open the App ID that the development profile uses.
2. Make sure that both of these capabilities are ticked:
   - **HID Virtual Device** (the approved one), for the Developer ID profile.
   - **HID Virtual Device (development)**, for the development profile that `make bridge` uses.

Both grant the same entitlement, but each one goes only into its own kind of profile. If you untick the development capability, development builds stop with `profile does not grant com.apple.developer.hid.virtual.device`.

Changing the capabilities can make existing profiles invalid. If [Profiles](https://developer.apple.com/account/resources/profiles/list) lists a profile as **Invalid**, click **Edit**, then **Generate**, and download the profile again.

### 4. Create the Developer ID provisioning profile

1. Go to [Profiles](https://developer.apple.com/account/resources/profiles/list) and click **+**.
2. Under **Distribution**, select **Developer ID** and click **Continue**.
3. Select the App ID from step 3, then the Developer ID Application certificate from step 2.
4. Enter the profile name `WolverineBridgeDeveloperID`, click **Generate**, then **Download**.

Copy the profile into the repository. The `app/profiles/` folder is git-ignored, so the profile is never committed.

```bash
mkdir -p app/profiles
cp ~/Downloads/WolverineBridgeDeveloperID.provisionprofile app/profiles/developerid.provisionprofile
security cms -D -i app/profiles/developerid.provisionprofile | grep -A1 hid.virtual.device
```

The output must contain `com.apple.developer.hid.virtual.device` followed by `<true/>`. To keep the profile somewhere else, pass `PROFILE=/path/to/file.provisionprofile` to `scripts/sign-release.sh`.

### 5. Store the notary credentials

Create an app-specific password at [account.apple.com](https://account.apple.com) under **Sign-In and Security → App-Specific Passwords**. Then store it in the keychain:

```bash
xcrun notarytool store-credentials wolverine-notary \
    --apple-id <your Apple ID> --team-id <your team ID> --password <app-specific password>
```

`scripts/make-dmg.sh` uses the profile name `wolverine-notary`. To use another name, pass `NOTARY_PROFILE=<name>`.

### 6. Build libusb for macOS 15.0

Homebrew's libusb is built for the macOS version it was installed on. If you bundle it, the app can fail to load on older macOS versions. Build libusb yourself instead. Run these commands from the repository root:

```bash
mkdir -p third_party && cd third_party
curl -LO https://github.com/libusb/libusb/releases/download/v1.0.29/libusb-1.0.29.tar.bz2
tar xjf libusb-1.0.29.tar.bz2 && cd libusb-1.0.29
./configure --prefix="$PWD/../../build/libusb" --disable-dependency-tracking \
    CFLAGS="-O2 -mmacosx-version-min=15.0" LDFLAGS="-mmacosx-version-min=15.0"
make -j8 && make install
cd ../..
vtool -show-build build/libusb/lib/libusb-1.0.0.dylib | grep minos
```

The last command must print `minos 15.0`. To use a newer libusb, check the [libusb releases](https://github.com/libusb/libusb/releases) and change `1.0.29`.

`make clean` keeps `build/libusb`, but `rm -rf build` deletes it. In that case, run this step again.

libusb is licensed under LGPL-2.1. The app links it as a separate dylib, which users can replace. Include libusb's license or a link to its source with each release.

## Each release

### 1. Choose the version

| Where | Value | Example |
| --- | --- | --- |
| Git tag and DMG name | `vX.Y.Z`, or `vX.Y.Z-rc.N` for a release candidate | `v1.0.0-rc.1` |
| `CFBundleShortVersionString` in [app/Resources/Info.plist](app/Resources/Info.plist) | `X.Y.Z`, numbers only | `1.0.0` |
| `CFBundleVersion` in the same file | An integer. Increase it for every build that you publish. | `1` |

Commit the change to `Info.plist`.

### 2. Build and sign the app

```bash
./scripts/sign-release.sh
```

The script ends with `signed .../build/WolverineBridge.app for distribution`. It stops with an error if libusb, the profile, the signature, or the bundled library is wrong. See [Troubleshooting](#troubleshooting).

### 3. Notarize and build the DMG

```bash
VERSION=1.0.0-rc.1 ./scripts/make-dmg.sh
```

The script uploads the app to Apple's notary service, and then the DMG. Each upload usually takes a few minutes. The script ends with `built build/WolverineBridge-<VERSION>.dmg` and the DMG's SHA-256.

The first time you run it, macOS asks whether Terminal can control Finder. Allow it: `create-dmg` needs it to lay out the DMG window.

### 4. Test on a clean Mac

Use a Mac or a user account without Homebrew libusb. Test on macOS 15 if you can.

1. Download the DMG through a browser, so that macOS marks it as downloaded from the internet.
2. Open the DMG and drag **WolverineBridge** to **Applications**.
3. Open the app. macOS must not show a Gatekeeper warning beyond the usual "downloaded from the internet" prompt.
4. Connect the controller. Check that the menu shows the handshake, then the input counts, and that the virtual pad appears. See [app/README.md](app/README.md) for how to verify the virtual pad.

### 5. Publish on GitHub

Do not commit the DMG. Attach it to a GitHub release instead:

```bash
git tag -a v1.0.0-rc.1 -m "WolverineBridge 1.0.0 RC 1"
git push origin v1.0.0-rc.1
gh release create v1.0.0-rc.1 build/WolverineBridge-1.0.0-rc.1.dmg --prerelease \
    --title "WolverineBridge 1.0.0 RC 1" \
    --notes "Apple Silicon, macOS 15 or later. Notarized. SHA-256: <hash from make-dmg.sh>"
```

For a final release, leave out `--prerelease`. Build the final release again with its own version, rather than publishing the RC's DMG, because the version is in the DMG's file name and volume name.

## Troubleshooting

| Message | Cause and fix |
| --- | --- |
| `ld: warning: building for macOS-15.0, but linking with dylib '/opt/homebrew/...' which was built for newer version` | The build used Homebrew's libusb. Build libusb in `build/libusb` (setup step 6), then use `scripts/sign-release.sh`, not `make bridge`. |
| `... is built for macOS <version>; rebuild it with -mmacosx-version-min=15.0` | `build/libusb` was built without the deployment target. Do setup step 6 again. |
| `... links ..., not the libusb in ...; run: rm -rf app/.build, then retry` | SwiftPM reused a binary that was linked against another libusb. Run `rm -rf app/.build` and run the script again. |
| `the profile's certificate is not a Developer ID Application certificate` | `PROFILE` points at a development profile. Use the Developer ID profile from setup step 4. |
| `profile expired on ...` | Generate the Developer ID profile again (setup step 4). |
| `app is not signed with the hardened runtime` or `... has no secure timestamp` | `make-dmg.sh` was given an app that `scripts/sign-release.sh` did not sign. Run `scripts/sign-release.sh` first. |
| `notarization of ... failed (status: Invalid)` | The script prints Apple's notary log, which names each file and problem. Fix them, then run both scripts again. |
| The installed release shows `Allow WolverineBridge in Accessibility settings` and no prompt appears | This Mac still has the Accessibility (PostEvent) grant made for a development build. macOS ties the grant to the certificate, so it does not cover the Developer ID build. Run `tccutil reset All <your bundle id>` (`reset PostEvent` is not enough: PostEvent is decided by the Accessibility entry), then open the app and allow the prompt. See [app/README.md](app/README.md#run). |
