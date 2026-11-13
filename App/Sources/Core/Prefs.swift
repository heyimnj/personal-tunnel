import Foundation
import TunnelCore

enum InterfaceStyle: String {
    case classic
    case minimal = "modern"

    var title: String { self == .classic ? L("Классика") : L("Минималистичный") }
}

/// Settings kept under the 1.x keys, so an update keeps the user's choices.
enum Prefs {
    static let defaults = UserDefaults.standard
    /// Fired after any appearance value changes; the interface restyles itself.
    static let appearanceChanged = Signal()

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private static func double(_ key: String, _ fallback: Double) -> Double {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }

    // MARK: Appearance

    static var style: InterfaceStyle {
        get { InterfaceStyle(rawValue: defaults.string(forKey: "personal.appearance") ?? "classic") ?? .classic }
        set { defaults.set(newValue.rawValue, forKey: "personal.appearance"); appearanceChanged.fire() }
    }

    /// Interface language: `system`, `ru` or `en` (1.x stored the same key).
    static var language: String {
        get { defaults.string(forKey: "personal.language") ?? "system" }
        set {
            defaults.set(newValue, forKey: "personal.language")
            Language.apply()
            appearanceChanged.fire()
        }
    }

    /// `system`, `light` or `dark`.
    static var theme: String {
        get { defaults.string(forKey: "personal.theme") ?? "system" }
        set { defaults.set(newValue, forKey: "personal.theme"); appearanceChanged.fire() }
    }

    /// `clear`, `regular` (blur) or `tinted`.
    static var glassStyle: String {
        get { defaults.string(forKey: "personal.glassStyle") ?? "regular" }
        set { defaults.set(newValue, forKey: "personal.glassStyle"); appearanceChanged.fire() }
    }

    static var solidSettings: Bool {
        get { bool("personal.solidSettings", true) }
        set { defaults.set(newValue, forKey: "personal.solidSettings"); appearanceChanged.fire() }
    }

    static var hideTabLabels: Bool {
        get { bool("personal.hideTabLabels", false) }
        set { defaults.set(newValue, forKey: "personal.hideTabLabels"); appearanceChanged.fire() }
    }

    static var accentDots: Bool {
        get { bool("personal.accentDots", true) }
        set { defaults.set(newValue, forKey: "personal.accentDots"); appearanceChanged.fire() }
    }

    static func opacity(_ key: String) -> Double { min(1, max(0.05, double(key, 1))) }
    static func setOpacity(_ value: Double, _ key: String) {
        defaults.set(value, forKey: key)
        appearanceChanged.fire()
    }

    static let glassOpacityKey = "personal.glassOpacity"
    static let buttonOpacityKey = "personal.buttonOpacity"
    static let serverOpacityKey = "personal.serverOpacity"
    static let cardOpacityKey = "personal.cardOpacity"

    static func accentKey(_ style: InterfaceStyle) -> String {
        style == .classic ? "personal.classicAccentHex" : "personal.modernAccentHex"
    }

    static func accentHex(_ style: InterfaceStyle = Prefs.style) -> String {
        defaults.string(forKey: accentKey(style)) ?? (style == .classic ? "3478F6" : "FA243C")
    }

    static func setAccentHex(_ hex: String?, _ style: InterfaceStyle = Prefs.style) {
        defaults.set(hex, forKey: accentKey(style))
        appearanceChanged.fire()
    }

    static var amoled: Bool {
        get { bool("personal.amoled", true) }
        set { defaults.set(newValue, forKey: "personal.amoled"); appearanceChanged.fire() }
    }

    static var textHex: String? {
        get { defaults.string(forKey: "personal.textHex") }
        set { defaults.set(newValue, forKey: "personal.textHex"); appearanceChanged.fire() }
    }

    static var panelHex: String? {
        get { defaults.string(forKey: "personal.panelHex") }
        set { defaults.set(newValue, forKey: "personal.panelHex"); appearanceChanged.fire() }
    }

    /// File name of the imported font inside Application Support/Fonts.
    static var fontFile: String? {
        get { defaults.string(forKey: "personal.fontFile") }
        set { defaults.set(newValue, forKey: "personal.fontFile"); appearanceChanged.fire() }
    }

    static var fontName: String {
        get { defaults.string(forKey: "personal.fontName") ?? "" }
        set { defaults.set(newValue, forKey: "personal.fontName") }
    }

    static var hapticsEnabled: Bool { bool("hapticsEnabled", true) }

    // MARK: Lists

    static var pingMode: String {
        get { defaults.string(forKey: "personal.pingMode") ?? "primary" }
        set { defaults.set(newValue, forKey: "personal.pingMode") }
    }

    /// «Автопинг» is switched off for now (owner, 3.0.1): no switch in the settings and
    /// no automatic test. Set to true to bring both back.
    static let autoPingAvailable = false

    /// Servers are measured on their own when the app opens and after a subscription update.
    static var autoPing: Bool {
        get { autoPingAvailable && bool("pt.autoPing", true) }
        set { defaults.set(newValue, forKey: "pt.autoPing") }
    }

    /// Tags each subscription's list is narrowed by (subscription id → tags).
    static var serverFilters: [String: [String]] {
        get { defaults.dictionary(forKey: "pt.serverFilters") as? [String: [String]] ?? [:] }
        set { defaults.set(newValue, forKey: "pt.serverFilters") }
    }

    static var sortByLatency: Bool {
        get { bool("personal.modernSortByLatency", false) }
        set { defaults.set(newValue, forKey: "personal.modernSortByLatency") }
    }

    static var arrangement: Arrangement {
        get { Arrangement.decode(defaults.string(forKey: Arrangement.defaultsKey)) }
        set { defaults.set(newValue.encoded, forKey: Arrangement.defaultsKey) }
    }

    static var favorites: Set<String> {
        get { Set(defaults.stringArray(forKey: "vpndirect.favorite.servers") ?? []) }
        set { defaults.set(Array(newValue), forKey: "vpndirect.favorite.servers") }
    }

    static var expandedSubscriptions: Set<Int64> {
        get { Set((defaults.array(forKey: "pt.expandedSubscriptions") as? [NSNumber] ?? []).map(\.int64Value)) }
        set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: "pt.expandedSubscriptions") }
    }

    // MARK: Network (2.0 keys, seeded from the 1.x database on migration)

    static var adBlocking: Bool {
        get { bool("pt.net.adBlocking", true) }
        set { defaults.set(newValue, forKey: "pt.net.adBlocking") }
    }

    static var adBlockLevel: AdBlockLevel {
        get { AdBlockLevel(rawValue: defaults.string(forKey: "pt.net.adBlockLevel") ?? "") ?? .standard }
        set { defaults.set(newValue.rawValue, forKey: "pt.net.adBlockLevel") }
    }

    /// With ad blocking: apps' own encrypted DNS and iCloud Private Relay are refused (3.0.5).
    static var blockEncryptedDNS: Bool {
        get { bool("pt.net.blockEncryptedDNS", true) }
        set { defaults.set(newValue, forKey: "pt.net.blockEncryptedDNS") }
    }

    static var bypassRussia: Bool {
        get { bool("pt.net.bypassRussia", true) }
        set { defaults.set(newValue, forKey: "pt.net.bypassRussia") }
    }

    /// «Локальная сеть»: LAN stays outside the tunnel.
    static var localNetwork: Bool {
        get { bool("pt.net.localNetwork", true) }
        set { defaults.set(newValue, forKey: "pt.net.localNetwork") }
    }

    /// «Защищённый DNS»: the system enforces the tunnel's routes.
    static var secureDNS: Bool {
        get { bool("pt.net.secureDNS", false) }
        set { defaults.set(newValue, forKey: "pt.net.secureDNS") }
    }

    static var autoConnect: Bool {
        get { bool("pt.net.autoConnect", false) }
        set { defaults.set(newValue, forKey: "pt.net.autoConnect") }
    }

    static var unknownWiFi: Bool {
        get { bool("pt.net.unknownWiFi", true) }
        set { defaults.set(newValue, forKey: "pt.net.unknownWiFi") }
    }

    static var autoFailover: Bool {
        get { bool("pt.net.autoFailover", true) }
        set { defaults.set(newValue, forKey: "pt.net.autoFailover") }
    }

    static var appLock: Bool {
        get { bool("pt.appLock", false) }
        set { defaults.set(newValue, forKey: "pt.appLock") }
    }

    /// «Автовыбор» instead of the manually chosen server.
    static var autoSelect: Bool {
        get { bool("pt.autoSelect", false) }
        set { defaults.set(newValue, forKey: "pt.autoSelect") }
    }

    /// «Подробный журнал»: the core logs every level (one line per packet at TRACE).
    static var verboseLog: Bool {
        get { bool("pt.verboseLog", false) }
        set { defaults.set(newValue, forKey: "pt.verboseLog") }
    }

    static var tunnelOptions: TunnelOptions {
        var options = TunnelOptions()
        options.logLevel = verboseLog ? "trace" : "info"
        options.adBlocking = adBlocking
        options.adBlockLevel = adBlockLevel
        options.blockEncryptedDNS = blockEncryptedDNS
        options.bypassRussia = bypassRussia
        options.bypassPrivate = localNetwork
        options.autoSelect = autoSelect
        return options
    }

    static var migratedFrom1x: Bool {
        get { defaults.bool(forKey: "pt.migrated.v1") }
        set { defaults.set(newValue, forKey: "pt.migrated.v1") }
    }
}
