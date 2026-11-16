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
