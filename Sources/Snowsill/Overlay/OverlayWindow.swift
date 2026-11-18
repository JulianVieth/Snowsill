import AppKit
import MetalKit

/// Borderless, transparent, click-through panel over a whole screen. A non-activating panel, so grabbing snow
/// never takes the focus away from the app the user works in.
final class OverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        // Panels hide when their app deactivates; this one must always stay.
        hidesOnDeactivate = false
        isFloatingPanel = false
        becomesKeyOnlyIfNeeded = true
        // Menus, alerts, Spotlight and the menu bar all sit above .floating; normal windows (0) stay below.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Metal view that forwards mouse presses on snow (the window only takes them while the cursor is over snow).
final class OverlayView: MTKView {
    enum MousePhase { case down, dragged, up }

    /// Phase, global AppKit point, click count (2 for a double click).
    var onMouse: ((MousePhase, NSPoint, Int) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Snowsill is never the active app, so cursor rects don't apply; an always-active tracking area does.
    // The window only receives these while it takes mouse events, i.e. while the cursor is over snow.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect, .mouseMoved], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseDown(with event: NSEvent) { forward(.down, event) }
    override func mouseDragged(with event: NSEvent) { forward(.dragged, event) }
    override func mouseUp(with event: NSEvent) { forward(.up, event) }

    private func forward(_ phase: MousePhase, _ event: NSEvent) {
        guard let window else { return }
        // Global AppKit coordinates.
        onMouse?(phase, window.convertPoint(toScreen: event.locationInWindow), event.clickCount)
    }
}
