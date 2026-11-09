import Observation
import SwiftUI
import TunnelKit

enum Appearance: String, CaseIterable, Identifiable {
    case classic
    case modern
    case material

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return L("Классический")
        case .modern: return L("Современный")
        case .material: return "Material You"
        }
    }

    var defaultAccentHex: String {
        switch self {
        case .classic: return "#3478F6"
        case .modern: return "#FA243C"
        case .material: return "#3478F6"
        }
    }
}

enum ThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("Как в системе")
        case .light: return L("Светлая")
        case .dark: return L("Тёмная")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case ru
    case en

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("Как в системе")
        case .ru: return "Русский"
        case .en: return "English"
        }
    }
}

/// Interface preferences. The `UserDefaults` keys are the ones Personal
/// Tunnel 1.x used, so an update keeps the user's choices.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    var theme: ThemeMode {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    var amoled: Bool {
        didSet { defaults.set(amoled, forKey: Keys.amoled) }
    }

    var classicAccentHex: String {
        didSet { defaults.set(classicAccentHex, forKey: Keys.classicAccent) }
    }

    var modernAccentHex: String {
        didSet { defaults.set(modernAccentHex, forKey: Keys.modernAccent) }
    }

    var materialSeedHex: String {
        didSet { defaults.set(materialSeedHex, forKey: Keys.materialSeed) }
    }

    /// File name of the imported font in `FontLibrary.directory`, empty for the system font.
    var fontFile: String {
        didSet { defaults.set(fontFile, forKey: Keys.fontFile) }
    }

    var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }

    var pingMode: PingMode {
        didSet { defaults.set(pingMode.rawValue, forKey: Keys.pingMode) }
    }

    var sortByLatency: Bool {
        didSet { defaults.set(sortByLatency, forKey: Keys.sortByLatency) }
    }

    var hideTabLabels: Bool {
        didSet { defaults.set(hideTabLabels, forKey: Keys.hideTabLabels) }
    }

    var haptics: Bool {
        didSet { defaults.set(haptics, forKey: Keys.haptics) }
    }

    /// After a latency test with the tunnel running, and when connecting,
    /// switch to the fastest stable server.
    var connectToBest: Bool {
        didSet { defaults.set(connectToBest, forKey: Keys.connectToBest) }
    }

    var expandedSubscriptions: Set<String> {
        didSet { defaults.set(Array(expandedSubscriptions), forKey: Keys.expanded) }
    }

    private init() {
        let defaults = UserDefaults.standard
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .modern
        theme = ThemeMode(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        amoled = defaults.bool(forKey: Keys.amoled)
        classicAccentHex = defaults.string(forKey: Keys.classicAccent) ?? Appearance.classic.defaultAccentHex
        modernAccentHex = defaults.string(forKey: Keys.modernAccent) ?? Appearance.modern.defaultAccentHex
        materialSeedHex = defaults.string(forKey: Keys.materialSeed) ?? Appearance.material.defaultAccentHex
        fontFile = defaults.string(forKey: Keys.fontFile) ?? ""
        language = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .system
        pingMode = PingMode(rawValue: defaults.string(forKey: Keys.pingMode) ?? "") ?? .primary
        sortByLatency = defaults.bool(forKey: Keys.sortByLatency)
        hideTabLabels = defaults.bool(forKey: Keys.hideTabLabels)
        haptics = defaults.object(forKey: Keys.haptics) as? Bool ?? true
        connectToBest = defaults.bool(forKey: Keys.connectToBest)
        expandedSubscriptions = Set(defaults.stringArray(forKey: Keys.expanded) ?? [])
    }

    var accentHex: String {
        switch appearance {
        case .classic: return classicAccentHex
        case .modern: return modernAccentHex
        case .material: return materialSeedHex
        }
    }

    func setAccentHex(_ hex: String) {
        switch appearance {
        case .classic: classicAccentHex = hex
        case .modern: modernAccentHex = hex
        case .material: materialSeedHex = hex
        }
    }

    /// The language strings resolve to.
    var effectiveLanguage: AppLanguage {
        switch language {
        case .ru, .en: return language
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "ru"
            return preferred.hasPrefix("ru") || preferred.hasPrefix("uk") || preferred.hasPrefix("be") || preferred.hasPrefix("kk") ? .ru : .en
        }
    }

    /// Values saved into backups.
    func exportPreferences() -> [String: JSON] {
        [
            Keys.appearance: .string(appearance.rawValue),
            Keys.theme: .string(theme.rawValue),
            Keys.amoled: .bool(amoled),
            Keys.classicAccent: .string(classicAccentHex),
            Keys.modernAccent: .string(modernAccentHex),
            Keys.materialSeed: .string(materialSeedHex),
            Keys.fontFile: .string(fontFile),
            Keys.language: .string(language.rawValue),
            Keys.pingMode: .string(pingMode.rawValue),
            Keys.sortByLatency: .bool(sortByLatency),
            Keys.hideTabLabels: .bool(hideTabLabels),
            Keys.haptics: .bool(haptics),
            Keys.connectToBest: .bool(connectToBest),
        ]
    }

    func importPreferences(_ values: [String: JSON]) {
        if let value = values[Keys.appearance]?.string, let parsed = Appearance(rawValue: value) { appearance = parsed }
        if let value = values[Keys.theme]?.string, let parsed = ThemeMode(rawValue: value) { theme = parsed }
        if let value = values[Keys.amoled]?.bool { amoled = value }
        if let value = values[Keys.classicAccent]?.text { classicAccentHex = value }
        if let value = values[Keys.modernAccent]?.text { modernAccentHex = value }
        if let value = values[Keys.materialSeed]?.text { materialSeedHex = value }
        if let value = values[Keys.fontFile]?.string { fontFile = value }
        if let value = values[Keys.language]?.string, let parsed = AppLanguage(rawValue: value) { language = parsed }
        if let value = values[Keys.pingMode]?.string, let parsed = PingMode(rawValue: value) { pingMode = parsed }
        if let value = values[Keys.sortByLatency]?.bool { sortByLatency = value }
        if let value = values[Keys.hideTabLabels]?.bool { hideTabLabels = value }
        if let value = values[Keys.haptics]?.bool { haptics = value }
        if let value = values[Keys.connectToBest]?.bool { connectToBest = value }
    }

    enum Keys {
        static let appearance = "personal.appearance"
        static let theme = "personal.theme"
        static let amoled = "personal.amoled"
        static let classicAccent = "personal.classicAccentHex"
        static let modernAccent = "personal.modernAccentHex"
        static let materialSeed = "personal.materialSeedHex"
        static let fontFile = "personal.fontFile"
        static let language = "personal.language"
        static let pingMode = "personal.pingMode"
        static let sortByLatency = "personal.modernSortByLatency"
        static let hideTabLabels = "personal.hideTabLabels"
        static let haptics = "hapticsEnabled"
        static let connectToBest = "personal.connectToBest"
        static let expanded = "personal.expandedSubscriptions"
    }
}
