import CoreGraphics
import Foundation
import Testing
@testable import SnowsillCore

@Suite struct WindowFilterTests {
    func entry(number: Int, pid: Int32, layer: Int = 0, alpha: Double = 1,
               bounds: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600)) -> [String: Any] {
        [
            kCGWindowNumber as String: number,
            kCGWindowOwnerPID as String: Int(pid),
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: bounds.dictionaryRepresentation as NSDictionary,
        ]
    }

    @Test func parsesBoundsAndKeepsFrontToBackOrder() {
        let list = [
            entry(number: 3, pid: 10, bounds: CGRect(x: 10, y: 20, width: 300, height: 200)),
            entry(number: 7, pid: 11),
        ]
        let windows = WindowFilter.parse(list, ownPID: 99)
        #expect(windows.map(\.number) == [3, 7])
        #expect(windows[0].bounds == CGRect(x: 10, y: 20, width: 300, height: 200))
        #expect(windows[0].ownerPID == 10)
    }

    @Test func dropsOtherLayersOwnWindowsInvisibleAndTinyWindows() {
        let list = [
            entry(number: 1, pid: 10, layer: 25),
            entry(number: 2, pid: 99),
            entry(number: 3, pid: 10, alpha: 0),
            entry(number: 4, pid: 10, bounds: CGRect(x: 0, y: 0, width: 79, height: 600)),
            entry(number: 5, pid: 10, bounds: CGRect(x: 0, y: 0, width: 800, height: 39)),
            entry(number: 6, pid: 10, bounds: CGRect(x: 0, y: 0, width: 80, height: 40)),
        ]
        #expect(WindowFilter.parse(list, ownPID: 99).map(\.number) == [6])
    }

    @Test func skipsMalformedEntries() {
        let list: [[String: Any]] = [[kCGWindowNumber as String: 1], entry(number: 2, pid: 10)]
        #expect(WindowFilter.parse(list, ownPID: 99).map(\.number) == [2])
    }

    @Test func activeWindowIsFrontmostWindowOfActiveApp() {
        let windows = [
            WindowInfo(number: 1, ownerPID: 10, bounds: .zero),
            WindowInfo(number: 2, ownerPID: 20, bounds: .zero),
            WindowInfo(number: 3, ownerPID: 20, bounds: .zero),
        ]
        #expect(WindowFilter.activeWindow(in: windows, activePID: 20)?.number == 2)
        #expect(WindowFilter.activeWindow(in: windows, activePID: 30) == nil)
        #expect(WindowFilter.activeWindow(in: windows, activePID: nil) == nil)
    }

    // MARK: - Widgets and click blockers

    static let widgetLayer = Int(CGWindowLevelForKey(.desktopIconWindow)) + 2

    @Test func widgetsOfNotificationCenterComeAfterAllWindows() {
        let list = [
            entry(number: 24, pid: 50, layer: Self.widgetLayer, bounds: CGRect(x: 188, y: 42, width: 180, height: 180)),
            entry(number: 3, pid: 10),
            entry(number: 23, pid: 50, layer: Self.widgetLayer, bounds: CGRect(x: 8, y: 42, width: 180, height: 180)),
            entry(number: 4, pid: 11),
        ]
        let scan = WindowFilter.scan(list, ownPID: 99, widgetPID: 50)
        #expect(scan.windows.map(\.number) == [3, 4, 24, 23])
        #expect(scan.windows.map(\.isWidget) == [false, false, true, true])
        // Snow lies on the visible tile, not on the transparent margin around it.
        #expect(scan.windows[2].bounds == CGRect(x: 196, y: 50, width: 164, height: 164))
    }

    @Test func desktopLayerWindowsOfOtherAppsAreNoWidgets() {
        let list = [
            entry(number: 24, pid: 51, layer: Self.widgetLayer, bounds: CGRect(x: 188, y: 42, width: 180, height: 180)),
            // Notification Center's own panel sits far above the desktop.
            entry(number: 30, pid: 50, layer: 23, bounds: CGRect(x: 1000, y: 0, width: 400, height: 900)),
        ]
        let scan = WindowFilter.scan(list, ownPID: 99, widgetPID: 50)
        #expect(scan.windows.isEmpty)
    }

    @Test func floatingWindowsOfOtherAppsBlockClicks() {
        let list = [
            entry(number: 1, pid: 10, layer: 3, bounds: CGRect(x: 0, y: 0, width: 300, height: 200)),
            entry(number: 2, pid: 99, layer: 3, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000)),  // ours
            entry(number: 3, pid: 12, layer: 20, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000)), // Dock: above us anyway
            entry(number: 4, pid: 13, layer: 0),
        ]
        let scan = WindowFilter.scan(list, ownPID: 99, widgetPID: nil)
        #expect(scan.blockers == [CGRect(x: 0, y: 0, width: 300, height: 200)])
        #expect(scan.windows.map(\.number) == [4])
    }

    // MARK: - Full screen (measured on a notch laptop and a Sidecar display, 2026-11-18)

    let sidecar = CGRect(x: -1366, y: 0, width: 1366, height: 1024)
    let laptop = CGRect(x: 0, y: 0, width: 1710, height: 1107)
    let menuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
    let desktopLayer = Int(CGWindowLevelForKey(.desktopIconWindow))

    func desktop(_ screen: CGRect) -> [String: Any] { entry(number: 900, pid: 30, layer: desktopLayer, bounds: screen) }
    func menuBar(_ screen: CGRect, height: CGFloat) -> [String: Any] {
        entry(number: 901, pid: 20, layer: menuLayer, bounds: CGRect(x: screen.minX, y: 0, width: screen.width, height: height))
    }

    @Test func fullScreenOnTheSidecarCoversItAndHidesItsDesktop() {
        let list = [
            menuBar(laptop, height: 34),
            entry(number: 1, pid: 10, bounds: sidecar),
            desktop(laptop),
        ]
        #expect(WindowFilter.fullScreens(list, screens: [laptop, sidecar], ownPID: 99) == [sidecar])
    }

    /// With a notch the app sits below the menu bar strip, just like a maximized window; only the desktop tells.
    @Test func fullScreenBelowTheNotch() {
        let list = [
            menuBar(laptop, height: 34),
            menuBar(sidecar, height: 30),
            entry(number: 1, pid: 10, bounds: CGRect(x: 0, y: 34, width: 1710, height: 1073)),
            desktop(sidecar),
        ]
        #expect(WindowFilter.fullScreens(list, screens: [laptop, sidecar], ownPID: 99) == [laptop])
    }

    @Test func maximizedWindowsKeepTheDesktop() {
        let list = [
            menuBar(laptop, height: 34),
            menuBar(sidecar, height: 30),
            entry(number: 1, pid: 10, bounds: CGRect(x: 0, y: 34, width: 1710, height: 1073)),
            entry(number: 2, pid: 11, bounds: sidecar),
            desktop(laptop),
            desktop(sidecar),
        ]
        #expect(WindowFilter.fullScreens(list, screens: [laptop, sidecar], ownPID: 99).isEmpty)
    }

    @Test func smallerWindowIsNoFullScreen() {
        let list = [menuBar(sidecar, height: 30), entry(number: 1, pid: 10, bounds: CGRect(x: -1366, y: 30, width: 1366, height: 914))]
        #expect(WindowFilter.fullScreens(list + [desktop(laptop)], screens: [laptop, sidecar], ownPID: 99).isEmpty)
    }

    @Test func ownOverlayDoesNotCount() {
        let list = [entry(number: 1, pid: 99, bounds: sidecar), desktop(laptop)]
        #expect(WindowFilter.fullScreens(list, screens: [laptop, sidecar], ownPID: 99).isEmpty)
    }

    /// Desktop icons switched off (no desktop window anywhere): only a window over the whole screen without menu bar.
    @Test func withoutDesktopWindowsOnlyTheStrictRule() {
        let maximized = [menuBar(sidecar, height: 30), entry(number: 1, pid: 10, bounds: CGRect(x: -1366, y: 30, width: 1366, height: 994))]
        #expect(WindowFilter.fullScreens(maximized, screens: [sidecar], ownPID: 99).isEmpty)
        let full = [entry(number: 1, pid: 10, bounds: sidecar)]
        #expect(WindowFilter.fullScreens(full, screens: [sidecar], ownPID: 99) == [sidecar])
        let screenSizedWithMenu = [menuBar(sidecar, height: 30), entry(number: 1, pid: 10, bounds: sidecar)]
        #expect(WindowFilter.fullScreens(screenSizedWithMenu, screens: [sidecar], ownPID: 99).isEmpty)
    }

    @Test func desktopWindowsAreNotParsedAsWindowsOrBlockers() {
        let scan = WindowFilter.scan([desktop(laptop), entry(number: 2, pid: 10)], ownPID: 99, widgetPID: nil)
        #expect(scan.windows.map(\.number) == [2])
        #expect(scan.blockers.isEmpty)
    }
}
