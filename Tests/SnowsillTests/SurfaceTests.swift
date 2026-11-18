import CoreGraphics
import Testing
@testable import SnowsillCore

@Suite struct SurfaceTests {
    func makeSurface(width: CGFloat = 20, edges: Surface.Edges = .walls, maxHeight: CGFloat = 50) -> Surface {
        Surface(kind: .ground(screen: 0), minX: 100, baseY: 500, width: width, maxHeight: maxHeight, edges: edges)
    }

    @Test func columnsCoverWidthInTwoPointSteps() {
        let surface = makeSurface(width: 20)
        #expect(surface.heights.count == 10)
        #expect(surface.column(at: 100) == 0)
        #expect(surface.column(at: 101.9) == 0)
        #expect(surface.column(at: 102) == 1)
        #expect(surface.column(at: 119.9) == 9)
        #expect(surface.column(at: 120) == nil)
        #expect(surface.column(at: 99.9) == nil)
    }

    @Test func partialLastColumnIsIncluded() {
        #expect(makeSurface(width: 21).heights.count == 11)
    }

    /// With a fractional minX, `(maxX - minX) / columnWidth` can come out a hair above the column count.
    @Test func depositUpToRightEndStaysInBoundsForFractionalMinX() {
        for step in 0..<2000 {
            let minX = 1000 + CGFloat(step) * 0.0137
            var surface = Surface(kind: .window(number: 1), minX: minX, baseY: 300, width: 600, maxHeight: 14, edges: .spill)
            let added = surface.deposit(volume: 2.5, minX: surface.maxX - 3.5, maxX: surface.maxX + 0.1)
            #expect(added > 0)
        }
    }

    @Test func depositSpreadsVolumeOverCoveredColumns() {
        var surface = makeSurface()
        // x 104...108 covers columns 2, 3 (and touches 4 at exactly 108 -> excluded)
        surface.deposit(volume: 8, minX: 104, maxX: 108)
        #expect(surface.heights[2] == 2)
        #expect(surface.heights[3] == 2)
        #expect(surface.heights[4] == 0)
        #expect(surface.totalVolume == 8)
        #expect(surface.topY(atColumn: 2) == 498)
    }

    @Test func depositOutsideSurfaceIsIgnored() {
        var surface = makeSurface()
        let deposited = surface.deposit(volume: 8, minX: 0, maxX: 10)
        #expect(deposited == 0)
        #expect(surface.totalVolume == 0)
    }

    @Test func depositIsClampedAtMaxHeight() {
        var surface = makeSurface(maxHeight: 5)
        let deposited = surface.deposit(volume: 100, minX: 100, maxX: 102)
        #expect(surface.heights[0] == 5)
        #expect(deposited == 10)
    }

    @Test func depositBumpsVersion() {
        var surface = makeSurface()
        let before = surface.version
        surface.deposit(volume: 1, minX: 100, maxX: 102)
        #expect(surface.version != before)
    }

    @Test func relaxConservesVolumeWithWalls() {
        var surface = makeSurface()
        surface.deposit(volume: 80, minX: 110, maxX: 112)
        let before = surface.totalVolume
        for _ in 0..<500 {
            let spilled = surface.relax()
            #expect(spilled.left == 0 && spilled.right == 0)
        }
        #expect(abs(surface.totalVolume - before) < 1e-9)
    }

    @Test func relaxEnforcesAngleOfRepose() {
        var surface = makeSurface(width: 40)
        surface.deposit(volume: 80, minX: 118, maxX: 120)
        for _ in 0..<2000 { surface.relax() }
        let threshold = Surface.reposeRatio * Surface.columnWidth
        for i in 0..<(surface.heights.count - 1) {
            #expect(abs(surface.heights[i] - surface.heights[i + 1]) <= threshold + 1e-6)
        }
        // A pile, not a flat layer: the center stays highest.
        #expect(surface.heights[9] > surface.heights[0])
    }

    @Test func relaxDoesNothingOnGentleSlope() {
        var surface = makeSurface()
        surface.deposit(volume: 4, minX: 110, maxX: 112)
        surface.deposit(volume: 2, minX: 112, maxX: 114)
        let version = surface.version
        let heights = surface.heights
        surface.relax()
        #expect(surface.heights == heights)
        #expect(surface.version == version)
    }

    @Test func spillingEdgesDropSnowOffBothSides() {
        var surface = makeSurface(edges: .spill)
        surface.deposit(volume: 40, minX: 100, maxX: 102)
        surface.deposit(volume: 40, minX: 118, maxX: 120)
        let before = surface.totalVolume
        var left: CGFloat = 0
        var right: CGFloat = 0
        for _ in 0..<500 {
            let spilled = surface.relax()
            left += spilled.left
            right += spilled.right
        }
        #expect(left > 0)
        #expect(right > 0)
        #expect(abs(surface.totalVolume + left + right - before) < 1e-9)
        let threshold = Surface.reposeRatio * Surface.columnWidth
        #expect(surface.heights[0] <= threshold + 1e-6)
        #expect(surface.heights[9] <= threshold + 1e-6)
    }

    @Test func wallsKeepEdgeSnow() {
        var surface = makeSurface(edges: .walls)
        surface.deposit(volume: 40, minX: 100, maxX: 102)
        for _ in 0..<500 { surface.relax() }
        #expect(abs(surface.totalVolume - 40) < 1e-9)
    }

    @Test func clearRemovesAllSnow() {
        var surface = makeSurface()
        surface.deposit(volume: 40, minX: 100, maxX: 120)
        surface.clear()
        #expect(surface.totalVolume == 0)
    }

    // MARK: - Relocation

    func filled(_ heights: [CGFloat]) -> Surface {
        var surface = Surface(kind: .window(number: 1), minX: 100, baseY: 500,
                              width: CGFloat(heights.count) * 2, maxHeight: 50, edges: .spill)
        for (i, h) in heights.enumerated() where h > 0 {
            surface.deposit(volume: h * 2, minX: 100 + CGFloat(i) * 2, maxX: 102 + CGFloat(i) * 2)
        }
        return surface
    }

    @Test func relocateCarriesSnowAlong() {
        var surface = filled([1, 2, 3, 4])
        let geometry = surface.geometryVersion
        let lost = surface.relocate(minX: 300, baseY: 250, width: 8, columnOffset: 0)
        #expect(surface.minX == 300)
        #expect(surface.baseY == 250)
        #expect(Array(surface.heights) == [1, 2, 3, 4])
        #expect(lost.left == 0 && lost.right == 0)
        #expect(surface.geometryVersion != geometry)
    }

    @Test func positiveOffsetLosesSnowOnTheLeft() {
        var surface = filled([1, 2, 3, 4])
        // New column j takes old column j + 2: the layer slid left relative to the window.
        let lost = surface.relocate(minX: 100, baseY: 500, width: 8, columnOffset: 2)
        #expect(Array(surface.heights) == [3, 4, 0, 0])
        #expect(lost.left == CGFloat(6))
        #expect(lost.right == 0)
    }

    @Test func negativeOffsetLosesSnowOnTheRight() {
        var surface = filled([1, 2, 3, 4])
        let lost = surface.relocate(minX: 100, baseY: 500, width: 8, columnOffset: -1)
        #expect(Array(surface.heights) == [0, 1, 2, 3])
        #expect(lost.left == 0)
        #expect(lost.right == CGFloat(8))
    }

    @Test func shrinkingCutsOffTheRightEnd() {
        var surface = filled([1, 2, 3, 4])
        let lost = surface.relocate(minX: 100, baseY: 500, width: 4, columnOffset: 0)
        #expect(Array(surface.heights) == [1, 2])
        #expect(lost.right == CGFloat(14))
    }

    @Test func growingAddsEmptyColumns() {
        var surface = filled([1, 2])
        let lost = surface.relocate(minX: 96, baseY: 500, width: 10, columnOffset: -2)
        #expect(Array(surface.heights) == [0, 0, 1, 2, 0])
        #expect(lost.left == 0 && lost.right == 0)
    }

    @Test func relocateConservesVolume() {
        var surface = filled([5, 1, 7, 2, 9, 3])
        let before = surface.totalVolume
        let lost = surface.relocate(minX: 50, baseY: 400, width: 6, columnOffset: 2)
        #expect(abs(surface.totalVolume + lost.left + lost.right - before) < 1e-9)
    }
}
