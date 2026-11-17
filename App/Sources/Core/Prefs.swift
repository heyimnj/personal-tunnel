import Foundation
import Security
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

    /// «Kill switch» (3.1.6): while the VPN is on but not connected (reconnecting,
    /// or ended by the system) nothing goes to the internet around it.
    static var killSwitch: Bool {
        get { bool("pt.net.killSwitch", false) }
        set { defaults.set(newValue, forKey: "pt.net.killSwitch") }
    }

    /// 3.2.7: the tunnel's loopback way out for the app's tests with the kill
    /// switch (`ProbeExit`): a port and a random login made once and kept, so the
    /// configuration the tunnel runs and the app's tests agree across launches
    /// and reloads. Loopback only; the login keeps other apps out.
    static var probeExit: ProbeExit {
        if let data = defaults.data(forKey: "pt.net.probeExit"), let exit = try? JSONDecoder().decode(ProbeExit.self, from: data),
           ProbeExit.ports.contains(exit.port), !exit.username.isEmpty, !exit.password.isEmpty {
            return exit
        }
        func random() -> String {
            var bytes = [UInt8](repeating: 0, count: 16)
            if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
                return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        let exit = ProbeExit(port: Int.random(in: ProbeExit.ports), username: random(), password: random())
        if let data = try? JSONEncoder().encode(exit) { defaults.set(data, forKey: "pt.net.probeExit") }
        return exit
    }

    /// 3.3 (PT-08, the owner's decision): the kill switch is on for a new install;
    /// an install that ran before keeps what it had (off unless turned on). Runs
    /// once at launch, before anything marks the install as run.
    static func seedKillSwitch(hasLegacyData: Bool) {
        guard defaults.object(forKey: "pt.net.killSwitch") == nil else { return }
        let ranBefore = defaults.object(forKey: "pt.migrated.v1") != nil || hasLegacyData
        killSwitch = !ranBefore
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

    static var appLock: Bool {
        get { bool("pt.appLock", false) }
        set { defaults.set(newValue, forKey: "pt.appLock") }
    }

    /// 3.3 (PT-09): «DNS вне туннеля» — which resolvers find server addresses
    /// (a `DirectResolvers.presets` id).
    static var directResolvers: String {
        get { defaults.string(forKey: "pt.net.directResolvers") ?? DirectResolvers.defaultPreset }
        set { defaults.set(newValue, forKey: "pt.net.directResolvers") }
    }

    static func resolverTitle(_ preset: String) -> String {
        switch preset {
        case "cloudflare": return "Cloudflare"
        case "google": return "Google"
        case "quad9": return "Quad9"
        case "yandex": return L("Яндекс")
        default: return L("Cloudflare и Google")
        }
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
        // 3.3 (PT-16): «warn» unless a diagnostic half hour is running.
        options.logLevel = verboseLog ? "trace" : (diagnosticLogActive ? "info" : "warn")
        options.adBlocking = adBlocking
        options.adBlockLevel = adBlockLevel
        options.blockEncryptedDNS = blockEncryptedDNS
        options.bypassRussia = bypassRussia
        options.bypassPrivate = localNetwork
        options.autoSelect = autoSelect
        options.directResolvers = DirectResolvers.addresses(directResolvers)
        return options
    }

    /// 3.3 beta 4: «Автообновление подписок» — every subscription is fetched at each
    /// launch and return to the app, and one a day old also while the app is open.
    static var autoUpdateSubscriptions: Bool {
        get { bool("pt.subscriptions.autoUpdate", true) }
        set { defaults.set(newValue, forKey: "pt.subscriptions.autoUpdate") }
    }

    /// 3.2.10: when subscriptions update themselves: `SubscriptionSchedule.everyDay`
    /// (once in 24 hours) or an hour of the day, 0–23 (once a day after it).
    static var subscriptionUpdateHour: Int {
        get { defaults.object(forKey: "pt.subscriptions.updateHour") == nil ? SubscriptionSchedule.everyDay : defaults.integer(forKey: "pt.subscriptions.updateHour") }
        set { defaults.set(newValue, forKey: "pt.subscriptions.updateHour") }
    }

    /// The choices of «Время обновления»: every 24 hours, or 00:00 … 23:00.
    static var subscriptionUpdateOptions: [(value: String, title: String)] {
        let hours: [(value: String, title: String)] = (0 ... 23).map { (value: String($0), title: String(format: "%02d:00", $0)) }
        return [(value: String(SubscriptionSchedule.everyDay), title: L("Каждые 24 часа"))] + hours
    }

    /// The build that last fetched every subscription again (3.1.2).
    static var refreshedForBuild: String? {
        get { defaults.string(forKey: "pt.refresh.build") }
        set { defaults.set(newValue, forKey: "pt.refresh.build") }
    }

    static var migratedFrom1x: Bool {
        get { defaults.bool(forKey: "pt.migrated.v1") }
        set { defaults.set(newValue, forKey: "pt.migrated.v1") }
    }

    /// 3.3 (PT-16): end of «Подробный журнал для диагностики» (in the group: the
    /// extension ends it too).
    static var diagnosticLogUntil: Date? {
        get {
            let value = AppGroup.defaults.double(forKey: SharedKey.diagnosticLogUntil)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        set {
            if let newValue { AppGroup.defaults.set(newValue.timeIntervalSince1970, forKey: SharedKey.diagnosticLogUntil) } else { AppGroup.defaults.removeObject(forKey: SharedKey.diagnosticLogUntil) }
        }
    }

    static var diagnosticLogActive: Bool { (diagnosticLogUntil ?? .distantPast) > Date() }

    // MARK: Privacy (3.2.1)

    /// «Передавать данные устройства провайдеру» for a subscription being added:
    /// the first download already sends them, so the choice is made beforehand.
    static var deviceDataForNewSubscriptions: Bool {
        get { bool("pt.privacy.deviceDataForNew", true) }
        set { defaults.set(newValue, forKey: "pt.privacy.deviceDataForNew") }
    }

    /// «Удалить все данные»: what belongs to the servers and subscriptions. The
    /// interface and network switches stay.
    static func eraseServerData() {
        for key in ["pt.serverFilters", "vpndirect.favorite.servers", "pt.expandedSubscriptions", "pt.autoSelect", Arrangement.defaultsKey] {
            defaults.removeObject(forKey: key)
        }
    }
}
