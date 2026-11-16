import CoreGraphics
import Foundation
import SnowPileCore

/// Polls the window list on a background queue and hands changed lists to the main actor as immutable snapshots.
final class WindowTracker: @unchecked Sendable {
    // `last` is only touched on `queue`; `timer` only on the main actor.
    private let queue = DispatchQueue(label: "SnowPile.WindowTracker", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var last: [WindowInfo]?
    private let ownPID = getpid()

    func start(interval: TimeInterval = 1.0 / 12, onChange: @escaping @MainActor @Sendable ([WindowInfo]) -> Void) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.poll(onChange) }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll(_ onChange: @escaping @MainActor @Sendable ([WindowInfo]) -> Void) {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return }
        let windows = WindowFilter.parse(raw, ownPID: ownPID)
        guard windows != last else { return }
        last = windows
        Task { @MainActor in onChange(windows) }
    }
}
