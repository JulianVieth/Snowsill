import CoreGraphics
import Testing
@testable import SnowPileCore

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
}
