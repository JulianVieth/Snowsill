import CoreGraphics

public enum Occlusion {
    /// Visible x ranges of the horizontal edge `minX...maxX` at `y` (CG), after removing every window in front.
    /// A window hides the edge where it covers the point just above it, where the snow lies.
    public static func visibleSegments(minX: CGFloat, maxX: CGFloat, y: CGFloat, occluders: [CGRect]) -> [ClosedRange<CGFloat>] {
        guard minX < maxX else { return [] }
        let probeY = y - 1
        var holes: [ClosedRange<CGFloat>] = []
        for rect in occluders where rect.minY <= probeY && rect.maxY > probeY && rect.maxX > minX && rect.minX < maxX {
            holes.append(max(rect.minX, minX)...min(rect.maxX, maxX))
        }
        guard !holes.isEmpty else { return [minX...maxX] }
        holes.sort { $0.lowerBound < $1.lowerBound }

        var visible: [ClosedRange<CGFloat>] = []
        var cursor = minX
        for hole in holes {
            if hole.lowerBound > cursor { visible.append(cursor...hole.lowerBound) }
            cursor = max(cursor, hole.upperBound)
        }
        if cursor < maxX { visible.append(cursor...maxX) }
        return visible
    }
}
