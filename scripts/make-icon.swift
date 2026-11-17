// Draws the app icon (night sky, snowflake, snow drift) into an .iconset folder for iconutil.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // macOS icon grid: 824 pt rounded square centered in 1024.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.14, blue: 0.3, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        CGColor(srgbRed: 0.07, green: 0.10, blue: 0.26, alpha: 1),
        CGColor(srgbRed: 0.20, green: 0.30, blue: 0.58, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])

    // Falling flakes.
    var seed: UInt64 = 7
    func rand() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 40) / CGFloat(1 << 24) }
    for _ in 0..<38 {
        let r = 5 + rand() * 9
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.55 + rand() * 0.4))
        ctx.fillEllipse(in: CGRect(x: 110 + rand() * 800, y: 260 + rand() * 650, width: r, height: r))
    }

    // Snow drift with a ragged top.
    let drift = CGMutablePath()
    drift.move(to: CGPoint(x: 100, y: 100))
    drift.addLine(to: CGPoint(x: 100, y: 255))
    var x: CGFloat = 100
    while x <= 924 {
        let y = 240 + 40 * sin(x / 150) + 14 * sin(x / 37) + 6 * sin(x / 9)
        drift.addLine(to: CGPoint(x: x, y: y))
        x += 6
    }
    drift.addLine(to: CGPoint(x: 924, y: 100))
    drift.closeSubpath()
    let snow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        CGColor(srgbRed: 0.76, green: 0.83, blue: 0.95, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.addPath(drift)
    ctx.clip()
    ctx.drawLinearGradient(snow, start: CGPoint(x: 0, y: 300), end: CGPoint(x: 0, y: 100), options: [])
    ctx.restoreGState()

    // The big snowflake: six arms with two pairs of branches each.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 575)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineCap(.round)
    ctx.setShadow(offset: .zero, blur: 18, color: CGColor(srgbRed: 0.6, green: 0.8, blue: 1, alpha: 0.7))
    for arm in 0..<6 {
        ctx.saveGState()
        ctx.rotate(by: CGFloat(arm) * .pi / 3)
        ctx.setLineWidth(34)
        ctx.move(to: .zero)
        ctx.addLine(to: CGPoint(x: 0, y: 250))
        ctx.strokePath()
        ctx.setLineWidth(26)
        for (at, length) in [(CGFloat(110), CGFloat(80)), (175, 58)] {
            for side in [CGFloat(-1), 1] {
                ctx.move(to: CGPoint(x: 0, y: at))
                ctx.addLine(to: CGPoint(x: side * length * 0.8, y: at + length * 0.75))
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: -42, y: -42, width: 84, height: 84))
    ctx.restoreGState()
    return ctx.makeImage()!
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    let rep = NSBitmapImageRep(cgImage: draw(size: points * scale))
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
