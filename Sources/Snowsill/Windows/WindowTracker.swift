import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import SnowsillCore

/// Polls the window list on a background queue and hands changed lists to the main actor as immutable snapshots.
/// Polls at 12 Hz while nothing moves and at 60 Hz right after a change, so snow keeps up with a dragged window.
/// In fast mode every poll is delivered, also unchanged ones: that is how the simulation learns a window stopped.
final class WindowTracker: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (_ scan: WindowScan, _ timestamp: CFTimeInterval) -> Void

    private static let idleInterval: TimeInterval = 1.0 / 12
    private static let activeInterval: TimeInterval = 1.0 / 60
    /// How long to stay at the fast rate after the last change.
    private static let activeDuration: CFTimeInterval = 0.5

    // All state below is only touched on `queue`.
    private let queue = DispatchQueue(label: "Snowsill.WindowTracker", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var last: WindowScan?
    /// Notification Center draws the desktop widgets. Looked up now and then, since it can restart.
    private var widgetPID: Int32?
    private var widgetLookup: CFTimeInterval = -.infinity
    private var lastChange: CFTimeInterval = -.infinity
    private var isFast = false
    private let ownPID = getpid()

    func start(onChange: @escaping Handler) {
        queue.async { [self] in
            stopOnQueue()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.poll(onChange) }
            self.timer = timer
            isFast = false
            schedule(Self.idleInterval, startNow: true)
            timer.resume()
        }
    }

    func stop() {
        queue.sync { stopOnQueue() }
    }

    private func stopOnQueue() {
        timer?.cancel()
        timer = nil
        last = nil
    }

    private func schedule(_ interval: TimeInterval, startNow: Bool = false) {
        timer?.schedule(deadline: startNow ? .now() : .now() + interval, repeating: interval, leeway: .milliseconds(2))
    }

    /// Screen frames in CG coordinates, safe off the main thread (unlike `NSScreen`).
    private static func screenFrames() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    private func poll(_ onChange: @escaping Handler) {
        let now = CACurrentMediaTime()
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return }
        if now - widgetLookup > 5 {
            widgetLookup = now
            widgetPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
                .first?.processIdentifier
        }
        var scan = WindowFilter.scan(raw, ownPID: ownPID, widgetPID: widgetPID)
        let candidates = WindowFilter.fullScreenCandidates(raw, screens: Self.screenFrames(), ownPID: ownPID)
        if !candidates.isEmpty,
           let desktop = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            // Only in this rare case: the list above leaves out the desktop windows needed to confirm.
            scan.fullScreens = candidates.filter { WindowFilter.isFullScreen($0, desktopList: desktop) }
        }

        let changed = scan != last
        if changed || isFast {
            Task { @MainActor in onChange(scan, now) }
        }
        if changed {
            last = scan
            lastChange = now
            if !isFast {
                isFast = true
                schedule(Self.activeInterval)
            }
        } else if isFast, now - lastChange > Self.activeDuration {
            isFast = false
            schedule(Self.idleInterval)
        }
    }
}
