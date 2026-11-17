import CoreGraphics
import Testing
@testable import SnowPileCore

@Suite struct OcclusionTests {
    @Test func nothingInFrontLeavesTheWholeEdge() {
        #expect(Occlusion.visibleSegments(minX: 100, maxX: 500, y: 200, occluders: []) == [100...500])
    }

    @Test func windowInFrontCutsAHole() {
        let front = CGRect(x: 200, y: 150, width: 100, height: 300)
        #expect(Occlusion.visibleSegments(minX: 100, maxX: 500, y: 200, occluders: [front]) == [100...200, 300...500])
    }

    @Test func windowCoveringTheLeftEndTrimsIt() {
        let front = CGRect(x: 0, y: 100, width: 150, height: 300)
        #expect(Occlusion.visibleSegments(minX: 100, maxX: 500, y: 200, occluders: [front]) == [150...500])
    }

    @Test func windowBelowTheEdgeDoesNotHideIt() {
        // Front window starts 3 pt below the edge: the snow on top of the back window stays visible.
        let front = CGRect(x: 200, y: 203, width: 100, height: 300)
        #expect(Occlusion.visibleSegments(minX: 100, maxX: 500, y: 200, occluders: [front]) == [100...500])
    }

    @Test func windowEndingAboveTheEdgeDoesNotHideIt() {
        let front = CGRect(x: 200, y: 0, width: 100, height: 150)
        #expect(Occlusion.visibleSegments(minX: 100, maxX: 500, y: 200, occluders: [front]) == [100...500])
    }

    @Test func overlappingOccludersMerge() {
        let a = CGRect(x: 150, y: 100, width: 100, height: 300)
        let b = CGRect(x: 220, y: 100, width: 100, height: 300)
        let c = CGRect(x: 400, y: 100, width: 50, height: 300)
        #expect(Occlusion.visibleSegments(minX: 100, maxX: 500, y: 200, occluders: [c, a, b]) == [100...150, 320...400, 450...500])
    }

    @Test func fullyCoveredEdgeHasNoSegments() {
        let front = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        #expect(Occlusion.visibleSegments(minX: 100, maxX: 500, y: 200, occluders: [front]).isEmpty)
    }

    // MARK: - In the simulation

    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func noSnowfall() -> SnowConfig {
        var config = SnowConfig()
        config.spawnRate = 0
        return config
    }

    @Test func backWindowColumnsBehindTheFrontWindowAreHidden() throws {
        var sim = SnowSimulation(config: noSnowfall(), bounds: screen, seed: 1)
        let front = WindowInfo(number: 1, ownerPID: 1, bounds: CGRect(x: 300, y: 150, width: 200, height: 300))
        let back = WindowInfo(number: 2, ownerPID: 2, bounds: CGRect(x: 100, y: 200, width: 600, height: 300))
        sim.setWindows([front, back], timestamp: 0)
        let surface = try #require(sim.surfaces.first { $0.kind == .window(number: 2) })
        #expect(surface.isHidden(surface.column(at: 400)!))
        #expect(!surface.isHidden(surface.column(at: 200)!))
        #expect(!surface.isHidden(surface.column(at: 600)!))
        let frontSurface = try #require(sim.surfaces.first { $0.kind == .window(number: 1) })
        #expect(!frontSurface.hasHidden)
    }

    @Test func flakesPassHiddenColumnsAndLandOnTheGround() throws {
        var sim = SnowSimulation(config: noSnowfall(), bounds: screen, seed: 2)
        // The front window covers the back window's whole top edge, but starts lower than it.
        let front = WindowInfo(number: 1, ownerPID: 1, bounds: CGRect(x: 0, y: 190, width: 1000, height: 600))
        let back = WindowInfo(number: 2, ownerPID: 2, bounds: CGRect(x: 100, y: 200, width: 600, height: 300))
        sim.setWindows([front, back], timestamp: 0)
        sim.addTestFlake(at: CGPoint(x: 400, y: 195), volume: 5)
        for _ in 0..<600 { sim.step(dt: 1.0 / 60) }
        let backSurface = try #require(sim.surfaces.first { $0.kind == .window(number: 2) })
        #expect(backSurface.totalVolume == 0)
        #expect(sim.surfaces[0].totalVolume > 4.99)
    }

    @Test func hiddenSnowReappearsWhenTheFrontWindowMovesAway() throws {
        var sim = SnowSimulation(config: noSnowfall(), bounds: screen, seed: 3)
        let back = WindowInfo(number: 2, ownerPID: 2, bounds: CGRect(x: 100, y: 200, width: 600, height: 300))
        sim.setWindows([back], timestamp: 0)
        sim.modifySurface(.window(number: 2)) { $0.deposit(volume: 2000, minX: 0, maxX: 1000) }
        let covering = WindowInfo(number: 1, ownerPID: 1, bounds: CGRect(x: 300, y: 150, width: 200, height: 300))
        sim.setWindows([covering, back], timestamp: 1)
        let hidden = try #require(sim.surfaces.first { $0.kind == .window(number: 2) })
        #expect(hidden.hasHidden)
        #expect(abs(hidden.totalVolume - 2000) < 1e-6)
        sim.setWindows([back], timestamp: 2)
        let visible = try #require(sim.surfaces.first { $0.kind == .window(number: 2) })
        #expect(!visible.hasHidden)
        #expect(abs(visible.totalVolume - 2000) < 1e-6)
    }
}
