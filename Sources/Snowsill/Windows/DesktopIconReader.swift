import AppKit
import ApplicationServices
import QuartzCore

/// Reads the frames of Finder's desktop icons through the Accessibility API, on a background queue every two seconds
/// (icons rarely move). Needs the Accessibility permission; without it, it delivers nothing and asks no questions.
final class DesktopIconReader: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (_ frames: [CGRect]) -> Void

    private static let interval: TimeInterval = 2
    private let queue = DispatchQueue(label: "Snowsill.DesktopIconReader", qos: .utility)
    // Only touched on `queue`.
    private var timer: DispatchSourceTimer?
    private var last: [CGRect]?

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system dialog that leads to the Accessibility settings.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start(onChange: @escaping Handler) {
        queue.async { [self] in
            timer?.cancel()
            last = nil
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.poll(onChange) }
            timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(200))
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            last = nil
        }
    }

    private func poll(_ onChange: @escaping Handler) {
        let frames = Self.isTrusted ? Self.readIconFrames() : []
        guard frames != last else { return }
        last = frames
        Task { @MainActor in onChange(frames) }
    }

    /// Finder → desktop scroll area(s) → icons. Frames are global, origin top left (like CG).
    static func readIconFrames() -> [CGRect] {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return [] }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var frames: [CGRect] = []
        for child in children(of: app) where role(of: child) == kAXScrollAreaRole as String {
            collectIcons(in: child, depth: 0, into: &frames)
        }
        return frames.sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
    }

    private static func collectIcons(in element: AXUIElement, depth: Int, into frames: inout [CGRect]) {
        guard depth < 4 else { return }
        for child in children(of: element) {
            if role(of: child) == kAXImageRole as String, let frame = frame(of: child) {
                frames.append(frame)
            } else {
                collectIcons(in: child, depth: depth + 1, into: &frames)
            }
        }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
