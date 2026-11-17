import AppKit
import Combine
import IOKit.ps
import MetalKit
import SnowPileCore

/// Owns one overlay (window, view, renderer and simulation) per screen, feeds them the window list, applies
/// settings, pauses when nobody can see the snow, and lets the mouse grab snow where there is some.
@MainActor
final class OverlayController {
    private struct Overlay {
        let displayID: CGDirectDisplayID
        let frame: NSRect
        let window: OverlayWindow
        let view: OverlayView
        let renderer: SnowRenderer
    }

    private let settings: Settings
    private var overlays: [Overlay] = []
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var settingsSubscription: AnyCancellable?
    private var hoverTimer: Timer?
    private var powerTimer: Timer?
    private let tracker = WindowTracker()
    private var scan = WindowScan()
    private var scanTimestamp: CFTimeInterval = 0
    /// Last active app other than SnowPile itself, so opening our menu doesn't change which window carries snow.
    private var activePID: Int32?
    private let debug = ProcessInfo.processInfo.environment["SNOWPILE_DEBUG"] == "1"

    // Reasons to stop rendering.
    private var screensAsleep = false
    private var screenLocked = false
    private var screenSaverRunning = false
    private var sessionInactive = false
    private var onBattery = false

    /// The overlay the mouse is currently dragging in, if any.
    private var dragging: Int?

    init(settings: Settings) {
        self.settings = settings
    }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })

        let ownPID = getpid()
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != ownPID { activePID = pid }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let pid = app?.processIdentifier, pid != ownPID else { return }
            MainActor.assumeIsolated {
                self?.activePID = pid
                self?.applyWindows()
            }
        })
        observePause(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observePause(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        observePause(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observePause(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
        let distributed = DistributedNotificationCenter.default()
        observePause(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true }
        observePause(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false }
        observePause(distributed, Notification.Name("com.apple.screensaver.didstart")) { $0.screenSaverRunning = true }
        observePause(distributed, Notification.Name("com.apple.screensaver.didstop")) { $0.screenSaverRunning = false }
        observePause(center, Notification.Name.NSProcessInfoPowerStateDidChange) { _ in }

        settingsSubscription = settings.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the value is stored.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applySettings() } }
        }

        // Battery state has no cheap notification that covers all cases; checking now and then is enough.
        powerTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePowerSource() }
        }
        updatePowerSource()

        rebuild()
        hoverTimer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }
        RunLoop.main.add(hoverTimer!, forMode: .common)
    }

    func stop() {
        tracker.stop()
        trackerRunning = false
        hoverTimer?.invalidate()
        powerTimer?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        observers.removeAll()
        distributedObservers.removeAll()
        for overlay in overlays { tearDown(overlay) }
        overlays.removeAll()
    }

    /// "Schnee abschütteln": clears all snow, flakes, balls and snowmen.
    func shakeOff() {
        for overlay in overlays { overlay.renderer.withSimulation { $0.reset() } }
    }

    // MARK: - Pausing

    private func observePause(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping @MainActor (OverlayController) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                self.updateRunning()
            }
        }
        if center is DistributedNotificationCenter { distributedObservers.append(observer) } else { observers.append(observer) }
    }

    private var shouldRun: Bool {
        settings.isEnabled && !screensAsleep && !screenLocked && !screenSaverRunning && !sessionInactive
    }

    private func updatePowerSource() {
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let type = info.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() as String? }
        let battery = type == kIOPSBatteryPowerValue
        if battery != onBattery {
            onBattery = battery
            updateRunning()
        }
    }

    /// 60 fps normally, 30 on battery or in Low Power Mode; paused (and hidden when switched off) otherwise.
    private func updateRunning() {
        let run = shouldRun
        let fps = onBattery || ProcessInfo.processInfo.isLowPowerModeEnabled ? 30 : 60
        for overlay in overlays {
            overlay.view.preferredFramesPerSecond = fps
            overlay.view.isPaused = !run
            if run {
                overlay.renderer.resumeClock()
                overlay.window.orderFrontRegardless()
            } else if !settings.isEnabled {
                overlay.window.orderOut(nil)
            }
        }
        if run != trackerRunning {
            trackerRunning = run
            if run { startTracker() } else { tracker.stop() }
        }
    }

    private var trackerRunning = false

    private func startTracker() {
        tracker.start { [weak self] scan, timestamp in
            self?.scan = scan
            self?.scanTimestamp = timestamp
            self?.applyWindows()
        }
    }

    // MARK: - Settings and windows

    private func applySettings() {
        let config = settings.snowConfig
        for overlay in overlays { overlay.renderer.withSimulation { $0.apply(config) } }
        applyWindows()
        updateRunning()
    }

    private func applyWindows() {
        var windows: [WindowInfo]
        let normal = scan.windows.filter { !$0.isWidget }
        if settings.onlyActiveWindow {
            windows = WindowFilter.activeWindow(in: normal, activePID: activePID).map { [$0] } ?? []
        } else {
            windows = normal
        }
        if settings.widgetsEnabled {
            windows += scan.windows.filter(\.isWidget)
        }
        for overlay in overlays { overlay.renderer.setWindows(windows, timestamp: scanTimestamp) }
    }

    /// Everything the overlay must never take a click from: all windows (whatever the mode) and floating panels.
    private var clickBlockers: [CGRect] {
        scan.windows.map(\.bounds) + scan.blockers
    }

    // MARK: - Mouse

    private var mainScreenHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private func cgPoint(_ appKit: NSPoint) -> CGPoint {
        CGPoint(x: appKit.x, y: mainScreenHeight - appKit.y)
    }

    /// The overlay windows ignore the mouse except while the cursor is over snow that can be grabbed.
    private func updateHover() {
        guard shouldRun, dragging == nil else { return }
        let p = cgPoint(NSEvent.mouseLocation)
        let blockers = clickBlockers
        var anyInteractive = false
        for overlay in overlays {
            let interactive = overlay.renderer.screenFrameCG.contains(p) && overlay.renderer.canGrab(at: p, windows: blockers)
            if overlay.window.ignoresMouseEvents == interactive { overlay.window.ignoresMouseEvents = !interactive }
            anyInteractive = anyInteractive || interactive
        }
        if anyInteractive { NSCursor.openHand.set() }
    }

    private func handleMouse(_ index: Int, _ phase: OverlayView.MousePhase, _ appKitPoint: NSPoint) {
        guard overlays.indices.contains(index) else { return }
        let renderer = overlays[index].renderer
        let p = cgPoint(appKitPoint)
        switch phase {
        case .down:
            if renderer.beginGrab(at: p, windows: clickBlockers) {
                dragging = index
                NSCursor.closedHand.set()
            }
        case .dragged:
            guard dragging == index else { return }
            renderer.moveGrab(to: p)
            NSCursor.closedHand.set()
        case .up:
            guard dragging == index else { return }
            renderer.endGrab()
            dragging = nil
            NSCursor.openHand.set()
            updateHover()
        }
    }

    // MARK: - Screens

    private func tearDown(_ overlay: Overlay) {
        overlay.view.isPaused = true
        overlay.window.orderOut(nil)
    }

    /// One overlay per screen. Screens that didn't change keep their overlay and snow.
    private func rebuild() {
        guard let device = MTLCreateSystemDefaultDevice(), let mainScreen = NSScreen.screens.first else { return }
        let mainHeight = mainScreen.frame.height
        var kept: [Overlay] = []
        var old = overlays

        for (index, screen) in NSScreen.screens.enumerated() {
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            if let i = old.firstIndex(where: { $0.displayID == displayID && $0.frame == screen.frame }) {
                kept.append(old.remove(at: i))
                continue
            }
            let window = OverlayWindow(screen: screen)
            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), device: device)
            view.colorPixelFormat = .bgra8Unorm
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            view.framebufferOnly = true
            view.preferredFramesPerSecond = 60
            view.enableSetNeedsDisplay = false
            view.layer?.isOpaque = false
            // Two instead of three queued drawables: one frame less latency, so snow lags less behind a dragged window.
            (view.layer as? CAMetalLayer)?.maximumDrawableCount = 2

            let screenFrameCG = Coordinates.cgRect(fromAppKit: screen.frame, mainScreenHeight: mainHeight)
            guard let renderer = SnowRenderer(
                view: view, screenFrameCG: screenFrameCG, screenIndex: index, config: settings.snowConfig, debug: debug
            ) else { continue }
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            renderer.withSimulation { $0.topInset = max(menuBar, 0) }
            view.delegate = renderer
            window.contentView = view
            kept.append(Overlay(displayID: displayID, frame: screen.frame, window: window, view: view, renderer: renderer))
        }
        for overlay in old { tearDown(overlay) }
        overlays = kept
        let frames = overlays.map(\.renderer.screenFrameCG)
        for overlay in overlays {
            let own = overlay.renderer.screenFrameCG
            overlay.renderer.withSimulation { $0.neighborScreens = frames.filter { $0 != own } }
        }
        // Mouse handlers capture the index, so re-wire them after the order may have changed.
        for (index, overlay) in overlays.enumerated() {
            overlay.view.onMouse = { [weak self] phase, point in self?.handleMouse(index, phase, point) }
        }
        dragging = nil
        updateRunning()
        applyWindows()
    }
}
