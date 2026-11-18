import AppKit
import Combine
import IOKit.ps
import MetalKit
import SnowsillCore

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

    private let settings: SnowSettings
    private var overlays: [Overlay] = []
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var settingsSubscription: AnyCancellable?
    private var hoverTimer: Timer?
    private var powerTimer: Timer?
    private let tracker = WindowTracker()
    private let iconReader = DesktopIconReader()
    private var iconReaderRunning = false
    private var iconFrames: [CGRect] = []
    private var scan = WindowScan()
    private var scanTimestamp: CFTimeInterval = 0
    /// Last active app other than Snowsill itself, so opening our menu doesn't change which window carries snow.
    private var activePID: Int32?
    private let debug = ProcessInfo.processInfo.environment["SNOWSILL_DEBUG"] == "1"

    // Reasons to stop rendering.
    private var screensAsleep = false
    private var screenLocked = false
    private var screenSaverRunning = false
    private var sessionInactive = false
    private var onBattery = false

    /// The overlay the mouse is currently dragging in, if any.
    private var dragging: Int?

    init(settings: SnowSettings) {
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
        iconReader.stop()
        iconReaderRunning = false
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

    /// When a window last moved (the tracker delivers every poll while something moves).
    private var lastWindowActivity: CFTimeInterval = -.infinity

    /// Each frame has a fixed cost of about 1 ms CPU per screen, whatever is drawn. Quiet snowfall moves only
    /// 2–3 pt per frame at 30 fps, so that is enough; 60 fps only matter where something has to follow quickly:
    /// a dragged window (its snow must stick to it), a dragged snowball, the cursor over snow.
    /// On battery or in Low Power Mode it stays at 30.
    private var desiredFPS: Int {
        if onBattery || ProcessInfo.processInfo.isLowPowerModeEnabled { return 30 }
        let windowsMoving = CACurrentMediaTime() - lastWindowActivity < 0.7
        let mouseOnSnow = dragging != nil || overlays.contains { !$0.window.ignoresMouseEvents }
        return windowsMoving || mouseOnSnow ? 60 : 30
    }

    private func updateFrameRate() {
        let fps = desiredFPS
        for overlay in overlays where overlay.view.preferredFramesPerSecond != fps {
            overlay.view.preferredFramesPerSecond = fps
        }
    }

    /// Paused (and hidden when switched off) while nobody can see the snow.
    private func updateRunning() {
        let run = shouldRun
        updateFrameRate()
        for overlay in overlays {
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
        let readIcons = run && settings.iconsEnabled
        if readIcons != iconReaderRunning {
            iconReaderRunning = readIcons
            if readIcons {
                iconReader.start { [weak self] frames in
                    self?.iconFrames = frames
                    self?.applyWindows()
                }
            } else {
                iconReader.stop()
                iconFrames = []
            }
        }
    }

    private var trackerRunning = false

    private func startTracker() {
        tracker.start { [weak self] scan, timestamp in
            guard let self else { return }
            if scan != self.scan { self.lastWindowActivity = CACurrentMediaTime() }
            self.scan = scan
            self.scanTimestamp = timestamp
            self.applyWindows()
            self.updateFrameRate()
        }
    }

    // MARK: - SnowSettings and windows

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
        if settings.iconsEnabled {
            windows += DesktopIcons.windows(from: iconFrames, ownerPID: 0)
        }
        for overlay in overlays { overlay.renderer.setWindows(windows, timestamp: scanTimestamp) }
    }

    /// Everything the overlay must never take a click from: all windows (whatever the mode) and floating panels.
    private var clickBlockers: [CGRect] {
        scan.windows.map(\.bounds) + scan.blockers + iconFrames
    }

    // MARK: - Mouse

    private var mainScreenHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private func cgPoint(_ appKit: NSPoint) -> CGPoint {
        CGPoint(x: appKit.x, y: mainScreenHeight - appKit.y)
    }

    /// The overlay windows ignore the mouse except while the cursor is over snow that can be grabbed.
    /// Replaces the real cursor position in the self-test.
    private var simulatedMouse: NSPoint?

    private func updateHover() {
        defer { updateFrameRate() }
        guard shouldRun, dragging == nil else { return }
        let p = cgPoint(simulatedMouse ?? NSEvent.mouseLocation)
        let blockers = clickBlockers
        var anyInteractive = false
        for overlay in overlays {
            let interactive = overlay.renderer.screenFrameCG.contains(p) && overlay.renderer.canGrab(at: p, windows: blockers)
            if overlay.window.ignoresMouseEvents == interactive { overlay.window.ignoresMouseEvents = !interactive }
            anyInteractive = anyInteractive || interactive
        }
        if anyInteractive && simulatedMouse == nil { NSCursor.openHand.set() }
    }

    private func handleMouse(_ index: Int, _ phase: OverlayView.MousePhase, _ appKitPoint: NSPoint, clicks: Int = 1) {
        guard overlays.indices.contains(index) else { return }
        let renderer = overlays[index].renderer
        let p = cgPoint(appKitPoint)
        switch phase {
        case .down:
            // Double click on a ball or snowman: it bursts.
            if clicks >= 2, renderer.shatterStacks(near: p) {
                dragging = nil
                return
            }
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
            overlay.view.onMouse = { [weak self] phase, point, clicks in self?.handleMouse(index, phase, point, clicks: clicks) }
        }
        dragging = nil
        updateRunning()
        applyWindows()
    }

    // MARK: - Self-test

    /// `SNOWSILL_SELFTEST=mouse`: drives the real mouse path (hover → click-through switch, AppKit → CG conversion,
    /// grab, roll, drop) with simulated positions on the main screen, since synthetic mouse events need
    /// Accessibility permission. Prints one line per check and exits with the number of failures.
    func runMouseSelfTest() {
        Task { @MainActor in
            func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
            var failures = 0
            func check(_ ok: Bool, _ text: String) {
                print((ok ? "OK      " : "FEHLER  ") + text)
                if !ok { failures += 1 }
            }
            await wait(1.5)
            guard let main = overlays.first, let screen = NSScreen.screens.first else {
                print("FEHLER  kein Overlay"); exit(1)
            }
            main.renderer.withSimulation { $0.fillGround(height: 30) }
            // A spot on the ground that no window covers (AppKit: x, y from the bottom of the main screen).
            let blockers = clickBlockers
            let height = screen.frame.height
            func free(_ x: CGFloat) -> Bool { !blockers.contains { $0.contains(CGPoint(x: x, y: height - 8)) } }
            let candidates = stride(from: CGFloat(80), to: screen.frame.width - 80, by: 10).filter { x in
                (0...20).allSatisfy { free(x + CGFloat($0) * 20 - 200) }
            }
            guard let x = candidates.first(where: { $0 > 300 }) ?? candidates.first else {
                print("FEHLER  kein freier Bodenstreifen auf dem Hauptbildschirm (Fenster schließen?)"); exit(1)
            }

            simulatedMouse = NSPoint(x: x, y: 8)
            updateHover()
            check(!main.window.ignoresMouseEvents, "Über Bodenschnee nimmt das Overlay Klicks an")
            simulatedMouse = NSPoint(x: x, y: height / 2)
            updateHover()
            check(main.window.ignoresMouseEvents, "In der Luft gehen Klicks durch")
            if let window = scan.windows.first(where: { !$0.isWidget && $0.bounds.maxY < height }) {
                let inside = NSPoint(x: window.bounds.midX, y: height - window.bounds.midY)
                simulatedMouse = inside
                updateHover()
                check(main.window.ignoresMouseEvents, "Über einem Fenster gehen Klicks durch")
            }

            // Three balls, big to small, stacked at x.
            for (index, distance) in [CGFloat(520), 280, 130].enumerated() {
                let start = x - 200
                handleMouse(0, .down, NSPoint(x: start, y: 6))
                check(dragging == 0, "Kugel \(index + 1) gegriffen")
                var px = start
                while px < start + distance {
                    px += 6
                    handleMouse(0, .dragged, NSPoint(x: min(px, x + 200), y: 4))
                    await wait(1.0 / 120)
                }
                handleMouse(0, .dragged, NSPoint(x: x + CGFloat(index), y: 300))
                handleMouse(0, .up, NSPoint(x: x + CGFloat(index), y: 300))
                check(dragging == nil, "Kugel \(index + 1) losgelassen")
                await wait(1.2)
            }
            var stacks: [SnowStack] = []
            main.renderer.withSimulation { stacks = $0.stacks }
            check(stacks.contains { $0.isSnowman && abs($0.x - x) < 4 }, "Schneemann steht bei x \(Int(x)) (\(stacks.map(\.volumes.count)))")
            simulatedMouse = nil
            print("Selbsttest beendet, Fehler: \(failures)")
            await wait(6)
            exit(Int32(failures))
        }
    }
}
