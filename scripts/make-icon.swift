// Render app/Resources/AppIcon.icns: an original game controller drawing in the style of the
// menu bar icon. SF Symbols may not be used in app icons, so the shape is drawn here instead.
//
//   swift scripts/make-icon.swift            # writes app/Resources/AppIcon.icns
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("app/Resources/AppIcon.icns")
let canvas = 1024

func context(_ size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// White controller silhouette with the D-pad and face buttons cut out (CG coordinates, y up).
func controller() -> CGImage {
    let c = context(canvas)
    c.setFillColor(.white)
    c.setStrokeColor(.white)

    // Body and grips. Filling them in one colour gives their union.
    c.addPath(CGPath(roundedRect: CGRect(x: 232, y: 450, width: 560, height: 200),
                     cornerWidth: 100, cornerHeight: 100, transform: nil))
    c.fillPath()
    c.setLineCap(.round)
    c.setLineWidth(190)
    for (top, bottom) in [((345.0, 530.0), (300.0, 395.0)), ((679.0, 530.0), (724.0, 395.0))] {
        c.move(to: CGPoint(x: top.0, y: top.1))
        c.addLine(to: CGPoint(x: bottom.0, y: bottom.1))
    }
    c.strokePath()

    // Cut-outs.
    c.setBlendMode(.clear)
    let dpad = CGPoint(x: 352, y: 545)
    for rect in [CGRect(x: dpad.x - 52, y: dpad.y - 17, width: 104, height: 34),
                 CGRect(x: dpad.x - 17, y: dpad.y - 52, width: 34, height: 104)] {
        c.addPath(CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil))
    }
    c.fillPath()
    let buttons = CGPoint(x: 672, y: 545)
    for (dx, dy) in [(0.0, 40.0), (0.0, -40.0), (40.0, 0.0), (-40.0, 0.0)] {
        c.fillEllipse(in: CGRect(x: buttons.x + dx - 19, y: buttons.y + dy - 19, width: 38, height: 38))
    }
    return c.makeImage()!
}

/// Full icon: rounded-square background on the macOS icon grid, controller on top.
func icon() -> CGImage {
    let c = context(canvas)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
    c.addPath(shape)
    c.setFillColor(CGColor(gray: 0.1, alpha: 1))
    c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(shape)
    c.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
        CGColor(srgbRed: 0.27, green: 0.82, blue: 0.29, alpha: 1),
        CGColor(srgbRed: 0.05, green: 0.45, blue: 0.13, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    c.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: CGColor(gray: 0, alpha: 0.3))
    c.draw(controller(), in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
    c.restoreGState()
    return c.makeImage()!
}

func png(_ image: CGImage, size: Int, to url: URL) throws {
    let c = context(size)
    c.interpolationQuality = .high
    c.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let master = icon()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(master, size: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(master, size: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(output.path)")
