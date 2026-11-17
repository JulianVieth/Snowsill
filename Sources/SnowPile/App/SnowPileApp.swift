import AppKit
import SwiftUI

@main
struct SnowPileApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("SnowPile", systemImage: "snowflake") {
            MenuContent(settings: appDelegate.settings) { appDelegate.shakeOff() }
        }
    }
}

struct MenuContent: View {
    @ObservedObject var settings: SnowSettings
    let shakeOff: () -> Void

    var body: some View {
        Toggle("Schnee", isOn: $settings.isEnabled)
            .keyboardShortcut("s")
        Divider()
        Picker("Intensität", selection: $settings.intensity) {
            ForEach(SnowSettings.Intensity.allCases) { Text($0.title).tag($0) }
        }
        Picker("Flockengröße", selection: $settings.flakeSize) {
            ForEach(SnowSettings.FlakeSize.allCases) { Text($0.title).tag($0) }
        }
        Picker("Wind", selection: $settings.wind) {
            ForEach(SnowSettings.Wind.allCases) { Text($0.title).tag($0) }
        }
        Picker("Schnee liegt auf", selection: $settings.onlyActiveWindow) {
            Text("Allen Fenstern").tag(false)
            Text("Nur dem aktiven Fenster").tag(true)
        }
        Divider()
        Toggle("Schnee am Boden", isOn: $settings.groundEnabled)
        Toggle("Schneeschaufler", isOn: $settings.plowEnabled)
            .disabled(!settings.groundEnabled)
        Toggle("Schneemänner bauen", isOn: $settings.snowmenEnabled)
            .disabled(!settings.groundEnabled)
        Toggle("Eiszapfen", isOn: $settings.iciclesEnabled)
        Toggle("Schnee auf Widgets", isOn: $settings.widgetsEnabled)
        Divider()
        Button("Schnee abschütteln", action: shakeOff)
        Toggle("Beim Anmelden starten", isOn: Binding(
            get: { settings.launchAtLogin },
            set: { settings.launchAtLogin = $0 }
        ))
        if let error = settings.loginItemError {
            Text(error)
        }
        Divider()
        Button("SnowPile beenden") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SnowSettings()
    private lazy var overlay = OverlayController(settings: settings)

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

    func shakeOff() {
        overlay.shakeOff()
    }
}
