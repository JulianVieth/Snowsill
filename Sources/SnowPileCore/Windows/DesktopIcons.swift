import CoreGraphics

/// Desktop icons as snow surfaces. Their frames come from Finder via the Accessibility API (app side);
/// this part is pure logic.
public enum DesktopIcons {
    /// Window numbers for icons start here, far above real window numbers.
    static let numberBase = 1 << 40
    static let minSize: CGFloat = 16

    /// Turns icon frames (CG) into window entries behind everything else. An icon keeps its number as long as it
    /// stays in place, so its snow survives polls; moving it starts fresh (its old snow drops).
    public static func windows(from frames: [CGRect], ownerPID: Int32) -> [WindowInfo] {
        var seen: Set<Int> = []
        var result: [WindowInfo] = []
        for frame in frames where frame.width >= minSize && frame.height >= minSize {
            let key = Int(frame.minX.rounded()) &* 100_003 &+ Int(frame.minY.rounded())
            let number = numberBase + (key & 0xFF_FFFF_FFFF)
            guard seen.insert(number).inserted else { continue }
            result.append(WindowInfo(number: number, ownerPID: ownerPID, bounds: frame, isWidget: true, isDesktopIcon: true))
        }
        return result
    }
}
