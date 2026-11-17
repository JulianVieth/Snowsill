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

    static func named(_ name: String) -> SnapshotScenario? { all.first { $0.name == name } }

    static let all: [SnapshotScenario] = [drag, close, ground]

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
