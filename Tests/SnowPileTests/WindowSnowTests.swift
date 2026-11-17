import CoreGraphics
import Testing
@testable import SnowPileCore

@Suite struct WindowSnowTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let window = WindowInfo(number: 42, ownerPID: 10, bounds: CGRect(x: 100, y: 200, width: 400, height: 300))
    let inset = SnowConfig().windowCornerInset

    func config(spawnRate: Double = 0) -> SnowConfig {
        var config = SnowConfig()
        config.spawnRate = spawnRate
        config.meltRate = 0
        config.windStrength = 0
        return config
    }

    /// Simulation with one window carrying `volume` of snow spread evenly over its top edge.
    func simWithSnow(_ volume: CGFloat = 3000, seed: UInt64 = 1) -> SnowSimulation {
        var sim = SnowSimulation(config: config(), bounds: screen, seed: seed)
        sim.setWindows([window], timestamp: 0)
        sim.modifySurface(.window(number: 42)) { $0.deposit(volume: volume, minX: 0, maxX: 1000) }
        return sim
    }

    func windowSurface(_ sim: SnowSimulation, _ number: Int = 42) -> Surface? {
        sim.surfaces.first { $0.kind == .window(number: number) }
    }

    func airborneVolume(_ sim: SnowSimulation) -> CGFloat {
        sim.flakes.filter(\.isActive).reduce(0) { $0 + $1.snowVolume }
    }

    func moved(dx: CGFloat = 0, dy: CGFloat = 0, dw: CGFloat = 0) -> WindowInfo {
        var w = window
        w.bounds.origin.x += dx
        w.bounds.origin.y += dy
        w.bounds.size.width += dw
        return w
    }

    // MARK: - Geometry

    @Test func surfaceSitsOnTopEdgeInsetFromCorners() throws {
        var sim = SnowSimulation(config: config(), bounds: screen, seed: 1)
        sim.setWindows([window], timestamp: 0)
        let surface = try #require(windowSurface(sim))
        #expect(surface.baseY == 200)
        #expect(surface.minX == 100 + inset)
        #expect(surface.maxX == 500 - inset)
        #expect(surface.maxHeight == SnowConfig().windowMaxHeight)
        #expect(surface.edges == .spill)
    }

    @Test func windowRightBelowTheMenuBarCarriesNoSnow() {
        var sim = SnowSimulation(config: config(), bounds: screen, seed: 2)
        sim.topInset = 30
        sim.setWindows([WindowInfo(number: 1, ownerPID: 10, bounds: CGRect(x: 0, y: 31, width: 400, height: 300))], timestamp: 0)
        #expect(windowSurface(sim, 1) == nil)
        sim.setWindows([WindowInfo(number: 1, ownerPID: 10, bounds: CGRect(x: 0, y: 60, width: 400, height: 300))], timestamp: 1)
        #expect(windowSurface(sim, 1) != nil)
    }

    @Test func surfaceIsClippedToScreen() throws {
        var sim = SnowSimulation(config: config(), bounds: screen, seed: 2)
        sim.setWindows([WindowInfo(number: 1, ownerPID: 10, bounds: CGRect(x: -100, y: 200, width: 400, height: 300))], timestamp: 0)
        let surface = try #require(windowSurface(sim, 1))
        #expect(surface.minX == 0)
        #expect(surface.maxX == 300 - inset)
    }

    @Test func windowsWithTopEdgeOffScreenGetNoSurface() {
        var sim = SnowSimulation(config: config(), bounds: screen, seed: 3)
        sim.setWindows([
            WindowInfo(number: 1, ownerPID: 10, bounds: CGRect(x: 100, y: -10, width: 400, height: 300)),
            WindowInfo(number: 2, ownerPID: 10, bounds: CGRect(x: 100, y: 900, width: 400, height: 300)),
            WindowInfo(number: 3, ownerPID: 10, bounds: CGRect(x: 1200, y: 100, width: 400, height: 300)),
        ], timestamp: 0)
        #expect(sim.surfaces.allSatisfy { if case .ground = $0.kind { true } else { false } })
    }

    @Test func snowLandsOnWindow() throws {
        var sim = SnowSimulation(config: config(spawnRate: 40), bounds: screen, seed: 4)
        sim.setWindows([window], timestamp: 0)
        for _ in 0..<(60 * 20) { sim.step(dt: 1.0 / 60) }
        let surface = try #require(windowSurface(sim))
        #expect(surface.totalVolume > 0)
        #expect(surface.heights.max()! <= SnowConfig().windowMaxHeight)
    }

    @Test func unchangedOrJitteringWindowKeepsSnow() throws {
        var sim = simWithSnow()
        let before = try #require(windowSurface(sim))
        sim.setWindows([window], timestamp: 0.1)
        sim.setWindows([moved(dx: 0.3)], timestamp: 0.2)
        let after = try #require(windowSurface(sim))
        #expect(after.heights == before.heights)
        #expect(after.minX == before.minX)
    }

    // MARK: - Moving

    @Test func slowMoveCarriesSnowAlong() throws {
        var sim = simWithSnow()
        let before = try #require(windowSurface(sim))
        // 50 pt right and 30 pt down within 0.25 s: 200 pt/s, well below the slip speed.
        sim.setWindows([moved(dx: 50, dy: 30)], timestamp: 0.25)
        let after = try #require(windowSurface(sim))
        #expect(after.id == before.id)
        #expect(after.minX == before.minX + 50)
        #expect(after.baseY == 230)
        #expect(after.heights == before.heights)
        #expect(sim.activeCount == 0)
    }

    @Test func fastHorizontalMoveThrowsSnowOffTheTrailingEdge() throws {
        var sim = simWithSnow()
        let volume = try #require(windowSurface(sim)).totalVolume
        // 100 pt to the right within one frame: 6000 pt/s.
        sim.setWindows([moved(dx: 100)], timestamp: 1.0 / 60)
        let after = try #require(windowSurface(sim))
        #expect(after.totalVolume < volume)
        // The window slid right under the lagging snow: it fell off the trailing (left) edge,
        // and the leading (right) end is bare.
        #expect(after.heights.first! > 0)
        #expect(after.heights.last == 0)
        #expect(sim.activeCount > 0)
        for flake in sim.flakes where flake.isActive {
            #expect(flake.position.x <= after.minX + 2)
        }
        #expect(abs(after.totalVolume + airborneVolume(sim) - volume) < 1e-6)
    }

    @Test func fastVerticalMoveKeepsSnow() throws {
        var sim = simWithSnow()
        let volume = try #require(windowSurface(sim)).totalVolume
        sim.setWindows([moved(dy: 100)], timestamp: 1.0 / 60)
        #expect(try #require(windowSurface(sim)).totalVolume == volume)
        #expect(sim.activeCount == 0)
    }

    @Test func movingAcrossTheScreenEdgeDropsSnowThere() throws {
        var sim = simWithSnow()
        let volume = try #require(windowSurface(sim)).totalVolume
        // Slowly to the left until the window sticks out 100 pt past the screen edge.
        sim.setWindows([moved(dx: -200)], timestamp: 1)
        let after = try #require(windowSurface(sim))
        #expect(after.minX == 0)
        #expect(after.totalVolume < volume)
        #expect(abs(after.totalVolume + airborneVolume(sim) - volume) < 1e-6)
    }

    // MARK: - Motion (for render prediction)

    @Test func motionReportsVelocityOfAMovingWindow() throws {
        var sim = simWithSnow()
        sim.setWindows([moved(dx: 10, dy: -5)], timestamp: 0.02)
        let motion = try #require(sim.motion(ofWindow: 42))
        #expect(abs(motion.velocity.dx - 500) < 1e-6)
        #expect(abs(motion.velocity.dy + 250) < 1e-6)
        #expect(motion.timestamp == 0.02)
    }

    @Test func motionStopsWhenThePositionStaysTheSame() throws {
        var sim = simWithSnow()
        sim.setWindows([moved(dx: 10)], timestamp: 0.02)
        sim.setWindows([moved(dx: 10)], timestamp: 0.04)
        let motion = try #require(sim.motion(ofWindow: 42))
        #expect(motion.velocity == .zero)
        #expect(motion.timestamp == 0.04)
    }

    @Test func motionIsSmoothed() throws {
        var sim = simWithSnow()
        sim.setWindows([moved(dx: 10)], timestamp: 0.02)   // 500 pt/s
        sim.setWindows([moved(dx: 30)], timestamp: 0.04)   // 1000 pt/s
        let motion = try #require(sim.motion(ofWindow: 42))
        #expect(motion.velocity.dx > 500 && motion.velocity.dx < 1000)
    }

    @Test func resizingHasNoMotion() throws {
        var sim = simWithSnow()
        sim.setWindows([moved(dx: -20, dw: 20)], timestamp: 0.02)
        #expect(try #require(sim.motion(ofWindow: 42)).velocity == .zero)
        #expect(sim.motion(ofWindow: 7) == nil)
    }

    // MARK: - Resizing

    @Test func growingFromTheRightKeepsSnowInPlace() throws {
        var sim = simWithSnow()
        let before = try #require(windowSurface(sim))
        sim.setWindows([moved(dw: 100)], timestamp: 0.1)
        let after = try #require(windowSurface(sim))
        #expect(after.minX == before.minX)
        #expect(Array(after.heights.prefix(before.heights.count)) == Array(before.heights))
        #expect(after.heights.last == 0)
    }

    @Test func shrinkingFromTheRightDropsTheCutOffSnow() throws {
        var sim = simWithSnow()
        let volume = try #require(windowSurface(sim)).totalVolume
        sim.setWindows([moved(dw: -100)], timestamp: 0.1)
        let after = try #require(windowSurface(sim))
        #expect(after.maxX == 400 - inset)
        #expect(abs(after.totalVolume + airborneVolume(sim) - volume) < 1e-6)
        #expect(sim.activeCount > 0)
    }

    @Test func growingFromTheLeftKeepsSnowAtItsAbsolutePosition() throws {
        var sim = simWithSnow()
        let before = try #require(windowSurface(sim))
        sim.setWindows([moved(dx: -100, dw: 100)], timestamp: 0.1)
        let after = try #require(windowSurface(sim))
        #expect(after.minX == before.minX - 100)
        let x: CGFloat = 300
        #expect(after.heights[after.column(at: x)!] == before.heights[before.column(at: x)!])
        #expect(after.heights.first == 0)
        #expect(sim.activeCount == 0)
    }

    // MARK: - Powder

    @Test func closingWindowTurnsSnowIntoPowder() {
        var sim = simWithSnow(3000)
        sim.setWindows([], timestamp: 0.1)
        #expect(windowSurface(sim) == nil)
        #expect(abs(airborneVolume(sim) - 3000) < 1e-6)
        let debris = sim.flakes.filter(\.isActive)
        #expect(debris.count > 60)
        // Clumps and powder, like the reference video.
        #expect(debris.contains { $0.kind == .clump })
        #expect(debris.contains { $0.kind == .powder })
        #expect(debris.allSatisfy { $0.radius <= SnowConfig().clumpRadiusRange.upperBound })
    }

    @Test func fullWindowFitsIntoThePowderPool() {
        // The fullest possible window: 376 pt × 14 pt.
        var sim = simWithSnow(376 * 14)
        sim.setWindows([], timestamp: 0.1)
        #expect(abs(airborneVolume(sim) - 376 * 14) < 1e-6)
    }

    @Test func powderFallsDownAndEndsUpOnTheGround() {
        var sim = simWithSnow(800)
        sim.setWindows([], timestamp: 0.1)
        for _ in 0..<(60 * 30) { sim.step(dt: 1.0 / 60) }
        #expect(sim.activeCount == 0)
        #expect(abs(sim.surfaces[0].totalVolume - 800) < 1e-6)
    }

    @Test func snowSlidingOffAnEdgeBecomesPowder() throws {
        var sim = SnowSimulation(config: config(), bounds: screen, seed: 9)
        sim.setWindows([window], timestamp: 0)
        sim.modifySurface(.window(number: 42)) { $0.deposit(volume: 200, minX: 112, maxX: 132) }
        for _ in 0..<30 { sim.step(dt: 1.0 / 60) }

        let surface = try #require(windowSurface(sim))
        let airborne = sim.flakes.filter(\.isActive)
        #expect(!airborne.isEmpty)
        #expect(airborne.allSatisfy { $0.position.x < surface.minX })
        #expect(airborne.allSatisfy { $0.radius <= SnowConfig().clumpRadiusRange.upperBound })
        let total = surface.totalVolume + airborneVolume(sim)
        #expect(total <= 200 + 1e-6)
        #expect(total > 200 - SnowConfig().clumpVolumeRange.lowerBound)
    }

    @Test func regularSnowfallNeverUsesThePowderPool() {
        var config = config(spawnRate: 100_000)
        config.maxFlakes = 100
        var sim = SnowSimulation(config: config, bounds: screen, seed: 10)
        for _ in 0..<60 {
            sim.step(dt: 1.0 / 60)
            #expect(sim.activeCount <= 100)
        }
        #expect(sim.activeCount == 100)
        #expect(sim.flakes.count == 100 + SnowConfig().powderCapacity)
    }

    @Test func powderDoesNotStopRegularSnowfall() {
        var config = config(spawnRate: 100_000)
        config.maxFlakes = 100
        var sim = SnowSimulation(config: config, bounds: screen, seed: 12)
        sim.setWindows([window], timestamp: 0)
        sim.modifySurface(.window(number: 42)) { $0.deposit(volume: 3000, minX: 0, maxX: 1000) }
        sim.setWindows([], timestamp: 0.1)
        sim.step(dt: 1.0 / 60)
        #expect(sim.snowfallCount == 100)
        #expect(sim.activeCount > 100)
    }

    @Test func clumpsBurstIntoPuffsWithoutCreatingSnow() {
        var sim = simWithSnow(3000, seed: 21)
        sim.setWindows([], timestamp: 0.1)
        var sawPuff = false
        for _ in 0..<(60 * 20) {
            sim.step(dt: 1.0 / 60)
            sawPuff = sawPuff || sim.flakes.contains { $0.isActive && $0.kind == .puff }
            // Puffs carry nothing; volume lives only in the debris and on surfaces.
            #expect(sim.flakes.allSatisfy { !$0.isActive || $0.kind != .puff || $0.snowVolume == 0 })
        }
        #expect(sawPuff)
        #expect(abs(sim.surfaces[0].totalVolume + airborneVolume(sim) - 3000) < 1e-6)
    }

    // MARK: - Minimizing

    /// The window list during a minimize animation: the window shrinks toward the Dock, every edge moves.
    func minimizeFrames() -> [CGRect] {
        (1...8).map { i in
            let t = CGFloat(i) / 8
            let w = 400 * (1 - 0.85 * t), h = 300 * (1 - 0.85 * t)
            return CGRect(x: 100 + (500 - 100) * t * 0.5, y: 200 + (780 - 200) * t, width: w, height: h)
        }
    }

    @Test func minimizingDropsTheSnowLikeClosing() throws {
        var sim = simWithSnow(3000)
        sim.setWindows([window], timestamp: 0.5)
        var t = 0.5
        var first = true
        for frame in minimizeFrames() {
            t += 1.0 / 60
            sim.setWindows([WindowInfo(number: 42, ownerPID: 10, bounds: frame)], timestamp: t)
            if first {
                // Right at the first shrinking step the whole layer falls from where it was.
                #expect(windowSurface(sim) == nil)
                let debris = sim.flakes.filter(\.isActive)
                #expect(abs(airborneVolume(sim) - 3000) < 1e-6)
                #expect(debris.allSatisfy { $0.position.y <= 200 + 1 && $0.position.y >= 200 - 20 })
                first = false
            }
            // No snow travels down with the animation.
            #expect(windowSurface(sim) == nil)
        }
        sim.setWindows([], timestamp: t + 0.1)
        // Restored later: an empty cap at the old place.
        sim.setWindows([window], timestamp: t + 5)
        #expect(try #require(windowSurface(sim)).totalVolume == 0)
    }

    /// Recorded on macOS 26: a window on the right screen minimized into the Dock on the main screen (Genie).
    static let genie: [(Double, CGRect)] = [
        (0.025, CGRect(x: 5500, y: 355, width: 800, height: 352)), (0.114, CGRect(x: 5487, y: 355, width: 813, height: 352)),
        (0.143, CGRect(x: 5385, y: 355, width: 915, height: 352)), (0.202, CGRect(x: 5066, y: 355, width: 1234, height: 352)),
        (0.262, CGRect(x: 4460, y: 355, width: 1840, height: 352)), (0.303, CGRect(x: 4137, y: 355, width: 2163, height: 353)),
        (0.314, CGRect(x: 3929, y: 363, width: 2370, height: 353)), (0.339, CGRect(x: 3635, y: 384, width: 2649, height: 353)),
        (0.370, CGRect(x: 2825, y: 455, width: 3250, height: 353)), (0.455, CGRect(x: 1513, y: 750, width: 1841, height: 323)),
        (0.526, CGRect(x: 1506, y: 966, width: 191, height: 107)), (0.595, CGRect(x: 1504, y: 1039, width: 64, height: 34)),
    ]

    @Test func recordedGenieMinimizeDropsTheSnowWhereItLay() throws {
        let screen = CGRect(x: 5150, y: -84, width: 1920, height: 1080)
        var sim = SnowSimulation(config: config(), bounds: screen, seed: 7)
        let start = WindowInfo(number: 9, ownerPID: 1, bounds: Self.genie[0].1)
        sim.setWindows([start], timestamp: 0)
        sim.fillWindow(9, height: 10)
        let volume = try #require(windowSurface(sim, 9)).totalVolume
        for (t, frame) in Self.genie.dropFirst() {
            sim.setWindows([WindowInfo(number: 9, ownerPID: 1, bounds: frame)], timestamp: t)
            if let surface = windowSurface(sim, 9) {
                // While stretching sideways the snow stays where it was, at the old top edge.
                #expect(surface.baseY == 355)
            }
        }
        #expect(windowSurface(sim, 9) == nil)
        // All of it fell from the old top edge (minus what slid off the stretched cap early on, also from there).
        let debris = sim.flakes.filter(\.isActive)
        #expect(abs(airborneVolume(sim) - volume) < 1e-6)
        #expect(debris.allSatisfy { $0.position.y <= 356 && $0.position.y >= 330 })
    }

    @Test func movingDownOrResizingFromTheTopIsNoMinimize() {
        let a = CGRect(x: 100, y: 200, width: 400, height: 300)
        #expect(!SnowSimulation.looksLikeMinimize(from: a, to: a.offsetBy(dx: 30, dy: 80)))          // move
        #expect(!SnowSimulation.looksLikeMinimize(from: a, to: CGRect(x: 100, y: 260, width: 400, height: 240))) // top edge
        #expect(!SnowSimulation.looksLikeMinimize(from: a, to: CGRect(x: 160, y: 260, width: 340, height: 240))) // top-left corner
        #expect(!SnowSimulation.looksLikeMinimize(from: a, to: CGRect(x: 40, y: 200, width: 460, height: 300)))  // left edge
        #expect(SnowSimulation.looksLikeMinimize(from: a, to: CGRect(x: 80, y: 230, width: 500, height: 300)))   // genie step
    }

    @Test func resizingFromACornerIsNoMinimize() throws {
        var sim = simWithSnow(3000)
        sim.setWindows([window], timestamp: 0.5)
        // Top-left corner dragged in: right and bottom edges stay.
        var w = window
        w.bounds = CGRect(x: 160, y: 260, width: 340, height: 240)
        sim.setWindows([w], timestamp: 0.5 + 1.0 / 60)
        #expect(windowSurface(sim) != nil)
    }

    @Test func aWindowThatOnlyLooksLikeMinimizingGetsItsSurfaceBack() throws {
        var sim = simWithSnow(3000)
        sim.setWindows([window], timestamp: 0.5)
        let shrunk = WindowInfo(number: 42, ownerPID: 10, bounds: CGRect(x: 150, y: 260, width: 300, height: 200))
        sim.setWindows([shrunk], timestamp: 0.52)
        #expect(windowSurface(sim) == nil)
        // It stays like that (a programmatic resize, not a minimize): after a while it carries snow again.
        sim.setWindows([shrunk], timestamp: 2.0)
        #expect(windowSurface(sim) != nil)
    }

    @Test func resetClearsWindowSnow() throws {
        var sim = simWithSnow()
        sim.reset()
        #expect(try #require(windowSurface(sim)).totalVolume == 0)
        #expect(sim.activeCount == 0)
    }
}
