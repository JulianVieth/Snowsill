import CoreGraphics
import Testing
@testable import SnowsillCore

@Suite struct IcicleTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let window = WindowInfo(number: 3, ownerPID: 1, bounds: CGRect(x: 100, y: 200, width: 500, height: 300))

    func config() -> SnowConfig {
        var c = SnowConfig()
        c.spawnRate = 0
        c.meltRate = 0
        c.windStrength = 0
        c.icicleDelay = 5
        c.icicleSpawnInterval = 1...2
        c.icicleGrowth = 1
        return c
    }

    func snowySim(_ c: SnowConfig? = nil, window w: WindowInfo? = nil) -> SnowSimulation {
        let w = w ?? window
        var s = SnowSimulation(config: c ?? config(), bounds: screen, seed: 4)
        s.setWindows([w], timestamp: 0)
        s.modifySurface(.window(number: w.number)) { $0.deposit(volume: 500 * 8, minX: 0, maxX: 1000) }
        return s
    }

    func run(_ s: inout SnowSimulation, seconds: Double) {
        for _ in 0..<Int(seconds * 60) { s.step(dt: 1.0 / 60) }
    }

    @Test func noIciclesBeforeTheSnowHasLainAWhile() {
        var s = snowySim()
        run(&s, seconds: 4)
        #expect(s.icicles(ofWindow: 3) == nil)
    }

    @Test func iciclesGrowUnderASnowyWindow() throws {
        var s = snowySim()
        run(&s, seconds: 30)
        let (bounds, icicles) = try #require(s.icicles(ofWindow: 3))
        #expect(bounds == window.bounds)
        #expect(icicles.count >= 3)
        #expect(icicles.contains { $0.length > 5 })
        #expect(icicles.allSatisfy { $0.length <= $0.maxLength })
        #expect(icicles.allSatisfy { $0.offset >= 20 && $0.offset <= 480 })
        // Spaced apart.
        let offsets = icicles.map(\.offset).sorted()
        for (a, b) in zip(offsets, offsets.dropFirst()) { #expect(b - a >= SnowSimulation.icicleSpacing) }
    }

    @Test func noSnowNoIcicles() {
        var s = SnowSimulation(config: config(), bounds: screen, seed: 4)
        s.setWindows([window], timestamp: 0)
        run(&s, seconds: 30)
        #expect(s.icicles(ofWindow: 3) == nil)
    }

    @Test func fastMoveBreaksThemOff() throws {
        var s = snowySim()
        run(&s, seconds: 30)
        let count = try #require(s.icicles(ofWindow: 3)).icicles.count
        s.setWindows([window], timestamp: 30)   // the tracker keeps polling while nothing moves
        var moved = window
        moved.bounds.origin.x += 40       // 40 pt in 1/60 s = 2400 pt/s
        s.setWindows([moved], timestamp: 30 + 1.0 / 60)
        #expect(s.icicles(ofWindow: 3) == nil)
        #expect(s.flakes.filter { $0.isActive && $0.kind == .ice }.count == count)
        // Ice carries no snow.
        #expect(s.flakes.filter { $0.isActive && $0.kind == .ice }.allSatisfy { $0.snowVolume == 0 })
    }

    @Test func slowMoveKeepsThem() throws {
        var s = snowySim()
        run(&s, seconds: 30)
        let count = try #require(s.icicles(ofWindow: 3)).icicles.count
        s.setWindows([window], timestamp: 30)
        var moved = window
        moved.bounds.origin.x += 2        // 120 pt/s
        s.setWindows([moved], timestamp: 30 + 1.0 / 60)
        let after = try #require(s.icicles(ofWindow: 3))
        #expect(after.icicles.count == count)
        #expect(after.bounds.minX == 102)
    }

    @Test func closingTheWindowDropsThem() throws {
        var s = snowySim()
        run(&s, seconds: 30)
        #expect(s.icicles(ofWindow: 3) != nil)
        s.setWindows([], timestamp: 31)
        #expect(s.icicles(ofWindow: 3) == nil)
        #expect(s.flakes.contains { $0.isActive && $0.kind == .ice })
        run(&s, seconds: 10)
        #expect(!s.flakes.contains { $0.isActive && $0.kind == .ice })
    }

    @Test func widgetsGrowNone() {
        var widget = window
        widget.isWidget = true
        var s = snowySim(window: widget)
        run(&s, seconds: 30)
        #expect(s.icicles(ofWindow: 3) == nil)
    }

    @Test func disabledMeansNone() {
        var c = config()
        c.iciclesEnabled = false
        var s = snowySim(c)
        run(&s, seconds: 30)
        #expect(s.icicles(ofWindow: 3) == nil)
    }

    @Test func iciclesBehindAFrontWindowAreHidden() throws {
        var s = snowySim()
        run(&s, seconds: 30)
        let front = WindowInfo(number: 9, ownerPID: 2, bounds: CGRect(x: 0, y: 450, width: 1000, height: 200))
        s.setWindows([front, window], timestamp: 31)
        let icicles = try #require(s.icicles(ofWindow: 3)).icicles
        let allHidden = icicles.allSatisfy { $0.isHidden }
        #expect(allHidden)
    }
}
