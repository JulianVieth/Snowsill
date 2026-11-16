import AppKit
import SwiftUI

@main
struct SnowPileApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("SnowPile", systemImage: "snowflake") {
            Button("Beenden") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let overlay = OverlayController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        overlay.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay.stop()
    }
}
