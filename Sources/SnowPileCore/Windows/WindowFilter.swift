import CoreGraphics
import Foundation

/// A normal app window as seen by `CGWindowListCopyWindowInfo`, bounds in CG coordinates.
public struct WindowInfo: Equatable, Sendable {
    public var number: Int
    public var ownerPID: Int32
    public var bounds: CGRect

    public init(number: Int, ownerPID: Int32, bounds: CGRect) {
        self.number = number
        self.ownerPID = ownerPID
        self.bounds = bounds
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

    public static func activeWindow(in windows: [WindowInfo], activePID: Int32?) -> WindowInfo? {
        guard let activePID else { return nil }
        return windows.first { $0.ownerPID == activePID }
    }
}
