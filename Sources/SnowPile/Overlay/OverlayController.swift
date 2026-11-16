import AppKit
import MetalKit
import SnowPileCore

@MainActor
final class OverlayController {
    private var windows: [OverlayWindow] = []
    // MTKView holds its delegate weakly.
    private var renderers: [SnowRenderer] = []
    private var screenObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private let tracker = WindowTracker()
    private var windowList: [WindowInfo] = []
    private var windowListTimestamp: CFTimeInterval = 0
    /// Last active app other than SnowPile itself, so opening our menu doesn't shake snow off the active window.
    private var activePID: Int32?
    private let debug = ProcessInfo.processInfo.environment["SNOWPILE_DEBUG"] == "1"

    func start() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }

        let ownPID = getpid()
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != ownPID {
            activePID = pid
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let pid = app?.processIdentifier, pid != ownPID else { return }
            MainActor.assumeIsolated {
                self?.activePID = pid
                self?.applyWindows()
            }
        }

        rebuild()
        tracker.start { [weak self] windows, timestamp in
            self?.windowList = windows
            self?.windowListTimestamp = timestamp
            self?.applyWindows()
        }
    }

    func stop() {
        tracker.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        screenObserver = nil
        activationObserver = nil
        tearDown()
    }

    /// Milestone 3: only the active window carries snow.
    private func applyWindows() {
        let active = WindowFilter.activeWindow(in: windowList, activePID: activePID)
        let windows = active.map { [$0] } ?? []
        for renderer in renderers { renderer.setWindows(windows, timestamp: windowListTimestamp) }
    }

    private func tearDown() {
        for window in windows {
            (window.contentView as? MTKView)?.isPaused = true
            window.orderOut(nil)
        }
        windows.removeAll()
        renderers.removeAll()
    }

    private func rebuild() {
        tearDown()
        // Milestone 1: only the main screen (screens[0] defines the CG origin).
        guard let mainScreen = NSScreen.screens.first,
              let device = MTLCreateSystemDefaultDevice()
        else { return }
        let mainHeight = mainScreen.frame.height

        let window = OverlayWindow(screen: mainScreen)
        let view = MTKView(frame: NSRect(origin: .zero, size: mainScreen.frame.size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.layer?.isOpaque = false

        let screenFrameCG = Coordinates.cgRect(fromAppKit: mainScreen.frame, mainScreenHeight: mainHeight)
        guard let renderer = SnowRenderer(view: view, screenFrameCG: screenFrameCG, debug: debug) else { return }
        view.delegate = renderer
        window.contentView = view
        window.orderFrontRegardless()
        windows.append(window)
        renderers.append(renderer)
        applyWindows()
    }
}
