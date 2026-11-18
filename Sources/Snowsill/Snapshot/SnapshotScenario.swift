import CoreGraphics
import SnowsillCore

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

    static let all: [SnapshotScenario] = [drag, close, ground, overlap, plow, snowman, icicles, secondary, widgets, wind, icons, carry]

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
    /// then closes that window, and finally the plow comes, stops in front of the first snowman and comes back
    /// from the other side to clear the rest.
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
            summary: "Kugeln rollen, zwei Schneemänner bauen (Boden und Fenster), Fenster bei 27 s schließen, ab 30 s Schaufler, danach Rückfahrt von rechts",
            duration: 56,
            captures: [3, 5, 9.5, 13.5, 17, 25, 27.3, 28, 31, 34, 36, 42, 46, 50, 56],
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

    /// Icicles grow under two snowy windows (faster than normal), then one is flicked sideways and they break off,
    /// the other closes.
    static let icicles: SnapshotScenario = {
        var config = SnowConfig()
        config.icicleDelay = 4
        config.icicleGrowth = 0.8
        config.icicleSpawnInterval = 1...3
        return SnapshotScenario(
            name: "icicles",
            summary: "Eiszapfen wachsen (beschleunigt), 30–30,25 s linkes Fenster schnell nach links, 33 s rechtes schließen",
            duration: 36,
            captures: [10, 20, 29.9, 30.1, 30.3, 30.6, 32.9, 33.2, 33.6, 36],
            windows: { t in
                var result: [WindowInfo] = []
                let x = lerp(260, 60, (t - 30) / 0.25)
                result.append(WindowInfo(number: 1, ownerPID: pid, bounds: CGRect(x: x, y: 260, width: 520, height: 300)))
                if t < 33 { result.append(WindowInfo(number: 2, ownerPID: pid, bounds: CGRect(x: 860, y: 340, width: 440, height: 260))) }
                return result
            },
            focus: { _, _ in CGRect(x: 40, y: 200, width: 1300, height: 500) },
            config: config,
            prepare: { sim in
                sim.setWindows([
                    WindowInfo(number: 1, ownerPID: pid, bounds: CGRect(x: 260, y: 260, width: 520, height: 300)),
                    WindowInfo(number: 2, ownerPID: pid, bounds: CGRect(x: 860, y: 340, width: 440, height: 260)),
                ], timestamp: 0)
                sim.fillWindow(1, height: 9)
                sim.fillWindow(2, height: 9)
            }
        )
    }()

    /// A secondary screen right of and above the main screen (negative CG y), with a window that spans both.
    /// Checks that everything is drawn in the right place in that screen's local coordinates.
    static let secondary = SnapshotScenario(
        name: "secondary",
        summary: "Zweitbildschirm bei x 1710, y -333; ein Fenster ragt links auf den Hauptbildschirm, eins liegt ganz drauf",
        screen: CGRect(x: 1710, y: -333, width: 1440, height: 900),
        duration: 40,
        captures: [20, 40],
        windows: { _ in [
            WindowInfo(number: 1, ownerPID: pid, bounds: CGRect(x: 1500, y: -100, width: 600, height: 400)),
            WindowInfo(number: 2, ownerPID: pid, bounds: CGRect(x: 2400, y: 0, width: 500, height: 350)),
        ] },
        focus: { _, _ in CGRect(x: 1710, y: -200, width: 1300, height: 300) },
        prepare: { $0.fillGround(height: 20) }
    )

    /// Two desktop widgets (like Calendar and Weather) top left, partly behind a window.
    static let widgets = SnapshotScenario(
        name: "widgets",
        summary: "Zwei Schreibtisch-Widgets oben links, das rechte teilweise hinter einem Fenster",
        duration: 40,
        captures: [20, 40],
        windows: { _ in [
            WindowInfo(number: 1, ownerPID: pid, bounds: CGRect(x: 300, y: 120, width: 700, height: 420)),
            WindowInfo(number: 24, ownerPID: pid + 9, bounds: CGRect(x: 188, y: 60, width: 180, height: 180), isWidget: true),
            WindowInfo(number: 23, ownerPID: pid + 9, bounds: CGRect(x: 8, y: 60, width: 180, height: 180), isWidget: true),
        ] },
        focus: { _, _ in CGRect(x: 0, y: 20, width: 700, height: 260) }
    )

    /// Stormy wind with gusts, a flurry around 87–95 s (seed 42), and melting once the snow stops at 100 s.
    static let wind: SnapshotScenario = {
        var config = SnowConfig()
        config.windStrength = 2.4
        config.meltRate = 0.05
        return SnapshotScenario(
            name: "wind",
            summary: "Stürmischer Wind mit Böen, Flurry ab ca. 87 s, ein Fenster",
            duration: 96,
            captures: [20, 50, 80, 86, 89, 91, 93, 96],
            windows: { _ in [WindowInfo(number: 1, ownerPID: pid, bounds: CGRect(x: 420, y: 340, width: 600, height: 380))] },
            focus: { _, _ in CGRect(x: 360, y: 260, width: 720, height: 160) },
            config: config
        )
    }()

    /// Desktop icons on the right edge (frames as Finder reports them), one partly behind a window.
    static let icons = SnapshotScenario(
        name: "icons",
        summary: "Drei Schreibtisch-Icons rechts, das unterste teilweise hinter einem Fenster",
        duration: 40,
        captures: [20, 40],
        windows: { _ in
            [WindowInfo(number: 1, ownerPID: pid, bounds: CGRect(x: 900, y: 300, width: 480, height: 300))]
                + DesktopIcons.windows(from: [
                    CGRect(x: 1340, y: 60, width: 64, height: 64),
                    CGRect(x: 1340, y: 170, width: 64, height: 64),
                    CGRect(x: 1340, y: 280, width: 64, height: 64),
                ], ownerPID: pid + 20)
        },
        focus: { _, _ in CGRect(x: 1100, y: 20, width: 340, height: 420) }
    )

    /// Builds a snowman on the ground, then grabs its bottom ball and carries the whole snowman onto a window.
    static let carry: SnapshotScenario = {
        let window = CGRect(x: 760, y: 380, width: 520, height: 300)
        let rolls: [(t: Double, from: CGFloat, to: CGFloat, drop: CGPoint)] = [
            (1, 60, 560, CGPoint(x: 300, y: 700)),
            (5, 60, 300, CGPoint(x: 300, y: 520)),
            (9, 580, 700, CGPoint(x: 302, y: 420)),
        ]
        return SnapshotScenario(
            name: "carry",
            summary: "Schneemann am Boden bauen, ab 14 s an der unteren Kugel packen und aufs Fenster tragen",
            duration: 20,
            captures: [13.5, 14.8, 15.6, 16.6, 20],
            windows: { _ in [WindowInfo(number: 5, ownerPID: pid, bounds: window)] },
            focus: { _, _ in CGRect(x: 200, y: 200, width: 1100, height: 700) },
            prepare: { $0.fillGround(height: 30) },
            mouse: { t in
                let ground: CGFloat = 900 - 12
                for roll in rolls where t >= roll.t && t < roll.t + 3.2 {
                    let u = t - roll.t
                    if u < 2 { return (CGPoint(x: roll.from + (roll.to - roll.from) * CGFloat(u / 2), y: ground), true) }
                    if u < 3 {
                        let k = CGFloat(u - 2)
                        return (CGPoint(x: roll.to + (roll.drop.x - roll.to) * k, y: ground + (roll.drop.y - ground) * k), true)
                    }
                    return (roll.drop, false)
                }
                // Grab the bottom ball (just above the ground snow) and carry the snowman over the window.
                if t >= 14 && t < 16.4 {
                    let k = CGFloat(min(max((t - 14.3) / 1.8, 0), 1))
                    let start = CGPoint(x: 300, y: 845)
                    let end = CGPoint(x: 1020, y: 250)
                    return (CGPoint(x: start.x + (end.x - start.x) * k, y: start.y + (end.y - start.y) * k), true)
                }
                if t >= 16.4 && t < 16.5 { return (CGPoint(x: 1020, y: 250), false) }
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
