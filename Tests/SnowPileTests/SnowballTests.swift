import CoreGraphics
import Testing
@testable import SnowPileCore

@Suite struct SnowballTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func config() -> SnowConfig {
        var config = SnowConfig()
        config.spawnRate = 0
        config.meltRate = 0
        config.windStrength = 0
        config.plowEnabled = false
        return config
    }

    func sim(groundHeight: CGFloat = 20, seed: UInt64 = 1) -> SnowSimulation {
        var sim = SnowSimulation(config: config(), bounds: screen, seed: seed)
        if groundHeight > 0 {
            sim.modifySurface(.ground(screen: 0)) { $0.deposit(volume: 1000 * groundHeight, minX: 0, maxX: 1000) }
        }
        return sim
    }

    /// All snow in the world: lying, airborne, in balls.
    func total(_ s: SnowSimulation) -> CGFloat {
        s.surfaces.reduce(0) { $0 + $1.totalVolume }
            + s.flakes.filter(\.isActive).reduce(0) { $0 + $1.snowVolume }
            + s.stacks.reduce(0) { $0 + $1.totalVolume }
            + (s.held?.volume ?? 0)
    }

    func run(_ s: inout SnowSimulation, seconds: Double) {
        for _ in 0..<Int(seconds * 60) { s.step(dt: 1.0 / 60) }
    }

    /// Rolls from x0 to x1 along the ground in small steps, like a mouse drag.
    func roll(_ s: inout SnowSimulation, from x0: CGFloat, to x1: CGFloat) {
        let steps = Int(abs(x1 - x0) / 4)
        for i in 1...max(steps, 1) {
            let x = x0 + (x1 - x0) * CGFloat(i) / CGFloat(max(steps, 1))
            s.moveGrab(to: CGPoint(x: x, y: 795))
        }
    }

    /// Builds a ball by rolling at `x` over `distance` and drops it from `dropY`.
    func makeBall(_ s: inout SnowSimulation, at x: CGFloat, distance: CGFloat, dropAt dropX: CGFloat, dropY: CGFloat) {
        let grabbed = s.beginGrab(at: CGPoint(x: x, y: 790), windows: [])
        #expect(grabbed)
        roll(&s, from: x, to: x + distance)
        s.moveGrab(to: CGPoint(x: dropX, y: dropY))
        s.endGrab()
        run(&s, seconds: 2)
    }

    // MARK: - Hit testing

    @Test func deepGroundSnowIsGrabbableButNotThinSnowOrAir() {
        #expect(sim(groundHeight: 20).canGrab(at: CGPoint(x: 500, y: 790), windows: []))
        #expect(!sim(groundHeight: 2).canGrab(at: CGPoint(x: 500, y: 799), windows: []))
        #expect(!sim(groundHeight: 20).canGrab(at: CGPoint(x: 500, y: 500), windows: []))
    }

    @Test func clicksOnWindowsAlwaysGoThrough() {
        let s = sim(groundHeight: 20)
        let window = CGRect(x: 400, y: 300, width: 300, height: 500)
        #expect(!s.canGrab(at: CGPoint(x: 500, y: 790), windows: [window]))
        #expect(s.canGrab(at: CGPoint(x: 300, y: 790), windows: [window]))
    }

    @Test func disabledSnowmenAreNotGrabbable() {
        var c = config()
        c.snowmenEnabled = false
        var s = SnowSimulation(config: c, bounds: screen, seed: 1)
        s.modifySurface(.ground(screen: 0)) { $0.deposit(volume: 20_000, minX: 0, maxX: 1000) }
        #expect(!s.canGrab(at: CGPoint(x: 500, y: 790), windows: []))
    }

    // MARK: - Rolling

    @Test func rollingGrowsTheBallAndConservesVolume() throws {
        var s = sim()
        let before = total(s)
        let grabbed = s.beginGrab(at: CGPoint(x: 200, y: 790), windows: [])
        #expect(grabbed)
        let start = try #require(s.held).radius
        roll(&s, from: 200, to: 700)
        let ball = try #require(s.held)
        #expect(ball.radius > start * 3)
        #expect(ball.isRolling)
        #expect(abs(total(s) - before) < 1e-6)
        // It took the snow from its path.
        let ground = s.surfaces[0]
        #expect(ground.heights[ground.column(at: 450)!] < 20)
        #expect(ground.heights[ground.column(at: 900)!] == 20)
    }

    @Test func noSnowNoGrowth() throws {
        var s = sim(groundHeight: 20)
        let grabbed = s.beginGrab(at: CGPoint(x: 100, y: 790), windows: [])
        #expect(grabbed)
        roll(&s, from: 100, to: 600)
        let grown = try #require(s.held).volume
        // Rolling again over the already cleared path barely adds anything.
        roll(&s, from: 600, to: 100)
        roll(&s, from: 100, to: 600)
        let after = try #require(s.held).volume
        roll(&s, from: 600, to: 100)
        #expect(try #require(s.held).volume - after < (after - grown) + 1)
    }

    @Test func carriedBallDoesNotGrow() throws {
        var s = sim()
        let grabbed = s.beginGrab(at: CGPoint(x: 200, y: 790), windows: [])
        #expect(grabbed)
        let volume = try #require(s.held).volume
        s.moveGrab(to: CGPoint(x: 200, y: 400))
        s.moveGrab(to: CGPoint(x: 800, y: 400))
        #expect(try #require(s.held).volume == volume)
        #expect(try !#require(s.held).isRolling)
    }

    // MARK: - Dropping and stacking

    @Test func droppedBallLandsOnTheGround() throws {
        var s = sim()
        makeBall(&s, at: 100, distance: 300, dropAt: 600, dropY: 400)
        let stack = try #require(s.stacks.first)
        #expect(stack.support == .ground)
        #expect(stack.x == 600)
        #expect(abs(stack.bottomY - s.surfaces[0].topY(atColumn: s.surfaces[0].column(at: 600)!)) < 1e-6)
    }

    @Test func threeBallsMakeASnowman() throws {
        var s = sim(groundHeight: 30)
        let before = total(s)
        makeBall(&s, at: 50, distance: 500, dropAt: 800, dropY: 600)    // big
        makeBall(&s, at: 50, distance: 250, dropAt: 800, dropY: 300)    // medium, onto the big one
        makeBall(&s, at: 50, distance: 100, dropAt: 802, dropY: 200)    // small, onto the medium one
        #expect(s.stacks.count == 1)
        let snowman = try #require(s.stacks.first)
        #expect(snowman.isSnowman)
        let r = snowman.radii
        #expect(r[0] >= r[1] && r[1] >= r[2])
        #expect(abs(total(s) - before) < 1e-6)
    }

    @Test func biggerBallIsNotStackedOnASmallerOne() {
        var s = sim(groundHeight: 30)
        makeBall(&s, at: 50, distance: 100, dropAt: 800, dropY: 600)    // small first
        makeBall(&s, at: 50, distance: 500, dropAt: 800, dropY: 300)    // big on top: lands beside, on the ground
        #expect(s.stacks.count == 2)
        #expect(s.stacks.allSatisfy { $0.volumes.count == 1 && $0.support == .ground })
    }

    @Test func grabbingAStackTakesItsTopBall() throws {
        var s = sim(groundHeight: 30)
        makeBall(&s, at: 50, distance: 400, dropAt: 800, dropY: 600)
        makeBall(&s, at: 50, distance: 150, dropAt: 800, dropY: 300)
        let stack = try #require(s.stacks.first)
        #expect(stack.volumes.count == 2)
        let top = try #require(stack.centers.last)
        let grabbed = s.beginGrab(at: top, windows: [])
        #expect(grabbed)
        #expect(try #require(s.held).volume == stack.volumes[1])
        #expect(s.stacks.first?.volumes.count == 1)
    }

    // MARK: - On windows

    let window = WindowInfo(number: 7, ownerPID: 1, bounds: CGRect(x: 300, y: 400, width: 400, height: 300))

    @Test func ballOnAWindowTravelsWithIt() throws {
        var s = sim(groundHeight: 30)
        s.setWindows([window], timestamp: 0)
        makeBall(&s, at: 50, distance: 200, dropAt: 500, dropY: 200)
        let stack = try #require(s.stacks.first)
        guard case .window(7, _) = stack.support else { Issue.record("not on the window: \(stack.support)"); return }
        var moved = window
        moved.bounds.origin.x += 100
        moved.bounds.origin.y -= 50
        s.setWindows([moved], timestamp: 1)
        run(&s, seconds: 0.1)
        let after = try #require(s.stacks.first)
        #expect(abs(after.x - 600) < 0.01)
        #expect(abs(after.bottomY - 350) < 0.01)
    }

    @Test func closingTheWindowShattersTheSnowmanButKeepsTheSnow() throws {
        var s = sim(groundHeight: 30)
        s.setWindows([window], timestamp: 0)
        makeBall(&s, at: 50, distance: 300, dropAt: 500, dropY: 200)
        let before = total(s)
        s.setWindows([], timestamp: 1)
        var sawClumps = false
        for _ in 0..<60 {
            s.step(dt: 1.0 / 60)
            sawClumps = sawClumps || s.flakes.contains { $0.isActive && $0.kind == .clump }
        }
        #expect(s.stacks.isEmpty)
        #expect(sawClumps)
        run(&s, seconds: 20)
        #expect(abs(total(s) - before) < 1e-3, "\(total(s) - before)")
    }

    @Test func ballOnAWindowStaysPutWhenTheWindowReachesPastTheScreenEdge() throws {
        var s = sim(groundHeight: 30)
        s.setWindows([window], timestamp: 0)
        makeBall(&s, at: 50, distance: 200, dropAt: 500, dropY: 200)
        // 200 pt relative to the window's left edge.
        var moved = window
        moved.bounds.origin.x = -100
        s.setWindows([moved], timestamp: 1)
        run(&s, seconds: 0.1)
        let stack = try #require(s.stacks.first)
        #expect(abs(stack.x - 100) < 0.01)
    }

    @Test func coveredSnowmanStaysAndIsHidden() throws {
        var s = sim(groundHeight: 30)
        s.setWindows([window], timestamp: 0)
        makeBall(&s, at: 50, distance: 200, dropAt: 500, dropY: 200)
        let front = WindowInfo(number: 8, ownerPID: 2, bounds: CGRect(x: 400, y: 100, width: 300, height: 500))
        s.setWindows([front, window], timestamp: 1)
        run(&s, seconds: 1)
        let stack = try #require(s.stacks.first)
        #expect(stack.isHidden)
        guard case .window(7, _) = stack.support else { Issue.record("fell off: \(stack.support)"); return }
        s.setWindows([window], timestamp: 2)
        run(&s, seconds: 0.1)
        #expect(try !#require(s.stacks.first).isHidden)
    }

    // MARK: - Rolling on windows

    @Test func snowOnAWindowCapIsGrabbableAndRollsThere() throws {
        var s = sim(groundHeight: 0)
        s.setWindows([window], timestamp: 0)
        s.fillWindow(7, height: 12)
        let surface = try #require(s.surfaces.first { $0.kind == .window(number: 7) })
        let before = total(s)
        // Just above the window's top edge (y 400), in the snow.
        #expect(s.canGrab(at: CGPoint(x: 350, y: 395), windows: [window.bounds]))
        // Inside the window: never.
        #expect(!s.canGrab(at: CGPoint(x: 350, y: 410), windows: [window.bounds]))
        let grabbed = s.beginGrab(at: CGPoint(x: 350, y: 395), windows: [window.bounds])
        #expect(grabbed)
        let start = try #require(s.held).volume
        for x in stride(from: 350, through: 650, by: 4) { s.moveGrab(to: CGPoint(x: CGFloat(x), y: 396)) }
        let ball = try #require(s.held)
        #expect(ball.isRolling)
        #expect(ball.volume > start * 3)
        // It sits on the window's snow, not on the ground.
        let after = try #require(s.surfaces.first { $0.kind == .window(number: 7) })
        #expect(ball.center.y + ball.radius <= after.baseY + 0.01)
        #expect(after.totalVolume < surface.totalVolume)
        #expect(abs(total(s) - before) < 1e-6)
    }

    // MARK: - Destroying

    @Test func doubleClickShattersASnowmanAndKeepsTheSnow() throws {
        var s = sim(groundHeight: 30)
        makeBall(&s, at: 50, distance: 500, dropAt: 800, dropY: 600)
        makeBall(&s, at: 50, distance: 250, dropAt: 800, dropY: 300)
        makeBall(&s, at: 50, distance: 100, dropAt: 802, dropY: 200)
        let snowman = try #require(s.stacks.first)
        #expect(snowman.isSnowman)
        let before = total(s)
        let shattered = s.shatterStacks(near: snowman.centers[1])
        #expect(shattered)
        #expect(s.stacks.isEmpty)
        #expect(s.flakes.contains { $0.isActive && $0.kind == .clump })
        run(&s, seconds: 20)
        #expect(abs(total(s) - before) < 1e-3)
    }

    @Test func doubleClickAfterTheFirstClickPickedUpTheTopBallStillShattersEverything() throws {
        var s = sim(groundHeight: 30)
        makeBall(&s, at: 50, distance: 400, dropAt: 800, dropY: 600)
        makeBall(&s, at: 50, distance: 150, dropAt: 800, dropY: 300)
        let top = try #require(s.stacks.first?.centers.last)
        // First click: grabs the top ball and drops it right away (it is falling back).
        let grabbed = s.beginGrab(at: top, windows: [])
        #expect(grabbed)
        s.endGrab()
        s.step(dt: 1.0 / 60)
        let shattered = s.shatterStacks(near: top)
        #expect(shattered)
        #expect(s.stacks.isEmpty)
    }

    @Test func doubleClickOnPlainSnowDoesNothing() {
        var s = sim(groundHeight: 30)
        let shattered = s.shatterStacks(near: CGPoint(x: 500, y: 790))
        #expect(!shattered)
    }

    // MARK: - Plow

    @Test func plowStopsRightInFrontOfABallAndLeavesNoBlock() throws {
        var c = config()
        c.plowEnabled = true
        c.plowInterval = 8
        c.plowThreshold = 10
        var s = SnowSimulation(config: c, bounds: screen, seed: 5)
        s.modifySurface(.ground(screen: 0)) { $0.deposit(volume: 20_000, minX: 0, maxX: 1000) }
        makeBall(&s, at: 50, distance: 200, dropAt: 600, dropY: 500)
        let stack = try #require(s.stacks.first)
        let r = try #require(stack.radii.first)
        var closest: CGFloat = .infinity
        for _ in 0..<(60 * 20) {
            s.step(dt: 1.0 / 60)
            if s.plow.isActive && s.plow.direction > 0 { closest = min(closest, stack.x - r - s.plow.x) }
        }
        // Stops close to the ball (leaving room for its short wall), never touching it.
        #expect(closest >= 0)
        #expect(closest < Plow.wallLength + 20)
        let after = try #require(s.stacks.first)
        #expect(abs(after.bottomY - stack.bottomY) < 4)
        #expect(!s.plow.isActive)
        // The wall is left as a pile no higher than a wall, no 50 pt block.
        #expect(s.surfaces[0].heights.max()! <= Plow.wallHeight + 0.01)
    }
}
