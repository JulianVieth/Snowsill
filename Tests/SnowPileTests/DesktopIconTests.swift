import CoreGraphics
import Testing
@testable import SnowPileCore

@Suite struct DesktopIconTests {
    let screen = CGRect(x: 0, y: 0, width: 1710, height: 1107)
    let disk = CGRect(x: 1600, y: 60, width: 64, height: 64)

    @Test func iconsBecomeWidgetLikeEntriesWithStableNumbers() {
        let a = DesktopIcons.windows(from: [disk, CGRect(x: 1600, y: 160, width: 64, height: 64)], ownerPID: 7)
        let b = DesktopIcons.windows(from: [disk], ownerPID: 7)
        #expect(a.count == 2)
        #expect(a.allSatisfy { $0.isDesktopIcon && $0.isWidget })
        #expect(a[0].number == b[0].number)
        #expect(a[0].number != a[1].number)
        #expect(a.allSatisfy { $0.number >= DesktopIcons.numberBase })
    }

    @Test func tinyAndDuplicateFramesAreDropped() {
        let icons = DesktopIcons.windows(from: [disk, disk, CGRect(x: 10, y: 10, width: 8, height: 8)], ownerPID: 7)
        #expect(icons.count == 1)
    }

    @Test func iconCarriesAThinCapAndHidesBehindWindows() throws {
        var config = SnowConfig()
        config.spawnRate = 0
        var sim = SnowSimulation(config: config, bounds: screen, seed: 1)
        let icon = DesktopIcons.windows(from: [disk], ownerPID: 7)[0]
        sim.setWindows([icon], timestamp: 0)
        let surface = try #require(sim.surfaces.first { $0.kind == .window(number: icon.number) })
        #expect(surface.maxHeight == config.iconMaxHeight)
        #expect(surface.minX == 1600 + config.iconInset)
        #expect(surface.baseY == 60)
        // A window over the icon hides its snow; icons grow no icicles.
        let window = WindowInfo(number: 3, ownerPID: 1, bounds: CGRect(x: 1500, y: 40, width: 200, height: 300))
        sim.setWindows([window, icon], timestamp: 1)
        let hidden = try #require(sim.surfaces.first { $0.kind == .window(number: icon.number) })
        #expect(hidden.hasHidden)
        #expect(sim.icicles(ofWindow: icon.number) == nil)
    }
}
