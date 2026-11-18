import AppKit
import ServiceManagement
import SwiftUI

@main
struct SnowsillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Snowsill", systemImage: "snowflake") {
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
        Toggle("Schnee im Vollbildmodus", isOn: $settings.snowInFullScreen)
        Toggle("Schnee auf Schreibtisch-Icons", isOn: Binding(
            get: { settings.iconsEnabled },
            set: { on in
                settings.iconsEnabled = on
                if on && !DesktopIconReader.isTrusted { DesktopIconReader.requestTrust() }
            }
        ))
        if settings.iconsEnabled && !DesktopIconReader.isTrusted {
            Text("Braucht „Bedienungshilfen“ in den Systemeinstellungen")
        }
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
        Button("Snowsill beenden") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = SnowSettings()
    private lazy var overlay = OverlayController(settings: settings)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        if let scenario = env["SNOWSILL_SNAPSHOT"] {
            let out = env["SNOWSILL_SNAPSHOT_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            exit(SnapshotRunner.run(scenarioName: scenario, outputDirectory: out, debug: env["SNOWSILL_DEBUG"] == "1"))
        }
        if env["SNOWSILL_ICONS"] == "list" {
            print("Bedienungshilfen: \(DesktopIconReader.isTrusted ? "erlaubt" : "nicht erlaubt")")
            for frame in DesktopIconReader.readIconFrames() { print("Icon \(frame)") }
            exit(0)
        }
        if let action = env["SNOWSILL_LOGIN_ITEM"] {
            exit(LoginItemCheck.run(action))
        }
        // Two instances would snow twice and block each other's clicks (each sees the other's overlay as a floating
        // window). Happens when the bundle runs and `swift run` starts another one.
        let own = ProcessInfo.processInfo.processIdentifier
        if let other = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier != own && ($0.bundleIdentifier == "local.snowsill.Snowsill" || $0.localizedName == "Snowsill")
        }) {
            print("Snowsill läuft bereits (PID \(other.processIdentifier)). Diese Instanz beendet sich.")
            exit(0)
        }
        NSApp.setActivationPolicy(.accessory)
        overlay.start()
        if env["SNOWSILL_SELFTEST"] == "mouse" { overlay.runMouseSelfTest() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay.stop()
    }

    func shakeOff() {
        overlay.shakeOff()
    }
}

/// Hidden check for the login item, since it only works from the bundle: `SNOWSILL_LOGIN_ITEM=status|on|off`.
enum LoginItemCheck {
    static func run(_ action: String) -> Int32 {
        let service = SMAppService.mainApp
        do {
            switch action {
            case "on": try service.register()
            case "off": try service.unregister()
            default: break
            }
        } catch {
            print("Fehler: \(error.localizedDescription)")
            return 1
        }
        let names: [SMAppService.Status: String] = [
            .notRegistered: "nicht registriert", .enabled: "aktiv", .requiresApproval: "wartet auf Freigabe", .notFound: "nicht gefunden",
        ]
        print("Login-Objekt: \(names[service.status] ?? "unbekannt")")
        return 0
    }
}
