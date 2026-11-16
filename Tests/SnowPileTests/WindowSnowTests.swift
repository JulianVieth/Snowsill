import CoreGraphics
import Testing
@testable import SnowPileCore

@Suite struct WindowSnowTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let window = WindowInfo(number: 42, ownerPID: 10, bounds: CGRect(x: 100, y: 200, width: 400, height: 300))

    func config(spawnRate: Double = 40, maxFlakes: Int = 2500) -> SnowConfig {
        var config = SnowConfig()
        config.spawnRate = spawnRate
        config.maxFlakes = maxFlakes
        return config
    }

    func windowSurface(_ sim: SnowSimulation, _ number: Int = 42) -> Surface? {
        sim.surfaces.first { $0.kind == .window(number: number) }
    }

    func activeIndices(_ sim: SnowSimulation) -> Set<Int> {
        Set(sim.flakes.indices.filter { sim.flakes[$0].isActive })
    }

    @Test func surfaceSitsOnTopEdgeInsetFromCorners() throws {
        var sim = SnowSimulation(config: config(), bounds: screen, seed: 1)
        sim.setWindows([window])
        let surface = try #require(windowSurface(sim))
        #expect(surface.baseY == 200)
        #expect(surface.minX == 100 + SnowConfig().windowCornerInset)
        #expect(surface.maxX == 500 - SnowConfig().windowCornerInset)
        #expect(surface.maxHeight == SnowConfig().windowMaxHeight)
        #expect(surface.edges == .spill)
    }

    @Test func surfaceIsClippedToScreen() throws {
        var sim = SnowSimulation(config: config(), bounds: screen, seed: 2)
        sim.setWindows([WindowInfo(number: 1, ownerPID: 10, bounds: CGRect(x: -100, y: 200, width: 400, height: 300))])
        let surface = try #require(windowSurface(sim, 1))
        #expect(surface.minX == 0)
        #expect(surface.maxX == 300 - SnowConfig().windowCornerInset)
    }

    @Test func windowsWithTopEdgeOffScreenGetNoSurface() {
        var sim = SnowSimulation(config: config(), bounds: screen, seed: 3)
        sim.setWindows([
            WindowInfo(number: 1, ownerPID: 10, bounds: CGRect(x: 100, y: -10, width: 400, height: 300)),
            WindowInfo(number: 2, ownerPID: 10, bounds: CGRect(x: 100, y: 900, width: 400, height: 300)),
            WindowInfo(number: 3, ownerPID: 10, bounds: CGRect(x: 1200, y: 100, width: 400, height: 300)),
        ])
        #expect(sim.surfaces.allSatisfy { if case .ground = $0.kind { true } else { false } })
    }

    @Test func snowLandsOnWindow() throws {
        var sim = SnowSimulation(config: config(), bounds: screen, seed: 4)
        sim.setWindows([window])
        for _ in 0..<(60 * 20) { sim.step(dt: 1.0 / 60) }
        let surface = try #require(windowSurface(sim))
        #expect(surface.totalVolume > 0)
        #expect(surface.heights.max()! <= SnowConfig().windowMaxHeight)
    }

    @Test func unchangedOrJitteringWindowKeepsSnow() throws {
        var sim = SnowSimulation(config: config(), bounds: screen, seed: 5)
        sim.setWindows([window])
        sim.modifySurface(.window(number: 42)) { $0.deposit(volume: 500, minX: 200, maxX: 300) }
        sim.setWindows([window])
        var jittered = window
        jittered.bounds.origin.x += 0.3
        sim.setWindows([jittered])
        #expect(try #require(windowSurface(sim)).totalVolume == 500)
    }

    @Test func movingWindowTurnsAllSnowIntoFlakes() throws {
        var sim = SnowSimulation(config: config(spawnRate: 0), bounds: screen, seed: 6)
        sim.setWindows([window])
        sim.modifySurface(.window(number: 42)) { $0.deposit(volume: 3000, minX: 112, maxX: 488) }
        let before = activeIndices(sim)

        var moved = window
        moved.bounds.origin.y += 30
        sim.setWindows([moved])

        let surface = try #require(windowSurface(sim))
        #expect(surface.baseY == 230)
        #expect(surface.totalVolume == 0)
        let clumps = activeIndices(sim).subtracting(before)
        #expect(!clumps.isEmpty)
        let volume = clumps.reduce(CGFloat(0)) { $0 + sim.flakes[$1].snowVolume }
        #expect(abs(volume - 3000) < 1e-6)
        for i in clumps {
            let p = sim.flakes[i].position
            #expect(p.x >= 100 && p.x <= 500)
            #expect(p.y >= 200 - SnowConfig().windowMaxHeight - 1 && p.y <= 200)
        }
    }

    @Test func closingWindowTurnsSnowIntoFlakes() {
        var sim = SnowSimulation(config: config(spawnRate: 0), bounds: screen, seed: 7)
        sim.setWindows([window])
        sim.modifySurface(.window(number: 42)) { $0.deposit(volume: 800, minX: 112, maxX: 488) }
        sim.setWindows([])
        #expect(windowSurface(sim) == nil)
        let volume = sim.flakes.filter(\.isActive).reduce(CGFloat(0)) { $0 + $1.snowVolume }
        #expect(abs(volume - 800) < 1e-6)
    }

    @Test func shakenSnowFallsDownEventually() {
        var sim = SnowSimulation(config: config(spawnRate: 0), bounds: screen, seed: 8)
        sim.setWindows([window])
        sim.modifySurface(.window(number: 42)) { $0.deposit(volume: 800, minX: 112, maxX: 488) }
        sim.setWindows([])
        for _ in 0..<(60 * 20) { sim.step(dt: 1.0 / 60) }
        #expect(sim.activeCount == 0)
        // Everything ended up on the ground (walls keep it there).
        #expect(abs(sim.surfaces[0].totalVolume - 800) < 1e-6)
    }

    @Test func snowSlidingOffAnEdgeBecomesFlakes() {
        var sim = SnowSimulation(config: config(spawnRate: 0), bounds: screen, seed: 9)
        sim.setWindows([window])
        sim.modifySurface(.window(number: 42)) { $0.deposit(volume: 200, minX: 112, maxX: 132) }
        for _ in 0..<30 { sim.step(dt: 1.0 / 60) }

        let surface = windowSurface(sim)!
        let airborne = sim.flakes.filter(\.isActive)
        #expect(!airborne.isEmpty)
        #expect(airborne.allSatisfy { $0.position.x < surface.minX })
        let inAir = airborne.reduce(CGFloat(0)) { $0 + $1.snowVolume }
        // Not yet converted spill is held back as credit, at most one flake's worth.
        let total = surface.totalVolume + inAir
        #expect(total <= 200 + 1e-6)
        #expect(total > 200 - SnowSimulation.flakeVolume(radius: SnowConfig().radiusRange.upperBound, config: SnowConfig()))
    }

    @Test func regularSnowfallLeavesReserveForShakenSnow() {
        var sim = SnowSimulation(config: config(spawnRate: 100_000, maxFlakes: 100), bounds: screen, seed: 10)
        for _ in 0..<60 {
            sim.step(dt: 1.0 / 60)
            #expect(sim.activeCount <= 75)
        }
        #expect(sim.activeCount == 75)
    }

    @Test func resetClearsWindowSnow() throws {
        var sim = SnowSimulation(config: config(), bounds: screen, seed: 11)
        sim.setWindows([window])
        sim.modifySurface(.window(number: 42)) { $0.deposit(volume: 500, minX: 200, maxX: 300) }
        sim.reset()
        #expect(try #require(windowSurface(sim)).totalVolume == 0)
        #expect(sim.activeCount == 0)
    }
}
