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
            writer.add(.ball, at: ball.center, size: CGSize(width: ball.radius, height: ball.radius), seed: 0.37)
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
        // Leaving after a stop it backs off, still facing what it stopped at.
        let d = plow.phase == .leaving ? -plow.direction : plow.direction
        let ground = simulation.bounds.maxY - 1.5
        let bx = plow.x
        // Positions along the vehicle, measured backwards from the blade.
        func at(_ back: CGFloat, _ up: CGFloat) -> CGPoint { CGPoint(x: bx - d * back, y: ground - up) }

        let raised: CGFloat = plow.phase == .leaving ? 6 : 0
        // Arm from body to blade.
        writer.add(.rect, at: at(8, 9 + raised / 2), size: CGSize(width: 6, height: 2), color: steel)
        // Blade, slightly tilted forward.
        writer.add(.rect, at: at(2, 9 + raised), size: CGSize(width: 2.6, height: Plow.bladeHeight / 2), color: blade,
                   rotation: d * 0.12, param: 1.2)
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
    }
}
