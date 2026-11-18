import CoreGraphics
import Foundation

/// A normal app window as seen by `CGWindowListCopyWindowInfo`, bounds in CG coordinates.
public struct WindowInfo: Equatable, Sendable {
    public var number: Int
    public var ownerPID: Int32
    public var bounds: CGRect
    /// A desktop widget or icon (behind all normal windows). Carries snow, but no icicles.
    public var isWidget: Bool
    /// A desktop icon (implies `isWidget`): small, square corners.
    public var isDesktopIcon: Bool

    public init(number: Int, ownerPID: Int32, bounds: CGRect, isWidget: Bool = false, isDesktopIcon: Bool = false) {
        self.number = number
        self.ownerPID = ownerPID
        self.bounds = bounds
        self.isWidget = isWidget || isDesktopIcon
        self.isDesktopIcon = isDesktopIcon
    }
}

/// Result of one window list poll.
public struct WindowScan: Equatable, Sendable {
    /// Normal windows front to back, then desktop widgets.
    public var windows: [WindowInfo]
    /// Other apps' windows between the normal windows and the Dock (floating panels, picture in picture).
    /// They may sit at or below the overlay's level, so the overlay must never take clicks there.
    public var blockers: [CGRect]
    /// Frames of the screens that show an app in full screen.
    public var fullScreens: [CGRect]

    public init(windows: [WindowInfo] = [], blockers: [CGRect] = [], fullScreens: [CGRect] = []) {
        self.windows = windows
        self.blockers = blockers
        self.fullScreens = fullScreens
    }
}

public enum WindowFilter {
    static let minSize = CGSize(width: 80, height: 40)

    /// Keeps normal, visible windows of other apps in the list's front-to-back order.
    /// Reads only number, owner PID, layer, alpha and bounds. `kCGWindowName` would require screen recording permission.
    public static func parse(_ list: [[String: Any]], ownPID: Int32) -> [WindowInfo] {
        var result: [WindowInfo] = []
        result.reserveCapacity(list.count)
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0 { continue }
            guard bounds.width >= minSize.width, bounds.height >= minSize.height else { continue }
            result.append(WindowInfo(number: number, ownerPID: pid, bounds: bounds))
        }
        return result
    }

    /// Measured on macOS 26: widget windows are 8 pt larger than their tile on every side.
    public static let widgetPadding: CGFloat = 8
    static let desktopIconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
    static let dockLayer = Int(CGWindowLevelForKey(.dockWindow))
    static let mainMenuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))

    // MARK: - Full screen

    /// Screens that show an app in full screen. The overlay can't tell by itself: an agent app's panels show on
    /// full-screen spaces even without `.fullScreenAuxiliary`. Needs a list that includes desktop elements.
    ///
    /// A full-screen space shows no desktop: the Finder's desktop window (one per screen) is missing there, and an
    /// app window covers the screen. With a notch it sits below the menu bar strip, exactly like a maximized
    /// window, so only the missing desktop tells them apart. Without any desktop window (desktop icons switched
    /// off) only a window over the whole screen with no menu bar counts.
    public static func fullScreens(_ list: [[String: Any]], screens: [CGRect], ownPID: Int32) -> [CGRect] {
        var appWindows: [CGRect] = [], desktops: [CGRect] = [], menuBars: [CGRect] = []
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0 { continue }
            switch layer {
            case 0: appWindows.append(bounds)
            case desktopIconLayer: desktops.append(bounds)
            case mainMenuLayer: menuBars.append(bounds)
            default: break
            }
        }
        return screens.filter { screen in
            if desktops.isEmpty {
                let menuBar = menuBars.contains { $0.intersects(CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: 2)) }
                return !menuBar && appWindows.contains { matches($0, screen) }
            }
            let hasDesktop = desktops.contains { d in
                let overlap = d.intersection(screen)
                return !overlap.isNull && overlap.width * overlap.height > screen.width * screen.height / 2
            }
            return !hasDesktop && appWindows.contains { covers($0, screen) }
        }
    }

    /// Full width down to the bottom, from the top or from just below a menu bar strip (notch).
    private static func covers(_ window: CGRect, _ screen: CGRect) -> Bool {
        abs(window.minX - screen.minX) <= 1 && abs(window.maxX - screen.maxX) <= 1
            && abs(window.maxY - screen.maxY) <= 1 && window.minY <= screen.minY + 50
    }

    private static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.maxX - b.maxX) <= 1 && abs(a.maxY - b.maxY) <= 1
    }

    /// Splits a raw window list into normal windows, desktop widgets and click blockers.
    /// Widgets are Notification Center's windows just above the desktop icon layer.
    public static func scan(_ list: [[String: Any]], ownPID: Int32, widgetPID: Int32?) -> WindowScan {
        var scan = WindowScan(windows: parse(list, ownPID: ownPID))
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer != 0,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0 { continue }
            if let widgetPID, pid == widgetPID, layer > desktopIconLayer, layer < desktopIconLayer + 10,
               bounds.width >= minSize.width, bounds.height >= minSize.height {
                // The window has a transparent margin around the visible tile; snow belongs on the tile.
                let tile = bounds.insetBy(dx: widgetPadding, dy: widgetPadding)
                scan.windows.append(WindowInfo(number: number, ownerPID: pid, bounds: tile, isWidget: true))
            } else if layer > 0, layer < dockLayer {
                scan.blockers.append(bounds)
            }
        }
        return scan
    }

    public static func activeWindow(in windows: [WindowInfo], activePID: Int32?) -> WindowInfo? {
        guard let activePID else { return nil }
        return windows.first { $0.ownerPID == activePID }
    }
}
