import AppKit
import Metal
import SnowPileCore

/// Snapshot mode (`SNOWPILE_SNAPSHOT=<scenario>`): runs a scripted scenario with simulated windows on a virtual
/// clock, renders offscreen and writes PNGs, so changes can be checked without looking at a real screen.
/// Output: one full frame and one 2× detail crop per capture time, a contact sheet and a stats log.
@MainActor
enum SnapshotRunner {
    static let frameRate: Double = 60
    static let renderScale: CGFloat = 2

    static func run(scenarioName: String, outputDirectory: URL?, debug: Bool) -> Int32 {
        guard let scenario = SnapshotScenario.named(scenarioName) else {
            let names = SnapshotScenario.all.map(\.name).joined(separator: ", ")
            FileHandle.standardError.write("Unbekanntes Szenario '\(scenarioName)'. Verfügbar: \(names)\n".data(using: .utf8)!)
            return 2
        }
        let out = outputDirectory ?? URL(fileURLWithPath: "snapshots/\(scenario.name)", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let screen = scenario.screen
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = SnowRenderer(device: device, pixelFormat: .bgra8Unorm, screenFrameCG: screen, config: scenario.config, debug: debug, seed: 42)
        else {
            FileHandle.standardError.write("Metal nicht verfügbar\n".data(using: .utf8)!)
            return 1
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(screen.width * renderScale), height: Int(screen.height * renderScale), mipmapped: false
        )
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return 1 }

        renderer.withSimulation { scenario.prepare(&$0) }
        var tracker = TrackerModel()
        var captures = scenario.captures.sorted()[...]
        var sheetFrames: [(time: Double, image: CGImage)] = []
        var log = "Szenario \(scenario.name): \(scenario.summary)\n"
        let frameCount = Int((scenario.duration * frameRate).rounded())

        for frame in 0...frameCount {
            let t = Double(frame) / frameRate
            let windows = scenario.windows(t)
            if tracker.shouldDeliver(windows, at: t) {
                renderer.setWindows(windows, timestamp: t)
            }
            renderer.advance(to: t)

            while let next = captures.first, next <= t + 0.5 / frameRate {
                captures.removeFirst()
                renderer.renderOffscreen(into: texture, viewSize: screen.size)
                guard let overlay = image(from: texture) else { continue }
                let full = composite(overlay: overlay, windows: windows, scenario: scenario)
                let stamp = String(format: "t%06.2f", t)
                write(full, to: out.appendingPathComponent("\(stamp).png"), scale: 1 / renderScale)
                if let focus = scenario.focus(t, windows) {
                    let crop = focus.intersection(screen)
                    let pixelRect = CGRect(
                        x: (crop.minX - screen.minX) * renderScale, y: (crop.minY - screen.minY) * renderScale,
                        width: crop.width * renderScale, height: crop.height * renderScale
                    ).integral
                    if let detail = full.cropping(to: pixelRect) {
                        write(detail, to: out.appendingPathComponent("detail_\(stamp).png"), scale: 1)
                    }
                }
                sheetFrames.append((t, full))
                log += String(format: "%6.2f s  ", t) + renderer.statsLine() + "\n"
            }
        }

        if let sheet = contactSheet(sheetFrames, screen: screen) {
            write(sheet, to: out.appendingPathComponent("sheet.png"), scale: 1)
        }
        try? log.write(to: out.appendingPathComponent("stats.txt"), atomically: true, encoding: .utf8)
        print(log, terminator: "")
        print("Ausgabe: \(out.path)")
        return 0
    }

    // MARK: - Images

    private static func image(from texture: MTLTexture) -> CGImage? {
        let width = texture.width, height = texture.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        // BGRA in memory with premultiplied alpha, like the transparent overlay window.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// Draws a fake desktop with the windows (back to front) and the overlay on top. Origin top left, like CG.
    private static func composite(overlay: CGImage, windows: [WindowInfo], scenario: SnapshotScenario) -> CGImage {
        let screen = scenario.screen
        let width = overlay.width, height = overlay.height
        let ctx = makeContext(width: width, height: height)!
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: renderScale, y: -renderScale)
        ctx.translateBy(x: -screen.minX, y: -screen.minY)

        let colors = [CGColor(srgbRed: 0.10, green: 0.16, blue: 0.32, alpha: 1), CGColor(srgbRed: 0.30, green: 0.36, blue: 0.55, alpha: 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: screen.minY), end: CGPoint(x: 0, y: screen.maxY), options: [])

        for window in windows.reversed() {
            let rect = window.bounds
            let path = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 24, color: CGColor(gray: 0, alpha: 0.5))
            ctx.addPath(path)
            ctx.setFillColor(CGColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(path)
            ctx.setStrokeColor(CGColor(gray: 0.35, alpha: 1))
            ctx.setLineWidth(1)
            ctx.strokePath()
            for (i, color) in [(1.0, 0.37, 0.34), (1.0, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
                ctx.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: rect.minX + 14 + CGFloat(i) * 20, y: rect.minY + 14, width: 12, height: 12))
            }
        }

        // The overlay image is already in pixel space; draw it 1:1 in an unscaled, unflipped context.
        ctx.resetClip()
        let base = ctx.ctm.inverted()
        ctx.concatenate(base)
        ctx.draw(overlay, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private static func contactSheet(_ frames: [(time: Double, image: CGImage)], screen: CGRect) -> CGImage? {
        guard !frames.isEmpty else { return nil }
        let columns = min(4, frames.count)
        let rows = (frames.count + columns - 1) / columns
        let thumbWidth = 480
        let thumbHeight = Int(CGFloat(thumbWidth) * screen.height / screen.width)
        let gap = 6
        let width = columns * thumbWidth + (columns + 1) * gap
        let height = rows * thumbHeight + (rows + 1) * gap
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        for (i, frame) in frames.enumerated() {
            let column = i % columns, row = i / columns
            let x = gap + column * (thumbWidth + gap)
            let y = height - (row + 1) * (thumbHeight + gap)
            let rect = CGRect(x: x, y: y, width: thumbWidth, height: thumbHeight)
            ctx.draw(frame.image, in: rect)
            let label = NSAttributedString(string: String(format: " %.2f s ", frame.time), attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .bold),
                .foregroundColor: NSColor.yellow,
                .backgroundColor: NSColor.black.withAlphaComponent(0.7),
            ])
            let line = CTLineCreateWithAttributedString(label)
            ctx.textPosition = CGPoint(x: rect.minX + 6, y: rect.maxY - 22)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()
    }

    private static func write(_ image: CGImage, to url: URL, scale: CGFloat) {
        var image = image
        if scale != 1 {
            let width = Int(CGFloat(image.width) * scale), height = Int(CGFloat(image.height) * scale)
            guard let ctx = makeContext(width: width, height: height) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = ctx.makeImage() else { return }
            image = scaled
        }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Mimics `WindowTracker`: 12 Hz polls while nothing changes, 60 Hz for 0.5 s after a change, and every poll
/// delivered while fast.
private struct TrackerModel {
    private var last: [WindowInfo]?
    private var lastChange = -Double.infinity
    private var nextPoll = 0.0

    mutating func shouldDeliver(_ windows: [WindowInfo], at t: Double) -> Bool {
        guard t + 1e-9 >= nextPoll else { return false }
        let changed = windows != last
        let fast = t - lastChange <= 0.5
        if changed {
            last = windows
            lastChange = t
        }
        nextPoll = t + ((changed || fast) ? 1.0 / 60 : 1.0 / 12)
        return changed || fast
    }
}
