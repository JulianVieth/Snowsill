import CoreGraphics
import Foundation

/// A normal app window as seen by `CGWindowListCopyWindowInfo`, bounds in CG coordinates.
public struct WindowInfo: Equatable, Sendable {
    public var number: Int
    public var ownerPID: Int32
    public var bounds: CGRect
    /// A desktop widget (behind all normal windows). Carries snow, but no icicles.
    public var isWidget: Bool

    public init(number: Int, ownerPID: Int32, bounds: CGRect, isWidget: Bool = false) {
        self.number = number
        self.ownerPID = ownerPID
        self.bounds = bounds
        self.isWidget = isWidget
    }
}

/// Result of one window list poll.
public struct WindowScan: Equatable, Sendable {
    /// Normal windows front to back, then desktop widgets.
    public var windows: [WindowInfo]
    /// Other apps' windows between the normal windows and the Dock (floating panels, picture in picture).
    /// They may sit at or below the overlay's level, so the overlay must never take clicks there.
    public var blockers: [CGRect]

    public init(windows: [WindowInfo] = [], blockers: [CGRect] = []) {
        self.windows = windows
        self.blockers = blockers
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

    static let desktopIconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
    static let dockLayer = Int(CGWindowLevelForKey(.dockWindow))

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
                scan.windows.append(WindowInfo(number: number, ownerPID: pid, bounds: bounds, isWidget: true))
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
