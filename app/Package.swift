// swift-tools-version: 6.0
// WolverineBridge: Wolverine GIP input -> CoreHID virtual Xbox gamepad, rumble back to the pad.
// Build and sign the .app with `make bridge` from the repository root. The bridge links
// ../build/libgipcore.a, which `make bridge` builds first.
import Foundation
import PackageDescription

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
// Directory of libusb-1.0.dylib; scripts/build-app.sh passes it from pkg-config.
let libusbDir = Context.environment["LIBUSB_LIBDIR"] ?? "/opt/homebrew/opt/libusb/lib"

let package = Package(
    name: "WolverineBridge",
    platforms: [.macOS(.v15)],
    targets: [
        // Xbox Bluetooth HID descriptor and input report encoder.
        .target(name: "XboxHID", path: "Sources/XboxHID"),
        .executableTarget(
            name: "WolverineBridge",
            dependencies: ["XboxHID"],
            path: "Sources/WolverineBridge",
            // `import CGipCore` through src/core/module.modulemap.
            swiftSettings: [.unsafeFlags(["-I", "\(repo)/src/core"])],
            linkerSettings: [
                .unsafeFlags(["-L\(repo)/build", "-lgipcore", "-L\(libusbDir)", "-lusb-1.0"]),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
    ]
)
