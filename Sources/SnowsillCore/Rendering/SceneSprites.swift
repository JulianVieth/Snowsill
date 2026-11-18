import CoreGraphics
import Foundation

/// Sprites for everything that isn't a falling particle or a snow surface: plow, snowballs, snowmen, icicles.
public enum SceneSprites {
    /// `windowOffset` is the predicted drawing offset of a window's surface, so things on it stay glued to it.
    public static func write(
        _ simulation: SnowSimulation, into writer: inout SpriteWriter, windowOffset: (Int) -> CGVector = { _ in .zero }
    ) {
        writePlow(simulation, into: &writer)
        writeIcicles(simulation, into: &writer, windowOffset: windowOffset)
        for stack in simulation.stacks where !stack.isHidden {
            var offset = CGVector.zero
            if case .window(let number, _) = stack.support { offset = windowOffset(number) }
            writeStack(stack, offset: offset, into: &writer)
        }
        if let ball = simulation.held {
            writeStack(ball.asStack, offset: .zero, into: &writer)
        }
    }

    // MARK: - Icicles

    static let ice = SIMD4<Float>(0.70, 0.90, 0.98, 0.95)

    static func writeIcicles(_ simulation: SnowSimulation, into writer: inout SpriteWriter, windowOffset: (Int) -> CGVector) {
        simulation.forEachIcicleGroup { number, bounds, icicles in
            let offset = windowOffset(number)
            for icicle in icicles where !icicle.isHidden && icicle.length >= 1 {
                let x = bounds.minX + icicle.offset + offset.dx
                // Starts a hair inside the window so it visibly hangs from the edge.
                let top = bounds.maxY + offset.dy - 0.5
                writer.add(.icicle, at: CGPoint(x: x, y: top + icicle.length / 2),
                           size: CGSize(width: icicle.width / 2, height: icicle.length / 2), color: ice, seed: icicle.seed)
            }
        }
    }

    // MARK: - Snowballs and snowmen

    static let coal = SIMD4<Float>(0.10, 0.10, 0.12, 1)
    static let carrot = SIMD4<Float>(0.98, 0.50, 0.10, 1)
    static let twig = SIMD4<Float>(0.40, 0.26, 0.15, 1)
    static let hatColor = SIMD4<Float>(0.12, 0.12, 0.14, 1)
    static let hatBand = SIMD4<Float>(0.78, 0.12, 0.14, 1)
    static let scarf = SIMD4<Float>(0.82, 0.16, 0.18, 1)

    static func writeStack(_ stack: SnowStack, offset: CGVector, into writer: inout SpriteWriter) {
        let radii = stack.radii
        let centers = stack.centers.map { CGPoint(x: $0.x + offset.dx, y: $0.y + offset.dy) }
        for (i, (c, r)) in zip(centers, radii).enumerated() {
            writer.add(.ball, at: c, size: CGSize(width: r, height: r), seed: CGFloat(stack.id % 17) * 0.11 + CGFloat(i) * 0.3)
        }
        guard stack.isSnowman, radii.count >= 3 else { return }
        let body = centers[1], rb = radii[1]
        let head = centers[2], rh = radii[2]

        // Arms: twigs from the sides of the middle ball, angled up, with a small fork.
        for side in [CGFloat(-1), 1] {
            let length = rb * 1.25
            let angle: CGFloat = 0.45 // up from horizontal
            let start = CGPoint(x: body.x + side * rb * 0.75, y: body.y - rb * 0.15)
            let mid = CGPoint(x: start.x + side * cos(angle) * length / 2, y: start.y - sin(angle) * length / 2)
            writer.add(.rect, at: mid, size: CGSize(width: length / 2, height: max(rb * 0.05, 0.9)), color: twig,
                       rotation: -side * angle, param: 0.6)
            let tip = CGPoint(x: start.x + side * cos(angle) * length * 0.8, y: start.y - sin(angle) * length * 0.8)
            let fork = CGPoint(x: tip.x + side * length * 0.08, y: tip.y - length * 0.12)
            writer.add(.rect, at: fork, size: CGSize(width: length * 0.13, height: max(rb * 0.04, 0.7)), color: twig,
                       rotation: -side * 1.2, param: 0.5)
        }
        // Buttons down the middle ball.
        for k in 0..<3 {
            let y = body.y - rb * 0.42 + CGFloat(k) * rb * 0.42
            writer.add(.disc, at: CGPoint(x: body.x, y: y), size: CGSize(width: max(rb * 0.085, 1), height: 0), color: coal)
        }
        // Scarf around the neck.
        let neckY = head.y + rh * 0.88
        writer.add(.rect, at: CGPoint(x: head.x, y: neckY), size: CGSize(width: rh * 0.92, height: max(rh * 0.16, 1.2)),
                   color: scarf, param: rh * 0.15)
        writer.add(.rect, at: CGPoint(x: head.x + rh * 0.45, y: neckY + rh * 0.38), size: CGSize(width: max(rh * 0.14, 1), height: rh * 0.36),
                   color: scarf, rotation: -0.15, param: rh * 0.08)
        // Eyes.
        for side in [CGFloat(-1), 1] {
            writer.add(.disc, at: CGPoint(x: head.x + side * rh * 0.33, y: head.y - rh * 0.22),
                       size: CGSize(width: max(rh * 0.11, 0.9), height: 0), color: coal)
        }
        // Carrot nose, pointing to the right.
        let noseLength = rh * 0.75
        writer.add(.triangle, at: CGPoint(x: head.x + noseLength / 2 + rh * 0.05, y: head.y + rh * 0.05),
                   size: CGSize(width: noseLength / 2, height: max(rh * 0.14, 1)), color: carrot)
        // Smile of coal bits.
        for k in -2...2 {
            let a = CGFloat(k) * 0.32
            let p = CGPoint(x: head.x + sin(a) * rh * 0.5, y: head.y + rh * 0.38 + (1 - cos(a)) * -rh * 0.35)
            writer.add(.disc, at: p, size: CGSize(width: max(rh * 0.06, 0.7), height: 0), color: coal)
        }
        // Top hat with a red band.
        let brimY = head.y - rh * 0.78
        writer.add(.rect, at: CGPoint(x: head.x, y: brimY), size: CGSize(width: rh * 0.82, height: max(rh * 0.07, 0.8)),
                   color: hatColor, param: rh * 0.05)
        let crownHeight = rh * 0.62
        writer.add(.rect, at: CGPoint(x: head.x, y: brimY - crownHeight / 2), size: CGSize(width: rh * 0.52, height: crownHeight / 2),
                   color: hatColor, param: rh * 0.04)
        writer.add(.rect, at: CGPoint(x: head.x, y: brimY - rh * 0.13), size: CGSize(width: rh * 0.53, height: max(rh * 0.06, 0.6)),
                   color: hatBand)
    }

    // MARK: - Plow

    static let orange = SIMD4<Float>(0.96, 0.52, 0.10, 1)
    static let darkOrange = SIMD4<Float>(0.80, 0.38, 0.06, 1)
    static let blade = SIMD4<Float>(0.98, 0.78, 0.16, 1)
    static let tire = SIMD4<Float>(0.11, 0.11, 0.13, 1)
    static let hub = SIMD4<Float>(0.62, 0.63, 0.66, 1)
    static let glass = SIMD4<Float>(0.72, 0.86, 0.96, 1)
    static let steel = SIMD4<Float>(0.32, 0.33, 0.36, 1)

    static func writePlow(_ simulation: SnowSimulation, into writer: inout SpriteWriter) {
        let plow = simulation.plow
        guard plow.isActive else { return }
        let d = plow.direction
        let ground = simulation.bounds.maxY - 1.5
        let bx = plow.x
        // Positions along the vehicle, measured backwards from the blade.
        func at(_ back: CGFloat, _ up: CGFloat) -> CGPoint { CGPoint(x: bx - d * back, y: ground - up) }

        // Body.
        writer.add(.rect, at: at(36, 12), size: CGSize(width: 24, height: 7), color: orange, param: 3)
        // Black-and-yellow stripe along the body.
        writer.add(.rect, at: at(36, 9), size: CGSize(width: 24, height: 1.2), color: SIMD4(0.15, 0.15, 0.15, 1))
        // Cabin with window.
        writer.add(.rect, at: at(50, 25), size: CGSize(width: 11, height: 8), color: darkOrange, param: 2.5)
        writer.add(.rect, at: at(47.5, 26), size: CGSize(width: 6.5, height: 4.5), color: glass, param: 1.5)
        // Hood vent and exhaust.
        writer.add(.rect, at: at(26, 20), size: CGSize(width: 1.2, height: 3), color: steel)
        // Beacon light: blinks.
        let blink = Float(0.55 + 0.45 * sin(simulation.time * 9))
        writer.add(.disc, at: at(50, 35), size: CGSize(width: 2.6, height: 2.6), color: SIMD4(1, 0.65, 0.1, blink))
        // Wheels.
        for back in [CGFloat(20), 56] {
            let spin = CGFloat(plow.x / 6) * d
            writer.add(.disc, at: at(back, 6), size: CGSize(width: 6.5, height: 6.5), color: tire)
            writer.add(.disc, at: at(back, 6), size: CGSize(width: 2.6, height: 2.6), color: hub)
            writer.add(.rect, at: at(back, 6), size: CGSize(width: 4.4, height: 0.7), color: hub, rotation: spin)
        }
        writeBlade(height: max(plow.bladeTop, Plow.bladeHeight), at: at, into: &writer)
    }

    static let bladeShadow = SIMD4<Float>(0.80, 0.56, 0.08, 1)
    static let bladeLight = SIMD4<Float>(1.00, 0.88, 0.36, 1)
    static let endPlate = SIMD4<Float>(0.86, 0.62, 0.10, 1)

    /// A rounded bar from `a` to `b` (CG points), `thickness` across.
    static func bar(_ a: CGPoint, _ b: CGPoint, thickness: CGFloat, color: SIMD4<Float>, into writer: inout SpriteWriter) {
        let length = hypot(b.x - a.x, b.y - a.y)
        writer.add(.rect, at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2),
                   size: CGSize(width: length / 2 + thickness / 2, height: thickness / 2), color: color,
                   rotation: atan2(b.y - a.y, b.x - a.x), param: thickness / 2)
    }

    /// The moldboard seen from the side: a curve open to the front, the steel cutting edge at the ground, the top
    /// rolled forward so the snow tumbles ahead rather than over it. `place(back, up)` places points relative to the
    /// blade's front edge, where the scraped snow stands as a straight face.
    static func writeBlade(height: CGFloat, at place: (CGFloat, CGFloat) -> CGPoint, into writer: inout SpriteWriter) {
        // Arc of a circle whose center lies ahead of the blade, from -55° (foot) to +62° (lip).
        let low = -55 * CGFloat.pi / 180, high = 62 * CGFloat.pi / 180
        let radius = height / (sin(high) - sin(low))
        let centerUp = -radius * sin(low)
        let centerBack = -radius * cos(low)
        func profile(_ t: CGFloat) -> (back: CGFloat, up: CGFloat) {
            let angle = low + (high - low) * t
            return (centerBack + radius * cos(angle), centerUp + radius * sin(angle))
        }
        let segments = 9
        let raw = (0...segments).map { profile(CGFloat($0) / CGFloat(segments)) }
        // The hollow touches the snow face, foot and lip reach into the wall: the snow fills the curve.
        // The face is drawn a little behind the blade's front edge (smoothing), so the hollow sits 3.5 pt back.
        let shift = (raw.map(\.back).max() ?? 0) - 3.5
        func at(_ back: CGFloat, _ up: CGFloat) -> CGPoint { place(back - shift, up) }
        let points = raw
        let deepest = raw.map(\.back).max() ?? 0

        // Push frame from the body to the back of the blade, and a lift cylinder up to its upper half.
        bar(place(14, 8), at(deepest + 1, height * 0.3), thickness: 2.2, color: steel, into: &writer)
        if height > 26 {
            let mount = place(24, 17), end = at(deepest, height * 0.62)
            bar(mount, end, thickness: 1.8, color: steel, into: &writer)
            let sleeve = CGPoint(x: mount.x + (end.x - mount.x) * 0.45, y: mount.y + (end.y - mount.y) * 0.45)
            bar(mount, sleeve, thickness: 2.8, color: hub, into: &writer)
        }
        // Ribs on the back.
        for t in [CGFloat(0.3), 0.62] {
            let p = profile(t)
            bar(at(p.back, p.up), at(p.back + 3, p.up), thickness: 1.4, color: steel, into: &writer)
        }
        // End plate: the crescent between the curve and the vertical at its hollow. Hides the straight snow face
        // where the curve reaches forward.
        for (p0, p1) in zip(points, points.dropFirst()) {
            let curve = (p0.back + p1.back) / 2
            guard deepest - curve > 0.5 else { continue }
            let up = (p0.up + p1.up) / 2
            let strip = abs(p1.up - p0.up) / 2 + 0.6
            let back = deepest + 1.2
            writer.add(.rect, at: at((back + curve) / 2, up), size: CGSize(width: (back - curve) / 2, height: strip),
                       color: endPlate)
        }
        // Moldboard: a darker back, a lighter face slightly in front of it.
        let thickness = max(2.6, height * 0.08)
        for (i, pair) in zip(points, points.dropFirst()).enumerated() {
            bar(at(pair.0.back + 0.6, pair.0.up), at(pair.1.back + 0.6, pair.1.up),
                thickness: thickness, color: bladeShadow, into: &writer)
            let shade = 0.5 + 0.5 * sin(CGFloat(i) / CGFloat(segments - 1) * .pi)
            let face = bladeLight * Float(shade) + blade * Float(1 - shade)
            bar(at(pair.0.back - 0.3, pair.0.up), at(pair.1.back - 0.3, pair.1.up),
                thickness: thickness * 0.55, color: face, into: &writer)
        }
        // Rolled lip on top and the steel cutting edge on the ground.
        if let top = points.last {
            writer.add(.disc, at: at(top.back - 0.2, top.up), size: CGSize(width: thickness * 0.65, height: 0), color: blade)
        }
        bar(at(1.5, 1.2), at(-1.5, 1.2), thickness: 2.2, color: steel, into: &writer)
    }
}
