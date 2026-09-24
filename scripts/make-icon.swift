// Renders the SubieScope app icon: a WR Blue gauge with a gold needle.
import AppKit

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with ~185 radius.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.2237
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.10, green: 0.23, blue: 0.52, alpha: 1).cgColor,
        NSColor(srgbRed: 0.03, green: 0.08, blue: 0.22, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])

    let r = body.width * 0.34
    // The dial is open at the bottom, so its visible shape spans from r above the hub
    // to r·sin 45° below it. Place the hub so that shape sits at the optical centre
    // (a touch above the geometric middle).
    let center = CGPoint(x: body.midX, y: body.midY - r * 0.07)
    let startAngle = CGFloat.pi * 1.25   // 225 degrees, lower left
    let endAngle = CGFloat.pi * -0.25    // -45 degrees, lower right

    // Track
    ctx.setLineCap(.round)
    ctx.setLineWidth(body.width * 0.055)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
    ctx.addArc(center: center, radius: r, startAngle: startAngle, endAngle: endAngle, clockwise: true)
    ctx.strokePath()

    // Filled sweep to ~75%
    let sweepEnd = startAngle - (startAngle - endAngle) * 0.74
    ctx.setStrokeColor(NSColor(srgbRed: 0.42, green: 0.70, blue: 1.0, alpha: 1).cgColor)
    ctx.addArc(center: center, radius: r, startAngle: startAngle, endAngle: sweepEnd, clockwise: true)
    ctx.strokePath()

    // Red zone
    ctx.setStrokeColor(NSColor(srgbRed: 0.93, green: 0.27, blue: 0.25, alpha: 1).cgColor)
    ctx.setLineWidth(body.width * 0.055)
    ctx.addArc(center: center, radius: r, startAngle: startAngle - (startAngle - endAngle) * 0.86, endAngle: endAngle, clockwise: true)
    ctx.strokePath()

    // Ticks
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
    ctx.setLineWidth(body.width * 0.012)
    for i in 0...8 {
        let a = startAngle - (startAngle - endAngle) * CGFloat(i) / 8
        let p1 = CGPoint(x: center.x + cos(a) * r * 0.70, y: center.y + sin(a) * r * 0.70)
        let p2 = CGPoint(x: center.x + cos(a) * r * 0.80, y: center.y + sin(a) * r * 0.80)
        ctx.move(to: p1); ctx.addLine(to: p2)
    }
    ctx.strokePath()

    // Gold needle
    let needleAngle = sweepEnd
    let tip = CGPoint(x: center.x + cos(needleAngle) * r * 0.92, y: center.y + sin(needleAngle) * r * 0.92)
    let perp = needleAngle + .pi / 2
    let w = body.width * 0.028
    ctx.setFillColor(NSColor(srgbRed: 0.93, green: 0.73, blue: 0.25, alpha: 1).cgColor)
    ctx.move(to: tip)
    ctx.addLine(to: CGPoint(x: center.x + cos(perp) * w, y: center.y + sin(perp) * w))
    ctx.addLine(to: CGPoint(x: center.x - cos(needleAngle) * r * 0.14, y: center.y - sin(needleAngle) * r * 0.14))
    ctx.addLine(to: CGPoint(x: center.x - cos(perp) * w, y: center.y - sin(perp) * w))
    ctx.closePath()
    ctx.fillPath()
    ctx.setFillColor(NSColor(srgbRed: 0.93, green: 0.73, blue: 0.25, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - w * 1.9, y: center.y - w * 1.9, width: w * 3.8, height: w * 3.8))
    ctx.setFillColor(NSColor(srgbRed: 0.03, green: 0.08, blue: 0.22, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - w * 0.8, y: center.y - w * 0.8, width: w * 1.6, height: w * 1.6))

    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
