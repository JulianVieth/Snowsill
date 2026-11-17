import CoreGraphics
import Testing
@testable import SnowPileCore

/// Each screen runs its own simulation in global CG coordinates. These use the layout of a real setup:
/// a laptop as main screen and a wide monitor to its right that sits higher (negative CG y).
@Suite struct MultiScreenTests {
    let laptop = CGRect(x: 0, y: 0, width: 1710, height: 1107)
    let wide = CGRect(x: 1710, y: -333, width: 3440, height: 1440)

    func config() -> SnowConfig {
        var c = SnowConfig()
        c.spawnRate = 0
        c.meltRate = 0
        c.windStrength = 0
        return c
    }

    @Test func groundSitsAtEachScreensBottom() throws {
        let a = SnowSimulation(config: config(), bounds: laptop, screenIndex: 0, seed: 1)
        let b = SnowSimulation(config: config(), bounds: wide, screenIndex: 1, seed: 1)
        #expect(a.surfaces[0].kind == .ground(screen: 0))
        #expect(b.surfaces[0].kind == .ground(screen: 1))
        #expect(b.surfaces[0].baseY == 1107)
        #expect(b.surfaces[0].minX == 1710)
        #expect(abs(b.surfaces[0].maxX - 5150) < 1e-6)
    }

    @Test func snowfallSpawnsAboveTheOwnScreen() {
        var c = config()
        c.spawnRate = 400
        var sim = SnowSimulation(config: c, bounds: wide, screenIndex: 1, seed: 2)
        sim.step(dt: 0.05)
        let flakes = sim.flakes.filter(\.isActive)
        #expect(!flakes.isEmpty)
        #expect(flakes.allSatisfy { $0.position.x >= 1710 && $0.position.x <= 5150 && $0.position.y < -333 + 10 })
    }

    @Test func eachScreenOnlyCarriesWindowsOnIt() {
        let onWide = WindowInfo(number: 1, ownerPID: 1, bounds: CGRect(x: 2000, y: -200, width: 800, height: 600))
        let onLaptop = WindowInfo(number: 2, ownerPID: 1, bounds: CGRect(x: 200, y: 300, width: 800, height: 600))
        var a = SnowSimulation(config: config(), bounds: laptop, screenIndex: 0, seed: 1)
        var b = SnowSimulation(config: config(), bounds: wide, screenIndex: 1, seed: 1)
        a.setWindows([onWide, onLaptop], timestamp: 0)
        b.setWindows([onWide, onLaptop], timestamp: 0)
        #expect(a.surfaces.map(\.kind) == [.ground(screen: 0), .window(number: 2)])
        #expect(b.surfaces.map(\.kind) == [.ground(screen: 1), .window(number: 1)])
    }

    @Test func windowSpanningTwoScreensIsSplitAtTheEdge() throws {
        let spanning = WindowInfo(number: 3, ownerPID: 1, bounds: CGRect(x: 1400, y: 300, width: 800, height: 400))
        var a = SnowSimulation(config: config(), bounds: laptop, screenIndex: 0, seed: 1)
        var b = SnowSimulation(config: config(), bounds: wide, screenIndex: 1, seed: 1)
        a.setWindows([spanning], timestamp: 0)
        b.setWindows([spanning], timestamp: 0)
        let left = try #require(a.surfaces.first { $0.kind == .window(number: 3) })
        let right = try #require(b.surfaces.first { $0.kind == .window(number: 3) })
        #expect(left.maxX == 1710)
        #expect(right.minX == 1710)
    }

    @Test func snowballsWorkOnASecondaryScreen() throws {
        var sim = SnowSimulation(config: config(), bounds: wide, screenIndex: 1, seed: 3)
        sim.fillGround(height: 25)
        let p = CGPoint(x: 3000, y: 1107 - 10)
        #expect(sim.canGrab(at: p, windows: []))
        let grabbed = sim.beginGrab(at: p, windows: [])
        #expect(grabbed)
        for x in stride(from: 3000, through: 3400, by: 4) { sim.moveGrab(to: CGPoint(x: CGFloat(x), y: 1100)) }
        sim.endGrab()
        for _ in 0..<120 { sim.step(dt: 1.0 / 60) }
        let stack = try #require(sim.stacks.first)
        #expect(stack.support == .ground)
        #expect(stack.bottomY > 1107 - 30 && stack.bottomY <= 1107)
    }

    @Test func snowDoesNotSpillAtTheScreenEdgeOfASpanningWindow() throws {
        let spanning = WindowInfo(number: 3, ownerPID: 1, bounds: CGRect(x: 1400, y: 300, width: 800, height: 400))
        var a = SnowSimulation(config: config(), bounds: laptop, screenIndex: 0, seed: 1)
        a.neighborScreens = [wide]
        a.setWindows([spanning], timestamp: 0)
        // A steep pile right at the screen edge.
        a.modifySurface(.window(number: 3)) { $0.deposit(volume: 200, minX: 1690, maxX: 1710) }
        for _ in 0..<120 { a.step(dt: 1.0 / 60) }
        let surface = try #require(a.surfaces.first { $0.kind == .window(number: 3) })
        #expect(surface.clippedRight && !surface.clippedLeft)
        #expect(abs(surface.totalVolume - 200) < 1e-6)
        #expect(a.activeCount == 0)
    }

    @Test func draggingASnowyWindowOntoTheNextScreenDropsNothingAtTheSeam() throws {
        var a = SnowSimulation(config: config(), bounds: laptop, screenIndex: 0, seed: 1)
        a.neighborScreens = [wide]
        var window = WindowInfo(number: 3, ownerPID: 1, bounds: CGRect(x: 800, y: 300, width: 800, height: 400))
        a.setWindows([window], timestamp: 0)
        a.fillWindow(3, height: 8)
        window.bounds.origin.x += 300
        a.setWindows([window], timestamp: 1)
        #expect(a.activeCount == 0)
        // Without a neighbor the same move drops the cut-off snow at the outer screen edge.
        var b = SnowSimulation(config: config(), bounds: laptop, screenIndex: 0, seed: 1)
        window.bounds.origin.x -= 300
        b.setWindows([window], timestamp: 0)
        b.fillWindow(3, height: 8)
        window.bounds.origin.x += 300
        b.setWindows([window], timestamp: 1)
        #expect(b.activeCount > 0)
    }
}
