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
    /// Unique per surface instance, so a recreated surface (moved window) is never mistaken for the old one.
    public let id: Int
    public private(set) var minX: CGFloat
    public private(set) var baseY: CGFloat
    public let maxHeight: CGFloat
    public let edges: Edges
    public private(set) var heights: ContiguousArray<CGFloat>
    /// Columns covered by a window in front. They keep their snow but receive none and aren't drawn.
    public private(set) var hidden: ContiguousArray<Bool>
    /// Whether any column is hidden, so the common case skips the per-column check.
    public private(set) var hasHidden = false
    /// Changes whenever the heightmap changes, so the renderer only rebuilds when needed.
    public private(set) var version = 0
    /// Changes when position or size change. The renderer rebuilds immediately then, so snow sticks to a moving window.
    public private(set) var geometryVersion = 0
    /// Spilled volume not yet turned into flakes.
    var spillCredit: (left: CGFloat, right: CGFloat) = (0, 0)

    public init(kind: Kind, minX: CGFloat, baseY: CGFloat, width: CGFloat, maxHeight: CGFloat, edges: Edges, id: Int = 0) {
        self.kind = kind
        self.id = id
        self.minX = minX
        self.baseY = baseY
        self.maxHeight = maxHeight
        self.edges = edges
        let count = max(Int((width / Self.columnWidth).rounded(.up)), 1)
        heights = ContiguousArray(repeating: 0, count: count)
        hidden = ContiguousArray(repeating: false, count: count)
    }

    @inline(__always)
    public func isHidden(_ column: Int) -> Bool {
        hasHidden && hidden[column]
    }

    /// Marks every column whose center lies outside all `visible` x ranges as hidden.
    public mutating func setVisible(_ visible: [ClosedRange<CGFloat>]) {
        var any = false
        var changed = false
        for i in hidden.indices {
            let x = minX + (CGFloat(i) + 0.5) * Self.columnWidth
            let isHidden = !visible.contains { $0.contains(x) }
            if hidden[i] != isHidden { hidden[i] = isHidden; changed = true }
            any = any || isHidden
        }
        hasHidden = any
        if changed { version &+= 1 }
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
        // Clamped: with a fractional minX the division can land a hair above the column count.
        let last = min(Int(((min(upperX, maxX) - minX) / Self.columnWidth).rounded(.up)) - 1, heights.count - 1)
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

    /// Moves the surface to a new position and width, carrying the snow along.
    /// New column `j` takes old column `j + columnOffset`. Old columns that no longer fit are returned as lost volume
    /// per side, so the caller can let them fall off.
    @discardableResult
    public mutating func relocate(minX newMinX: CGFloat, baseY newBaseY: CGFloat, width: CGFloat, columnOffset: Int) -> (left: CGFloat, right: CGFloat) {
        let newCount = max(Int((width / Self.columnWidth).rounded(.up)), 1)
        var lost: (left: CGFloat, right: CGFloat) = (0, 0)
        var newHeights = ContiguousArray<CGFloat>(repeating: 0, count: newCount)
        for k in heights.indices where heights[k] > 0 {
            let j = k - columnOffset
            if j < 0 {
                lost.left += heights[k] * Self.columnWidth
            } else if j >= newCount {
                lost.right += heights[k] * Self.columnWidth
            } else {
                newHeights[j] = heights[k]
            }
        }
        heights = newHeights
        if hidden.count != newCount || hasHidden {
            hidden = ContiguousArray(repeating: false, count: newCount)
            hasHidden = false
        }
        minX = newMinX
        baseY = newBaseY
        geometryVersion &+= 1
        version &+= 1
        return lost
    }

    public mutating func clear() {
        spillCredit = (0, 0)
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
