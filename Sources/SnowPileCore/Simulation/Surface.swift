import CoreGraphics

/// Snow lying on a horizontal edge (screen bottom or visible part of a window's top edge), stored as a heightmap.
/// Coordinates are CG (y grows downward), so snow grows toward smaller y. Volume is measured in pt².
public struct Surface: Sendable {
    public enum Kind: Hashable, Sendable {
        case ground(screen: Int)
        case window(number: Int)
    }

    public enum Edges: Sendable {
        /// Snow stays at the ends (screen corners).
        case walls
        /// Snow sliding past an end falls off and becomes flakes again.
        case spill
    }

    public static let columnWidth: CGFloat = 2
    /// Max height difference between neighbors, relative to the column width.
    public static let reposeRatio: CGFloat = 1.5

    public let kind: Kind
    public let minX: CGFloat
    public let baseY: CGFloat
    public let maxHeight: CGFloat
    public let edges: Edges
    public private(set) var heights: ContiguousArray<CGFloat>
    /// Changes whenever the heightmap changes, so the renderer only rebuilds when needed.
    public private(set) var version = 0

    public init(kind: Kind, minX: CGFloat, baseY: CGFloat, width: CGFloat, maxHeight: CGFloat, edges: Edges) {
        self.kind = kind
        self.minX = minX
        self.baseY = baseY
        self.maxHeight = maxHeight
        self.edges = edges
        let count = max(Int((width / Self.columnWidth).rounded(.up)), 1)
        heights = ContiguousArray(repeating: 0, count: count)
    }

    public var maxX: CGFloat { minX + CGFloat(heights.count) * Self.columnWidth }

    public var totalVolume: CGFloat { heights.reduce(0, +) * Self.columnWidth }

    public func column(at x: CGFloat) -> Int? {
        guard x >= minX, x < maxX else { return nil }
        return min(Int((x - minX) / Self.columnWidth), heights.count - 1)
    }

    public func topY(atColumn column: Int) -> CGFloat {
        baseY - heights[column]
    }

    /// Spreads `volume` evenly over all columns overlapping `minX..<maxX`. Returns the volume actually added.
    @discardableResult
    public mutating func deposit(volume: CGFloat, minX lowerX: CGFloat, maxX upperX: CGFloat) -> CGFloat {
        let first = Int(((max(lowerX, minX) - minX) / Self.columnWidth).rounded(.down))
        let last = Int(((min(upperX, maxX) - minX) / Self.columnWidth).rounded(.up)) - 1
        guard volume > 0, first <= last, first < heights.count, last >= 0 else { return 0 }

        let perColumn = volume / (CGFloat(last - first + 1) * Self.columnWidth)
        var added: CGFloat = 0
        for i in first...last {
            let new = min(heights[i] + perColumn, maxHeight)
            added += new - heights[i]
            heights[i] = new
        }
        if added > 0 { version &+= 1 }
        return added * Self.columnWidth
    }

    /// One relaxation pass of the sandpile rule. Returns the volume that slid off each end (always 0 with walls).
    @discardableResult
    public mutating func relax() -> (left: CGFloat, right: CGFloat) {
        let threshold = Self.reposeRatio * Self.columnWidth
        var changed = false
        let count = heights.count

        // Alternating sweep directions keeps piles symmetric.
        for i in 0..<(count - 1) { changed = settle(i, i + 1, threshold: threshold) || changed }
        for i in stride(from: count - 2, through: 0, by: -1) { changed = settle(i, i + 1, threshold: threshold) || changed }

        var spilled: (left: CGFloat, right: CGFloat) = (0, 0)
        if edges == .spill {
            spilled.left = spillOff(column: 0, threshold: threshold)
            spilled.right = spillOff(column: count - 1, threshold: threshold)
        }
        if changed || spilled.left > 0 || spilled.right > 0 { version &+= 1 }
        return spilled
    }

    public mutating func clear() {
        guard heights.contains(where: { $0 > 0 }) else { return }
        for i in heights.indices { heights[i] = 0 }
        version &+= 1
    }

    private mutating func settle(_ a: Int, _ b: Int, threshold: CGFloat) -> Bool {
        let diff = heights[a] - heights[b]
        guard abs(diff) > threshold else { return false }
        // Move half the excess so the pair ends up exactly at the threshold.
        let move = (abs(diff) - threshold) / 2
        if diff > 0 {
            heights[a] -= move
            heights[b] += move
        } else {
            heights[a] += move
            heights[b] -= move
        }
        return true
    }

    /// The ground beyond a spilling edge counts as height 0.
    private mutating func spillOff(column: Int, threshold: CGFloat) -> CGFloat {
        let excess = heights[column] - threshold
        guard excess > 0 else { return 0 }
        let move = excess / 2
        heights[column] -= move
        return move * Self.columnWidth
    }
}
