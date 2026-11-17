import CoreGraphics
import SnowPileCore

/// A scripted sequence of window states for snapshot mode. All rects in CG coordinates (origin top left).
struct SnapshotScenario {
    var name: String
    var summary: String
    var screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    var duration: Double
    var captures: [Double]
    /// Front-to-back window list at time t, as the tracker would report it.
    var windows: (Double) -> [WindowInfo]
    /// Region for the 2× detail crop, or nil for none.
    var focus: (Double, [WindowInfo]) -> CGRect?
    var config = SnowConfig()
    /// Runs once before the first frame, e.g. to pre-fill the ground.
    var prepare: (inout SnowSimulation) -> Void = { _ in }
    /// Scripted mouse: position (CG) and whether the button is down at time t, or nil for no mouse.
    var mouse: (Double) -> (point: CGPoint, down: Bool)? = { _ in nil }

    static func named(_ name: String) -> SnapshotScenario? { all.first { $0.name == name } }

    static let all: [SnapshotScenario] = [drag, close, ground, overlap, plow, snowman]

    private static let pid: Int32 = 4242

    /// Area just around a window's top edge, where its snow lies.
    private static func topEdge(_ windows: [WindowInfo]) -> CGRect? {
        guard let w = windows.first?.bounds else { return nil }
        return CGRect(x: w.minX - 60, y: w.minY - 70, width: w.width + 120, height: 130)
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        a + (b - a) * CGFloat(min(max(t, 0), 1))
    }

    /// Snow piles up on a window, then it is dragged slowly, flicked fast sideways, stands still and is dragged up.
    static let drag = SnapshotScenario(
        name: "drag",
        summary: "40 s schneien, 40–42 s langsam rechts (150 pt/s), 43–43,3 s schnell links (1500 pt/s), 45–45,5 s nach oben",
        duration: 49,
        captures: [10, 25, 40, 40.5, 41, 42, 43.0, 43.1, 43.2, 43.3, 43.6, 44.2, 45.2, 45.5, 46.5, 49],
        windows: { t in
            var x: CGFloat = 420, y: CGFloat = 340
            if t > 40 { x = lerp(420, 720, (t - 40) / 2) }
            if t > 43 { x = lerp(720, 270, (t - 43) / 0.3) }
            if t > 45 { y = lerp(340, 240, (t - 45) / 0.5) }
            return [WindowInfo(number: 1, ownerPID: pid, bounds: CGRect(x: x, y: y, width: 600, height: 380))]
        },
        focus: { _, windows in topEdge(windows) }
    )

    /// Snow piles up on a window, then the window closes and the whole layer falls down.
    static let close = SnapshotScenario(
        name: "close",
        summary: "40 s schneien, bei 40 s Fenster schließen, Schnee fällt zu Boden",
        duration: 46,
        captures: [39.9, 40.05, 40.2, 40.4, 40.7, 41.0, 41.5, 42.0, 43.0, 44.0, 46.0],
        windows: { t in
            t < 40 ? [WindowInfo(number: 1, ownerPID: pid, bounds: CGRect(x: 420, y: 340, width: 600, height: 380))] : []
        },
        focus: { _, _ in CGRect(x: 360, y: 260, width: 720, height: 640) }
    )

    /// Two overlapping windows: snow must not lie on the part of the back window that the front one covers.
    /// Then the front window moves away and reveals the hidden part.
    static let overlap = SnapshotScenario(
        name: "overlap",
        summary: "Vorderes Fenster verdeckt hinteres, 40 s schneien, 40–41 s vorderes Fenster nach unten rechts",
        duration: 44,
        captures: [20, 40, 40.5, 41, 42, 44],
        windows: { t in
            let fx = lerp(560, 900, (t - 40) / 1), fy = lerp(260, 420, (t - 40) / 1)
            return [
                WindowInfo(number: 2, ownerPID: pid, bounds: CGRect(x: fx, y: fy, width: 420, height: 300)),
                WindowInfo(number: 1, ownerPID: pid + 1, bounds: CGRect(x: 240, y: 320, width: 600, height: 380)),
            ]
        },
        focus: { _, _ in CGRect(x: 180, y: 200, width: 900, height: 200) }
    )

    /// Deep ground snow, then the plow crosses from left to right and pushes the wall off the screen.
    static let plow: SnapshotScenario = {
        var config = SnowConfig()
        config.plowInterval = 2
        config.plowThreshold = 20
        return SnapshotScenario(
            name: "plow",
            summary: "Boden mit ca. 32 pt vorbefüllt, ab 2 s fährt der Schaufler von links nach rechts",
            duration: 18,
            captures: [1.5, 3, 5, 7, 9, 11, 12.5, 13.5, 15, 18],
            windows: { _ in [] },
            focus: { _, _ in CGRect(x: 0, y: 760, width: 1440, height: 140) },
            config: config,
            prepare: { $0.fillGround(height: 32) }
        )
    }()

    /// Rolls three balls out of deep ground snow and stacks them into a snowman, builds a second one on a window,
    /// then closes that window, and finally the plow comes and stops in front of the first snowman.
    static let snowman: SnapshotScenario = {
        var config = SnowConfig()
        config.plowInterval = 30
        config.plowThreshold = 10
        let window = CGRect(x: 820, y: 420, width: 460, height: 300)
        // (start time, from x, to x, drop point): roll along the ground, lift, carry, release.
        let rolls: [(t: Double, from: CGFloat, to: CGFloat, drop: CGPoint)] = [
            (1, 80, 640, CGPoint(x: 420, y: 700)),
            (6, 80, 420, CGPoint(x: 420, y: 520)),
            (10, 680, 840, CGPoint(x: 422, y: 420)),
            (14, 700, 1100, CGPoint(x: 1000, y: 300)),
            (18, 700, 900, CGPoint(x: 1000, y: 250)),
            (21.5, 1150, 1260, CGPoint(x: 1002, y: 200)),
        ]
        return SnapshotScenario(
            name: "snowman",
            summary: "Kugeln rollen, zwei Schneemänner bauen (Boden und Fenster), Fenster bei 27 s schließen, ab 30 s Schaufler",
            duration: 42,
            captures: [3, 5, 9.5, 13.5, 17, 25, 27.3, 28, 31, 34, 36, 42],
            windows: { t in t < 27 ? [WindowInfo(number: 5, ownerPID: pid, bounds: window)] : [] },
            focus: { t, _ in t < 29 ? CGRect(x: 300, y: 180, width: 1000, height: 720) : CGRect(x: 0, y: 500, width: 1440, height: 400) },
            config: config,
            prepare: { $0.fillGround(height: 30) },
            mouse: { t in
                for roll in rolls where t >= roll.t && t < roll.t + 3.2 {
                    let u = t - roll.t
                    let ground: CGFloat = 900 - 12
                    if u < 2 {
                        let x = roll.from + (roll.to - roll.from) * CGFloat(u / 2)
                        return (CGPoint(x: x, y: ground), true)
                    }
                    if u < 3 {
                        let k = CGFloat(u - 2)
                        let p = CGPoint(x: roll.to + (roll.drop.x - roll.to) * k, y: ground + (roll.drop.y - ground) * k)
                        return (p, true)
                    }
                    return (roll.drop, false)
                }
                return nil
            }
        )
    }()

    /// Only the ground, to judge how the drift builds up over time.
    static let ground = SnapshotScenario(
        name: "ground",
        summary: "Kein Fenster, 180 s Schneefall auf den Boden",
        duration: 180,
        captures: [30, 60, 90, 120, 150, 180],
        windows: { _ in [] },
        focus: { _, _ in CGRect(x: 0, y: 760, width: 720, height: 140) }
    )
}
