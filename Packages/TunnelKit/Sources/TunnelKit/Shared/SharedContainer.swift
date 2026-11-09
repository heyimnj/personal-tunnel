import Foundation

/// Files and preferences shared by the app, the packet tunnel and the widget
/// through the App Group container.
///
/// The App Group identifier is read from the `AppGroupIdentifier` key of the
/// running bundle's Info.plist, which the build sets from `APP_GROUP_IDENTIFIER`
/// so a re-signed IPA can use the group its provisioning profile allows.
public enum SharedContainer {
    public static let fallbackGroupIdentifier = "group.com.personaltunnelapp"

    public static var groupIdentifier: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
           !value.isEmpty, !value.hasPrefix("$(")
        {
            return value
        }
        return fallbackGroupIdentifier
    }

    /// The shared container, or the app's own Application Support directory
    /// when the group is unavailable (unsigned simulator builds, tests).
    public static let directory: URL = {
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) {
                return url
            }
        #endif
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return fallback.appendingPathComponent("PersonalTunnel", isDirectory: true)
    }()

    public static var isAvailable: Bool {
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
            return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) != nil
        #else
            return false
        #endif
    }

    /// Server library (subscriptions and servers).
    public static var libraryURL: URL { directory.appendingPathComponent("library.json") }
    /// The configuration the tunnel starts with when the app is not running
    /// (on-demand, widget, Control Center, Shortcuts).
    public static var activeConfigurationURL: URL { tunnelDirectory.appendingPathComponent("active-config.json") }
    public static var tunnelDirectory: URL { directory.appendingPathComponent("Tunnel", isDirectory: true) }
    /// Libbox base, working and temporary directories.
    public static var coreBaseDirectory: URL { directory }
    public static var coreWorkingDirectory: URL { cacheDirectory.appendingPathComponent("Working", isDirectory: true) }
    public static var cacheDirectory: URL {
        directory.appendingPathComponent("Library", isDirectory: true).appendingPathComponent("Caches", isDirectory: true)
    }

    public static var defaults: UserDefaults {
        UserDefaults(suiteName: groupIdentifier) ?? .standard
    }

    public static func prepareDirectories() {
        for url in [directory, tunnelDirectory, coreWorkingDirectory, cacheDirectory] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Writes atomically with complete-until-first-unlock protection, so the
    /// tunnel can read the file after a reboot once the device was unlocked.
    public static func write(_ data: Data, to url: URL, excludedFromBackup: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try data.write(to: url, options: [.atomic])
        #endif
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excludedFromBackup
        try? mutable.setResourceValues(values)
    }
}

/// Keys of values shared through `SharedContainer.defaults`.
public enum SharedKey {
    /// Name and flag of the server the tunnel uses, for the widget.
    public static let activeServerName = "shared.activeServerName"
    public static let activeServerFlag = "shared.activeServerFlag"
    /// Last error the extension reported at start.
    public static let lastTunnelError = "shared.lastTunnelError"
    /// Bytes transferred today and the day they belong to.
    public static let trafficDay = "shared.trafficDay"
    public static let trafficToday = "shared.trafficToday"
    /// The app's own network requests (JSON array of NetworkActivityEntry).
    public static let networkActivity = "shared.networkActivity"
    /// Network Extension settings applied when the VPN profile is saved.
    public static let includeAllNetworks = "tunnel.includeAllNetworks"
    public static let excludeLocalNetworks = "tunnel.excludeLocalNetworks"
    public static let excludeAPNs = "tunnel.excludeAPNs"
    public static let excludeCellularServices = "tunnel.excludeCellularServices"
    public static let onDemand = "tunnel.onDemand"
    public static let onDemandTrustedSSIDs = "tunnel.onDemandTrustedSSIDs"
    /// Keep subscription links and keys out of iPhone / iCloud backups.
    public static let excludeFromDeviceBackup = "storage.excludeFromDeviceBackup"
}

/// Keys of the tunnel start options passed from the app to the extension.
public enum TunnelStartKey {
    public static let configuration = "configContent"
    public static let serverName = "serverName"
    public static let ignoreMemoryLimit = "ignoreMemoryLimit"
}

/// Messages the app sends to the running extension.
public enum TunnelMessage: String, Codable, Sendable {
    /// Re-read `activeConfigurationURL` and restart the core with it.
    case reload
}

/// Daily traffic accounting stored in the shared defaults.
public enum DailyTraffic {
    static func dayKey(_ date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func today(_ defaults: UserDefaults = SharedContainer.defaults) -> Int64 {
        guard defaults.string(forKey: SharedKey.trafficDay) == dayKey() else { return 0 }
        return Int64(defaults.double(forKey: SharedKey.trafficToday))
    }

    public static func add(_ bytes: Int64, defaults: UserDefaults = SharedContainer.defaults) {
        guard bytes > 0 else { return }
        let key = dayKey()
        var current = defaults.string(forKey: SharedKey.trafficDay) == key ? defaults.double(forKey: SharedKey.trafficToday) : 0
        current += Double(bytes)
        defaults.set(key, forKey: SharedKey.trafficDay)
        defaults.set(current, forKey: SharedKey.trafficToday)
    }
}
