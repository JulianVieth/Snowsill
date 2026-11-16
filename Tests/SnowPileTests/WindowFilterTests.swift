import CoreGraphics
import Foundation
import Testing
@testable import SnowPileCore

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
}
