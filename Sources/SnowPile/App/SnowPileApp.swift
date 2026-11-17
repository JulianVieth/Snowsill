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
        let env = ProcessInfo.processInfo.environment
        if let scenario = env["SNOWPILE_SNAPSHOT"] {
            let out = env["SNOWPILE_SNAPSHOT_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            exit(SnapshotRunner.run(scenarioName: scenario, outputDirectory: out, debug: env["SNOWPILE_DEBUG"] == "1"))
        }
        NSApp.setActivationPolicy(.accessory)
        overlay.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay.stop()
    }
}
