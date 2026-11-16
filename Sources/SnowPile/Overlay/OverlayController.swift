import AppKit
import SnowPileCore
import SpriteKit

@MainActor
final class OverlayController {
    private var windows: [OverlayWindow] = []
    private var screenObserver: NSObjectProtocol?
    private let debug = ProcessInfo.processInfo.environment["SNOWPILE_DEBUG"] == "1"

    func start() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        rebuild()
    }

    func stop() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        tearDown()
    }

    private func tearDown() {
        for window in windows {
            (window.contentView as? SKView)?.presentScene(nil)
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private func rebuild() {
        tearDown()
        // Milestone 1: only the main screen (screens[0] defines the CG origin).
        guard let mainScreen = NSScreen.screens.first else { return }
        let mainHeight = mainScreen.frame.height

        let window = OverlayWindow(screen: mainScreen)
        let view = SKView(frame: NSRect(origin: .zero, size: mainScreen.frame.size))
        view.allowsTransparency = true
        view.preferredFramesPerSecond = 60
        view.ignoresSiblingOrder = true
        if debug {
            view.showsFPS = true
            view.showsNodeCount = true
        }

        let screenFrameCG = Coordinates.cgRect(fromAppKit: mainScreen.frame, mainScreenHeight: mainHeight)
        let scene = SnowScene(screenFrameCG: screenFrameCG, debug: debug)
        window.contentView = view
        view.presentScene(scene)
        window.orderFrontRegardless()
        windows.append(window)
    }
}
