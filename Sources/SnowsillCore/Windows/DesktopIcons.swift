import CoreGraphics

/// Desktop icons as snow surfaces. Their frames come from Finder via the Accessibility API (app side);
/// this part is pure logic.
public enum DesktopIcons {
    /// Window numbers for icons start here, far above real window numbers.
    static let numberBase = 1 << 40
    static let minSize: CGFloat = 16
    /// Finder's icon frame is larger than the artwork. Measured on macOS 26 (96 pt frame): the image starts
    /// about 7 pt below the frame's top and 15 pt in from each side.
    static let artworkTop: CGFloat = 0.07
    static let artworkSide: CGFloat = 0.155

    /// The part of an icon frame the artwork covers, where snow lies.
    public static func artwork(of frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + frame.width * artworkSide, y: frame.minY + frame.height * artworkTop,
               width: frame.width * (1 - 2 * artworkSide), height: frame.height * (1 - artworkTop))
    }

    /// Turns icon frames (CG) into window entries behind everything else. An icon keeps its number as long as it
    /// stays in place, so its snow survives polls; moving it starts fresh (its old snow drops).
    public static func windows(from frames: [CGRect], ownerPID: Int32) -> [WindowInfo] {
        var seen: Set<Int> = []
        var result: [WindowInfo] = []
        for frame in frames where frame.width >= minSize && frame.height >= minSize {
            let key = Int(frame.minX.rounded()) &* 100_003 &+ Int(frame.minY.rounded())
            let number = numberBase + (key & 0xFF_FFFF_FFFF)
            guard seen.insert(number).inserted else { continue }
            result.append(WindowInfo(number: number, ownerPID: ownerPID, bounds: artwork(of: frame), isWidget: true, isDesktopIcon: true))
        }
        return result
    }
}
