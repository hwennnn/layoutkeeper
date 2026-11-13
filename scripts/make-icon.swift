// Renders the LayoutKeeper app icon: a dark rounded tile with two "remembered" windows
// snapping into place. Usage: swift scripts/make-icon.swift <out.icns>
import AppKit

func draw(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }
    let s = size / 1024
    let inset: CGFloat = 100 * s
    let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = 185 * s

    // Tile with gradient
    let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    path.addClip()
    let gradient = NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.30, alpha: 1),
                                       NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.14, alpha: 1)])!
    gradient.draw(in: tile, angle: -90)

    // Soft glow
    ctx.saveGState()
    let glow = NSGradient(colors: [NSColor(calibratedRed: 0.28, green: 0.62, blue: 1.0, alpha: 0.35), .clear])!
    glow.draw(fromCenter: CGPoint(x: tile.midX + 120 * s, y: tile.maxY - 60 * s), radius: 0,
              toCenter: CGPoint(x: tile.midX + 120 * s, y: tile.maxY - 60 * s), radius: 520 * s, options: [])
    ctx.restoreGState()

    func window(_ r: CGRect, alpha: CGFloat, accent: NSColor) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 40 * s, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        let body = NSBezierPath(roundedRect: r, xRadius: 44 * s, yRadius: 44 * s)
        NSColor(calibratedWhite: 0.96, alpha: alpha).setFill()
        body.fill()
        ctx.restoreGState()
        // title bar
        ctx.saveGState()
        body.addClip()
        let bar = CGRect(x: r.minX, y: r.maxY - 80 * s, width: r.width, height: 80 * s)
        accent.withAlphaComponent(alpha).setFill()
        bar.fill()
        for (i, c) in [NSColor.systemRed, NSColor.systemYellow, NSColor.systemGreen].enumerated() {
            c.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: CGRect(x: r.minX + (34 + CGFloat(i) * 46) * s, y: bar.midY - 15 * s, width: 30 * s, height: 30 * s)).fill()
        }
        ctx.restoreGState()
        // content lines
        NSColor(calibratedWhite: 0.78, alpha: alpha).setFill()
        for i in 0..<3 {
            let w = r.width * (i == 2 ? 0.45 : 0.7)
            NSBezierPath(roundedRect: CGRect(x: r.minX + 40 * s, y: r.maxY - (150 + CGFloat(i) * 62) * s, width: w, height: 22 * s), xRadius: 11 * s, yRadius: 11 * s).fill()
        }
    }

    // Back window (ghost: where it was) and front window (snapped)
    window(CGRect(x: tile.minX + 150 * s, y: tile.minY + 250 * s, width: 440 * s, height: 340 * s), alpha: 0.35,
           accent: NSColor(calibratedRed: 0.45, green: 0.50, blue: 0.62, alpha: 1))
    window(CGRect(x: tile.minX + 290 * s, y: tile.minY + 150 * s, width: 470 * s, height: 360 * s), alpha: 1,
           accent: NSColor(calibratedRed: 0.24, green: 0.55, blue: 0.98, alpha: 1))

    // Pin badge
    let badge = CGRect(x: tile.maxX - 250 * s, y: tile.maxY - 250 * s, width: 150 * s, height: 150 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 18 * s, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    NSColor(calibratedRed: 0.99, green: 0.62, blue: 0.20, alpha: 1).setFill()
    NSBezierPath(ovalIn: badge).fill()
    ctx.restoreGState()
    NSColor.white.setStroke()
    let check = NSBezierPath()
    check.lineWidth = 18 * s; check.lineCapStyle = .round; check.lineJoinStyle = .round
    check.move(to: CGPoint(x: badge.minX + 40 * s, y: badge.midY))
    check.line(to: CGPoint(x: badge.minX + 66 * s, y: badge.midY - 26 * s))
    check.line(to: CGPoint(x: badge.maxX - 38 * s, y: badge.midY + 30 * s))
    check.stroke()

    img.unlockFocus()
    return img
}

func png(_ img: NSImage, _ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.icns"
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("LayoutKeeper.iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! png(draw(CGFloat(px)), px).write(to: tmp.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", out]
try! p.run(); p.waitUntilExit()
try! png(draw(1024), 1024).write(to: URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension("png"))
print(p.terminationStatus == 0 ? "wrote \(out)" : "iconutil failed")
exit(p.terminationStatus)
