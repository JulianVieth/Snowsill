import CoreGraphics
import Testing
@testable import SnowsillCore

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

    func sim(groundHeight: CGFloat, seed: UInt64 = 1, interval: Double = 10) -> SnowSimulation {
        var sim = SnowSimulation(config: config(interval: interval), bounds: screen, seed: seed)
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

    @Test func everyBitOfSnowIsAccountedFor() {
        var s = sim(groundHeight: 30)
        let before = s.surfaces[0].totalVolume
        run(&s, seconds: 13)
        #expect(s.plow.phase == .plowing)
        // Lying, in the air, or pushed aside out of view (like a real plow pushes snow to the roadside).
        let total = s.surfaces[0].totalVolume + airborne(s) + s.plow.pushedAside
        #expect(abs(total - before) < 1e-3)
        #expect(s.plow.pushedAside > 0)
    }

    @Test func pushesAVisibleWallAheadEvenInDeepSnow() throws {
        for depth in [CGFloat(10), 32] {
            var c = config()
            c.plowThreshold = 5
            var s = SnowSimulation(config: c, bounds: screen, seed: 1)
            s.modifySurface(.ground(screen: 0)) { $0.deposit(volume: 1000 * depth, minX: 0, maxX: 1000) }
            run(&s, seconds: 13)
            #expect(s.plow.phase == .plowing)
            let ground = s.surfaces[0]
            let blade = try #require(ground.column(at: s.plow.x))
            // A wall rising clearly above the untouched snow right in front of the blade ...
            let wall = ground.heights[blade..<min(blade + 15, ground.heights.count)]
            #expect(wall.max()! > depth + Plow.wallRise * 0.6, "depth \(depth)")
            #expect(wall.max()! <= depth + Plow.wallRise + 0.5)
            // ... tapering into the untouched snow further ahead.
            let far = try #require(ground.column(at: s.plow.x + 150))
            #expect(abs(ground.heights[far] - depth) < 1)
        }
    }

    @Test func nothingTrailsBehindTheBlade() throws {
        var s = sim(groundHeight: 30)
        for _ in 0..<(60 * 14) {
            s.step(dt: 1.0 / 60)
            guard s.plow.phase == .plowing, s.plow.x > 120 else { continue }
            let ground = s.surfaces[0]
            let a = try #require(ground.column(at: s.plow.x - 100)), b = try #require(ground.column(at: s.plow.x - 4))
            #expect(ground.heights[a...b].allSatisfy { $0 < 3 })
        }
    }

    @Test func leavesAThinIrregularLayerBehind() throws {
        var s = sim(groundHeight: 30)
        run(&s, seconds: 14)
        let ground = s.surfaces[0]
        let behind = ground.heights.prefix(Int((s.plow.x - 20) / Surface.columnWidth)).dropFirst(5)
        #expect(!behind.isEmpty)
        #expect(behind.allSatisfy { $0 < 3 })
        #expect(Set(behind.map { Int($0 * 10) }).count > 3)
    }

    @Test func crossesTheScreenAndComesBackLater() {
        var s = sim(groundHeight: 30)
        run(&s, seconds: 10 + 1000 / 120 + 3)
        #expect(!s.plow.isActive)
        #expect(s.plow.lastRun > 10)
        #expect(s.surfaces[0].meanHeight < 4)
        #expect(s.surfaces[0].heights.max()! < 4)
        // Second run goes the other way once the snow is back.
        s.modifySurface(.ground(screen: 0)) { $0.deposit(volume: 30_000, minX: 0, maxX: 1000) }
        run(&s, seconds: 11)
        #expect(s.plow.isActive)
        #expect(s.plow.direction == -1)
    }

    // MARK: - Something built in the way

    func placeSnowman(_ s: inout SnowSimulation, at x: CGFloat) {
        let top = s.groundTop(at: x)!
        s.stacks.append(SnowStack(id: 99, volumes: [2500, 1200, 500], x: x, bottomY: top, support: .ground))
    }

    /// Mean height of the ground between two x positions.
    func height(_ s: SnowSimulation, from a: CGFloat, to b: CGFloat) -> CGFloat {
        let ground = s.surfaces[0]
        let columns = ground.column(at: a)!...ground.column(at: b)!
        return ground.heights[columns].reduce(0, +) / CGFloat(columns.count)
    }

    @Test(arguments: [CGFloat(40), 500, 960])
    func drivesBehindASnowmanAndItDropsOntoTheClearedGround(snowmanX: CGFloat) throws {
        var s = sim(groundHeight: 40, interval: 120)
        placeSnowman(&s, at: snowmanX)
        let before = try #require(s.stacks.first)
        var highest = before.bottomY
        // Interval and one crossing of the whole screen.
        for _ in 0..<(60 * (120 + 14)) {
            s.step(dt: 1.0 / 60)
            // No wall builds up under it: it never gets lifted.
            if let stack = s.stacks.first { highest = min(highest, stack.bottomY) }
        }
        #expect(!s.plow.isActive)
        #expect(highest >= before.bottomY - 1)
        // Intact, on the scraped ground.
        let after = try #require(s.stacks.first)
        #expect(s.stacks.count == 1)
        #expect(after.volumes == before.volumes)
        #expect(after.support == .ground)
        #expect(after.bottomY > screen.maxY - 4)
        #expect(height(s, from: 20, to: 980) < 4)
    }

    @Test func snowmanFallsRatherThanJumpingDown() throws {
        var s = sim(groundHeight: 40, interval: 120)
        placeSnowman(&s, at: 500)
        var falling = false
        for _ in 0..<(60 * (120 + 14)) {
            s.step(dt: 1.0 / 60)
            if case .falling(_, let shatters)? = s.stacks.first?.support {
                falling = true
                #expect(!shatters)
            }
        }
        #expect(falling)
    }

    // MARK: - Heavy snowfall

    @Test func comesEarlyWhenTheGroundIsNearlyFull() {
        var s = sim(groundHeight: 45, interval: 240)
        run(&s, seconds: Plow.fullGroundPause - 1)
        #expect(!s.plow.isActive)
        run(&s, seconds: 2)
        #expect(s.plow.isActive)
    }

    @Test func keepsTheRegularIntervalWhileThereIsRoom() {
        var s = sim(groundHeight: 30, interval: 240)
        run(&s, seconds: 120)
        #expect(!s.plow.isActive)
        #expect(s.plow.lastRun == 0)
    }

    /// Blizzard with large flakes fills the ground in about a minute; the plow has to keep up.
    @Test func keepsUpWithABlizzard() {
        var c = SnowConfig()
        c.maxFlakes = 2200
        c.spawnRate = 120
        c.radiusRange = 1.8...5.0
        var s = SnowSimulation(config: c, bounds: CGRect(x: 0, y: 0, width: 1710, height: 1107), seed: 1)
        var full = 0, samples = 0
        for i in 0..<(60 * 60 * 5) {
            s.step(dt: 1.0 / 60)
            guard i > 60 * 90, i % 60 == 0 else { continue }
            samples += 1
            if s.surfaces[0].meanHeight > 0.95 * s.surfaces[0].maxHeight { full += 1 }
        }
        #expect(Double(full) / Double(samples) < 0.25)
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
