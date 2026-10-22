// Draws the app icon and writes Resources/AppIcon.icns plus docs/icon.png.
// Usage: swift Scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func linearGradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

func drawIcon(in ctx: CGContext) {
    // macOS icon grid: 824pt body centered on a 1024pt canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x161A33))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: deep navy to indigo.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(
        linearGradient([color(0x2B2F6B), color(0x141733)]),
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.minY),
        options: []
    )
    // Soft glow behind the bars.
    ctx.drawRadialGradient(
        linearGradient([color(0x6C7CFF, 0.35), color(0x6C7CFF, 0)]),
        startCenter: CGPoint(x: body.midX, y: body.midY - 40), startRadius: 0,
        endCenter: CGPoint(x: body.midX, y: body.midY - 40), endRadius: 420,
        options: []
    )

    // Five bars, one per metric, like the menu bar columns.
    let bars: [(height: CGFloat, top: UInt32, bottom: UInt32)] = [
        (0.46, 0x5EE7FF, 0x2F8BFF), // CPU
        (0.30, 0x7AF0C8, 0x22B39A), // GPU
        (0.78, 0xFFC56B, 0xFF7A3D), // RAM (the one under pressure)
        (0.38, 0xC4A2FF, 0x7B5CFF), // Swap
        (0.60, 0x8FB8FF, 0x4C6BFF), // Disk
    ]
    let barWidth: CGFloat = 92
    let gap: CGFloat = 42
    let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
    let baseY: CGFloat = 270
    let maxHeight: CGFloat = 470
    var x = body.midX - totalWidth / 2

    for bar in bars {
        // Track.
        let track = CGRect(x: x, y: baseY, width: barWidth, height: maxHeight)
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: 26, cornerHeight: 26, transform: nil))
        ctx.setFillColor(color(0xFFFFFF, 0.07))
        ctx.fillPath()

        // Fill.
        let fill = CGRect(x: x, y: baseY, width: barWidth, height: maxHeight * bar.height)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: fill, cornerWidth: 26, cornerHeight: 26, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(
            linearGradient([color(bar.top), color(bar.bottom)]),
            start: CGPoint(x: fill.midX, y: fill.maxY),
            end: CGPoint(x: fill.midX, y: fill.minY),
            options: []
        )
        ctx.restoreGState()
        x += barWidth + gap
    }

    // Baseline under the bars.
    ctx.setFillColor(color(0xFFFFFF, 0.18))
    ctx.fill(CGRect(x: body.midX - totalWidth / 2 - 10, y: baseY - 30, width: totalWidth + 20, height: 8))

    // Glossy top highlight and hairline border.
    ctx.drawLinearGradient(
        linearGradient([color(0xFFFFFF, 0.14), color(0xFFFFFF, 0)]),
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.midY + 120),
        options: []
    )
    ctx.restoreGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(color(0xFFFFFF, 0.12))
    ctx.setLineWidth(3)
    ctx.strokePath()
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
try render(size: 512).write(to: root.appendingPathComponent("docs/icon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Resources/AppIcon.icns e docs/icon.png gerados" : "iconutil falhou")
