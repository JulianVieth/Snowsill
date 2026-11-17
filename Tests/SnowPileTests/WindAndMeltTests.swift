import CoreGraphics
import Testing
@testable import SnowPileCore

@Suite struct WindAndMeltTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    // MARK: - Wind

    @Test func calmMeansNoWind() {
        var wind = Wind(seed: 3, firstFlurry: 1e9)
        var rng = SplitMix64(seed: 1)
        for _ in 0..<6000 {
            wind.step(dt: 0.05, strength: 0, flurries: false, rng: &rng)
            #expect(wind.speed == 0)
        }
    }

    @Test func breezeAndGustsStayInARangeAndVary() {
        var wind = Wind(seed: 3, firstFlurry: 1e9)
        var rng = SplitMix64(seed: 1)
        var speeds: [CGFloat] = []
        for _ in 0..<12000 {   // 10 minutes
            wind.step(dt: 0.05, strength: 1, flurries: false, rng: &rng)
            speeds.append(wind.speed)
        }
        #expect(speeds.allSatisfy { abs($0) <= Wind.breeze + Wind.gust })
        #expect((speeds.max()! - speeds.min()!) > 10)
        // Changes smoothly: no jumps between steps.
        for (a, b) in zip(speeds, speeds.dropFirst()) { #expect(abs(a - b) < 2) }
    }

    @Test func flurriesComeNowAndThenAndRaiseTheSnowfall() {
        var wind = Wind(seed: 5, firstFlurry: 10)
        var rng = SplitMix64(seed: 2)
        var flurrySeconds = 0.0
        var maxFactor: CGFloat = 1
        for _ in 0..<(20 * 60 * 10) {   // 20 minutes at 10 Hz
            wind.step(dt: 0.1, strength: 1, flurries: true, rng: &rng)
            if wind.isFlurry { flurrySeconds += 0.1 }
            maxFactor = max(maxFactor, wind.spawnFactor)
        }
        #expect(maxFactor > 3)
        #expect(flurrySeconds > 20 && flurrySeconds < 400)
    }

    @Test func windDriftsFlakesSideways() {
        var config = SnowConfig()
        config.spawnRate = 0
        config.windStrength = 1
        config.flurriesEnabled = false
        var sim = SnowSimulation(config: config, bounds: screen, seed: 9)
        sim.windOverride = 30
        sim.addTestFlake(at: CGPoint(x: 500, y: 100), volume: 1)
        let start = sim.flakes.first { $0.isActive }!.velocity.dx
        // A few steps: the flake picks up the wind's direction.
        for _ in 0..<60 { sim.step(dt: 1.0 / 60) }
        let dx = sim.flakes.first { $0.isActive }!.velocity.dx
        #expect(dx > start + 20)
    }

    @Test func snowfallStartsUpwindSoTheWindwardSideGetsSnow() {
        var config = SnowConfig()
        config.spawnRate = 400
        config.flurriesEnabled = false
        var sim = SnowSimulation(config: config, bounds: screen, seed: 10)
        sim.windX = 25
        sim.spawnOnly(count: 300)
        let xs = sim.flakes.filter(\.isActive).map(\.position.x)
        #expect(xs.contains { $0 < 0 })
        #expect(xs.allSatisfy { $0 <= 1000 })
    }

    // MARK: - Melting

    func meltSim() -> SnowSimulation {
        var config = SnowConfig()
        config.spawnRate = 0
        config.windStrength = 0
        config.meltRate = 0.1
        config.meltSpeedupAfter = 10
        config.meltSpeedup = 3
        config.plowEnabled = false
        var sim = SnowSimulation(config: config, bounds: screen, seed: 1)
        sim.modifySurface(.ground(screen: 0)) { $0.deposit(volume: 1000 * 20, minX: 0, maxX: 1000) }
        return sim
    }

    @Test func snowMeltsSlowlyAndFasterWithoutNewSnow() {
        var sim = meltSim()
        // Mark fresh snowfall.
        sim.modifySurface(.ground(screen: 0)) { $0.lastSnowfall = 0 }
        for _ in 0..<(60 * 5) { sim.step(dt: 1.0 / 60) }
        let early = 20 - sim.surfaces[0].meanHeight      // ~0.5 pt in 5 s
        #expect(early > 0.3 && early < 0.7)
        for _ in 0..<(60 * 10) { sim.step(dt: 1.0 / 60) }
        let before = sim.surfaces[0].meanHeight
        for _ in 0..<(60 * 5) { sim.step(dt: 1.0 / 60) }
        let late = before - sim.surfaces[0].meanHeight   // ~1.5 pt in 5 s
        #expect(late > early * 2)
    }

    @Test func meltingNeverGoesBelowZero() {
        var sim = meltSim()
        for _ in 0..<(60 * 120) { sim.step(dt: 1.0 / 60) }
        #expect(sim.surfaces[0].heights.allSatisfy { $0 == 0 })
    }
}
