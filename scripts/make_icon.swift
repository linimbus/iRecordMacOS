import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.iconset")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func drawIcon(size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let s = CGFloat(size)
    let full = NSRect(x: 0, y: 0, width: s, height: s)
    let backgroundPath = NSBezierPath(roundedRect: full.insetBy(dx: s * 0.035, dy: s * 0.035), xRadius: s * 0.225, yRadius: s * 0.225)

    let background = NSGradient(colors: [
        NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.115, alpha: 1),
        NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.19, alpha: 1)
    ])
    background?.draw(in: backgroundPath, angle: -55)

    NSColor.white.withAlphaComponent(0.10).setStroke()
    backgroundPath.lineWidth = max(1, s * 0.008)
    backgroundPath.stroke()

    // Screen outline.
    let screen = NSRect(x: s * 0.20, y: s * 0.26, width: s * 0.60, height: s * 0.44)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: s * 0.075, yRadius: s * 0.075)
    NSColor.white.withAlphaComponent(0.055).setFill()
    screenPath.fill()
    NSColor.white.withAlphaComponent(0.62).setStroke()
    screenPath.lineWidth = max(1.2, s * 0.035)
    screenPath.stroke()

    // Stand.
    let stand = NSBezierPath()
    stand.move(to: NSPoint(x: s * 0.38, y: s * 0.175))
    stand.line(to: NSPoint(x: s * 0.62, y: s * 0.175))
    NSColor.white.withAlphaComponent(0.42).setStroke()
    stand.lineWidth = max(1, s * 0.028)
    stand.lineCapStyle = .round
    stand.stroke()

    // Recording dot with glow.
    let dotRect = NSRect(x: s * 0.545, y: s * 0.325, width: s * 0.25, height: s * 0.25)
    let glow = NSShadow()
    glow.shadowColor = NSColor.systemRed.withAlphaComponent(0.55)
    glow.shadowBlurRadius = s * 0.09
    glow.shadowOffset = .zero
    NSGraphicsContext.saveGraphicsState()
    glow.set()
    let dot = NSBezierPath(ovalIn: dotRect)
    NSGradient(colors: [
        NSColor(calibratedRed: 1.0, green: 0.33, blue: 0.29, alpha: 1),
        NSColor(calibratedRed: 0.78, green: 0.09, blue: 0.09, alpha: 1)
    ])?.draw(in: dot, angle: -70)
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.75).setStroke()
    let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: -s * 0.012, dy: -s * 0.012))
    ring.lineWidth = max(1, s * 0.012)
    ring.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let outputs: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (size, name) in outputs {
    guard let data = drawIcon(size: size) else {
        fputs("Failed to render \(name)\n", stderr)
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent(name))
}

print("Wrote \(outputs.count) icon images to \(outputDirectory.path)")
