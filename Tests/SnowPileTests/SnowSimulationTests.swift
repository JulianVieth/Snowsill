import CoreGraphics
import Testing
@testable import SnowPileCore

@Suite struct SnowSimulationTests {
    let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    @Test func spawnsFlakesAboveScreen() {
        var sim = SnowSimulation(bounds: screen, seed: 1)
        sim.step(dt: 0.05)
        #expect(sim.activeCount > 0)
        for flake in sim.flakes where flake.isActive {
            #expect(flake.position.y < screen.minY + 10)
        }
    }

    @Test func neverExceedsPoolSize() {
        var config = SnowConfig()
        config.maxFlakes = 50
        config.spawnRate = 10_000
        var sim = SnowSimulation(config: config, bounds: screen, seed: 2)
        for _ in 0..<100 {
            sim.step(dt: 1.0 / 60)
            #expect(sim.activeCount <= 50)
            #expect(sim.flakes.count == 50)
        }
        #expect(sim.activeCount == sim.flakes.lazy.filter(\.isActive).count)
    }

    @Test func poolSizeIsClampedToHardLimit() {
        var config = SnowConfig()
        config.maxFlakes = 100_000
        let sim = SnowSimulation(config: config, bounds: screen, seed: 3)
        #expect(sim.flakes.count == SnowSimulation.hardFlakeLimit)
    }

    @Test func flakesFallDownward() {
        var sim = SnowSimulation(bounds: screen, seed: 4)
        sim.step(dt: 0.05)
        let before = sim.flakes.indices.filter { sim.flakes[$0].isActive }.map { ($0, sim.flakes[$0].position.y) }
        #expect(!before.isEmpty)
        sim.step(dt: 0.05)
        for (index, y) in before { #expect(sim.flakes[index].position.y > y) }
    }

    @Test func flakesDisappearAtBottomAndSlotsAreReused() {
        var config = SnowConfig()
        config.maxFlakes = 20
        config.spawnRate = 200
        var sim = SnowSimulation(config: config, bounds: screen, seed: 5)
        // 60 s simulated: every flake must have crossed the 1000 pt screen at least once.
        for _ in 0..<(60 * 60) {
            sim.step(dt: 1.0 / 60)
            for flake in sim.flakes where flake.isActive {
                #expect(flake.position.y - flake.radius <= screen.maxY)
            }
        }
        #expect(sim.activeCount > 0)
        #expect(sim.flakes.count == 20)
    }

    @Test func resetClearsAllFlakes() {
        var sim = SnowSimulation(bounds: screen, seed: 6)
        for _ in 0..<60 { sim.step(dt: 1.0 / 60) }
        #expect(sim.activeCount > 0)
        sim.reset()
        #expect(sim.activeCount == 0)
        #expect(!sim.flakes.contains { $0.isActive })
    }

    @Test func hugeTimeStepIsClamped() {
        var sim = SnowSimulation(bounds: screen, seed: 7)
        sim.step(dt: 0.05)
        let maxYBefore = sim.flakes.filter(\.isActive).map(\.position.y).max() ?? 0
        sim.step(dt: 30)
        let maxYAfter = sim.flakes.filter(\.isActive).map(\.position.y).max() ?? 0
        #expect(maxYAfter - maxYBefore < 20)
    }
}

@Suite struct GroundSnowTests {
    let screen = CGRect(x: 0, y: 0, width: 400, height: 300)

    func simulate(_ sim: inout SnowSimulation, seconds: Double) {
        for _ in 0..<Int(seconds * 60) { sim.step(dt: 1.0 / 60) }
    }

    @Test func groundSurfaceSpansScreenBottom() {
        let sim = SnowSimulation(bounds: screen, seed: 1)
        #expect(sim.surfaces.count == 1)
        #expect(sim.surfaces[0].minX == 0)
        #expect(sim.surfaces[0].maxX == 400)
        #expect(sim.surfaces[0].baseY == 300)
        #expect(sim.surfaces[0].edges == .walls)
    }

    @Test func flakesLandAndPileUp() {
        var sim = SnowSimulation(bounds: screen, seed: 2)
        simulate(&sim, seconds: 30)
        #expect(sim.surfaces[0].totalVolume > 0)
    }

    /// Deposits and sliding within a step can raise the snow over a flake that was already checked,
    /// so a flake may be inside the snow for one step, but never for two.
    @Test func noFlakeStaysInsideTheSnow() {
        var config = SnowConfig()
        config.spawnRate = 400
        var sim = SnowSimulation(config: config, bounds: screen, seed: 3)
        var insideLastStep = Set<Int>()
        for _ in 0..<(60 * 40) {
            sim.step(dt: 1.0 / 60)
            let ground = sim.surfaces[0]
            var inside = Set<Int>()
            for i in sim.flakes.indices where sim.flakes[i].isActive {
                let flake = sim.flakes[i]
                guard let column = ground.column(at: flake.position.x),
                      flake.position.y >= ground.topY(atColumn: column) else { continue }
                inside.insert(i)
            }
            #expect(inside.isDisjoint(with: insideLastStep))
            insideLastStep = inside
        }
        #expect(sim.surfaces[0].totalVolume > 0)
    }

    @Test func groundNeverExceedsMaxHeight() {
        var config = SnowConfig()
        config.spawnRate = 5000
        config.groundMaxHeight = 10
        var sim = SnowSimulation(config: config, bounds: screen, seed: 4)
        simulate(&sim, seconds: 60)
        #expect(sim.surfaces[0].heights.max()! <= 10)
        #expect(sim.surfaces[0].heights.max()! > 9)
    }

    @Test func pileRespectsAngleOfRepose() {
        var config = SnowConfig()
        config.spawnRate = 2000
        var sim = SnowSimulation(config: config, bounds: screen, seed: 5)
        simulate(&sim, seconds: 20)
        // Fresh deposits may exceed the slope for one step, relaxation brings it back within a few.
        for _ in 0..<200 { sim.step(dt: 0) }
        var relaxed = sim.surfaces[0]
        for _ in 0..<200 { relaxed.relax() }
        let threshold = Surface.reposeRatio * Surface.columnWidth
        let heights = relaxed.heights
        for i in 0..<(heights.count - 1) {
            #expect(abs(heights[i] - heights[i + 1]) <= threshold + 1e-6)
        }
    }

    @Test func groundCanBeDisabled() {
        var config = SnowConfig()
        config.groundEnabled = false
        var sim = SnowSimulation(config: config, bounds: screen, seed: 6)
        simulate(&sim, seconds: 10)
        #expect(sim.surfaces.isEmpty)
        #expect(sim.activeCount > 0)
    }

    @Test func resetClearsGround() {
        var sim = SnowSimulation(bounds: screen, seed: 7)
        simulate(&sim, seconds: 20)
        #expect(sim.surfaces[0].totalVolume > 0)
        sim.reset()
        #expect(sim.surfaces[0].totalVolume == 0)
    }
}
