import CoreGraphics
import Testing
@testable import SnowPileCore

@Suite struct PlowTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func config(interval: Double = 10) -> SnowConfig {
        var config = SnowConfig()
        config.spawnRate = 0
        config.plowInterval = interval
        config.plowThreshold = 20
        config.meltRate = 0
        config.windStrength = 0
        return config
    }

    func sim(groundHeight: CGFloat, seed: UInt64 = 1) -> SnowSimulation {
        var sim = SnowSimulation(config: config(), bounds: screen, seed: seed)
        sim.modifySurface(.ground(screen: 0)) { $0.deposit(volume: 1000 * groundHeight, minX: 0, maxX: 1000) }
        return sim
    }

    func run(_ sim: inout SnowSimulation, seconds: Double) {
        for _ in 0..<Int(seconds * 60) { sim.step(dt: 1.0 / 60) }
    }

    func airborne(_ sim: SnowSimulation) -> CGFloat {
        sim.flakes.filter(\.isActive).reduce(0) { $0 + $1.snowVolume }
    }

    @Test func staysAwayBelowTheThreshold() {
        var s = sim(groundHeight: 10)
        run(&s, seconds: 30)
        #expect(!s.plow.isActive)
        #expect(s.plow.lastRun == 0)
    }

    @Test func waitsForTheInterval() {
        var s = sim(groundHeight: 30)
        run(&s, seconds: 9)
        #expect(!s.plow.isActive)
        run(&s, seconds: 1.5)
        #expect(s.plow.isActive)
    }

    @Test func conservesVolumeWhileScraping() {
        var s = sim(groundHeight: 30)
        let before = s.surfaces[0].totalVolume
        run(&s, seconds: 13)
        #expect(s.plow.phase == .plowing)
        #expect(s.plow.wallVolume > 0)
        let total = s.surfaces[0].totalVolume + s.plow.wallVolume + airborne(s)
        #expect(abs(total - before) < 1e-3, "diff \(total - before)")
    }

    @Test func leavesAThinIrregularLayerBehind() throws {
        var s = sim(groundHeight: 30)
        run(&s, seconds: 14)
        let ground = s.surfaces[0]
        let behind = ground.heights.prefix(Int((s.plow.x - 20) / Surface.columnWidth)).dropFirst(5)
        #expect(!behind.isEmpty)
        // Columns the wall overflow didn't hit stay at the residual height.
        let residualColumns = behind.filter { $0 < 3 }
        #expect(Double(residualColumns.count) > Double(behind.count) * 0.8)
        #expect(Set(residualColumns.map { Int($0 * 10) }).count > 3)
    }

    @Test func crossesTheScreenAndComesBackLater() {
        var s = sim(groundHeight: 30)
        run(&s, seconds: 10 + 1000 / 120 + 3)
        #expect(!s.plow.isActive)
        #expect(s.plow.lastRun > 10)
        #expect(s.surfaces[0].meanHeight < 8)
        // Second run goes the other way once the snow is back.
        s.modifySurface(.ground(screen: 0)) { $0.deposit(volume: 30_000, minX: 0, maxX: 1000) }
        run(&s, seconds: 11)
        #expect(s.plow.isActive)
        #expect(s.plow.direction == -1)
    }

    @Test func disabledPlowNeverComes() {
        var c = config()
        c.plowEnabled = false
        var s = SnowSimulation(config: c, bounds: screen, seed: 3)
        s.modifySurface(.ground(screen: 0)) { $0.deposit(volume: 40_000, minX: 0, maxX: 1000) }
        run(&s, seconds: 20)
        #expect(!s.plow.isActive)
    }
}
