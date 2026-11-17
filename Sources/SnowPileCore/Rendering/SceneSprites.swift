import CoreGraphics
import Foundation

/// Sprites for everything that isn't a falling particle or a snow surface: plow, snowballs, snowmen, icicles.
public enum SceneSprites {
    public static func write(_ simulation: SnowSimulation, into writer: inout SpriteWriter) {
        writePlow(simulation, into: &writer)
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

        // Wall of snow in front of the blade.
        let wall = plow.wallShape
        if wall.height > 0.5 {
            writer.add(.mound, at: CGPoint(x: bx + d * wall.halfWidth * 0.85, y: ground - wall.height / 2),
                       size: CGSize(width: wall.halfWidth, height: wall.height / 2),
                       seed: CGFloat(plow.run % 7) * 0.13)
        }

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
