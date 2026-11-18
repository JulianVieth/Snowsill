import Combine
import Foundation
import ServiceManagement
import SnowsillCore

/// User settings, persisted in `UserDefaults`. Changes are published so the overlay can apply them live.
@MainActor
final class SnowSettings: ObservableObject {
    enum Intensity: String, CaseIterable, Identifiable {
        case light, medium, blizzard
        var id: String { rawValue }
        var title: String {
            switch self {
            case .light: "Leicht"
            case .medium: "Mittel"
            case .blizzard: "Schneesturm"
            }
        }
    }

    enum FlakeSize: String, CaseIterable, Identifiable {
        case small, normal, large
        var id: String { rawValue }
        var title: String {
            switch self {
            case .small: "Klein"
            case .normal: "Normal"
            case .large: "Groß"
            }
        }
    }

    enum Wind: String, CaseIterable, Identifiable {
        case calm, breeze, stormy
        var id: String { rawValue }
        var title: String {
            switch self {
            case .calm: "Windstill"
            case .breeze: "Brise"
            case .stormy: "Stürmisch"
            }
        }
    }

    private let defaults: UserDefaults

    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: "enabled") } }
    @Published var intensity: Intensity { didSet { defaults.set(intensity.rawValue, forKey: "intensity") } }
    @Published var flakeSize: FlakeSize { didSet { defaults.set(flakeSize.rawValue, forKey: "flakeSize") } }
    @Published var wind: Wind { didSet { defaults.set(wind.rawValue, forKey: "wind") } }
    @Published var onlyActiveWindow: Bool { didSet { defaults.set(onlyActiveWindow, forKey: "onlyActiveWindow") } }
    @Published var groundEnabled: Bool { didSet { defaults.set(groundEnabled, forKey: "groundEnabled") } }
    @Published var plowEnabled: Bool { didSet { defaults.set(plowEnabled, forKey: "plowEnabled") } }
    @Published var snowmenEnabled: Bool { didSet { defaults.set(snowmenEnabled, forKey: "snowmenEnabled") } }
    @Published var iciclesEnabled: Bool { didSet { defaults.set(iciclesEnabled, forKey: "iciclesEnabled") } }
    @Published var widgetsEnabled: Bool { didSet { defaults.set(widgetsEnabled, forKey: "widgetsEnabled") } }
    /// Needs the Accessibility permission, so it is off until switched on.
    @Published var iconsEnabled: Bool { didSet { defaults.set(iconsEnabled, forKey: "iconsEnabled") } }
    /// Last error from registering the login item, shown in the menu.
    @Published var loginItemError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        isEnabled = bool("enabled", true)
        intensity = Intensity(rawValue: defaults.string(forKey: "intensity") ?? "") ?? .medium
        flakeSize = FlakeSize(rawValue: defaults.string(forKey: "flakeSize") ?? "") ?? .normal
        wind = Wind(rawValue: defaults.string(forKey: "wind") ?? "") ?? .breeze
        onlyActiveWindow = bool("onlyActiveWindow", false)
        groundEnabled = bool("groundEnabled", true)
        plowEnabled = bool("plowEnabled", true)
        snowmenEnabled = bool("snowmenEnabled", true)
        iciclesEnabled = bool("iciclesEnabled", true)
        widgetsEnabled = bool("widgetsEnabled", true)
        iconsEnabled = bool("iconsEnabled", false)
    }

    /// The simulation parameters these settings stand for.
    var snowConfig: SnowConfig {
        var config = SnowConfig()
        switch intensity {
        case .light:
            config.maxFlakes = 350
            config.spawnRate = 16
        case .medium:
            config.maxFlakes = 800
            config.spawnRate = 40
        case .blizzard:
            config.maxFlakes = 2200
            config.spawnRate = 120
        }
        switch flakeSize {
        case .small: config.radiusRange = 0.9...2.6
        case .normal: config.radiusRange = 1.2...3.6
        case .large: config.radiusRange = 1.8...5.0
        }
        switch wind {
        case .calm: config.windStrength = 0
        case .breeze: config.windStrength = 1
        case .stormy: config.windStrength = 2.4
        }
        config.groundEnabled = groundEnabled
        config.plowEnabled = plowEnabled
        config.snowmenEnabled = snowmenEnabled
        config.iciclesEnabled = iciclesEnabled
        return config
    }

    // MARK: - Launch at login

    /// Only works from the .app bundle (`scripts/bundle.sh`), not from `swift run`.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                loginItemError = nil
            } catch {
                loginItemError = Bundle.main.bundleURL.pathExtension == "app"
                    ? error.localizedDescription
                    : "Nur im App-Bundle möglich (scripts/bundle.sh)"
            }
        }
    }
}
