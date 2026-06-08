import AppKit
import Foundation

// Renders the app icon — a thin white ring on a dark rounded square, matching the menu-bar
// circle — and packs it into an .icns with iconutil.
//
// Usage: swift scripts/make_app_icon.swift [output.icns]   (default: Resources/AppIcon.icns)

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/Resources/AppIcon.icns"

let entries: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func renderPNG(px: Int) -> Data {
    let dimension = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Dark rounded-square background, with a small transparent margin for macOS masking.
    let margin = dimension * 0.06
    let bgRect = NSRect(x: margin, y: margin, width: dimension - 2 * margin, height: dimension - 2 * margin)
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: bgRect.width * 0.22, yRadius: bgRect.width * 0.22)
    NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
    bg.fill()

    // Thin white ring, centred.
    let ringDiameter = dimension * 0.52
    let lineWidth = max(1, dimension * 0.035)
    let ringRect = NSRect(
        x: (dimension - ringDiameter) / 2,
        y: (dimension - ringDiameter) / 2,
        width: ringDiameter, height: ringDiameter
    ).insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
    let ring = NSBezierPath(ovalIn: ringRect)
    ring.lineWidth = lineWidth
    NSColor.white.setStroke()
    ring.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = NSTemporaryDirectory() + "Meeting2-\(UUID().uuidString).iconset"
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for entry in entries {
    try! renderPNG(px: entry.px).write(to: URL(fileURLWithPath: "\(iconset)/\(entry.name).png"))
}

try? FileManager.default.createDirectory(
    atPath: (outputPath as NSString).deletingLastPathComponent,
    withIntermediateDirectories: true
)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", outputPath]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(atPath: iconset)
print("Wrote \(outputPath)")
