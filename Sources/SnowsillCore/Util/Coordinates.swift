import CoreGraphics

/// CG-Koordinaten: Ursprung oben links des Hauptbildschirms (`NSScreen.screens[0]`), y nach unten.
/// AppKit-Koordinaten: Ursprung unten links des Hauptbildschirms, y nach oben.
/// Szenen-Koordinaten: Ursprung unten links des jeweiligen Bildschirms, y nach oben.
public enum Coordinates {
    public static func cgRect(fromAppKit rect: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: mainScreenHeight - (rect.minY + rect.height), width: rect.width, height: rect.height)
    }

    // The flip is its own inverse.
    public static func appKitRect(fromCG rect: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        cgRect(fromAppKit: rect, mainScreenHeight: mainScreenHeight)
    }

    @inline(__always)
    public static func sceneLocal(_ point: CGPoint, screenFrameCG screen: CGRect) -> CGPoint {
        CGPoint(x: point.x - screen.minX, y: screen.maxY - point.y)
    }
}
