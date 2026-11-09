import Foundation

/// The file written by "Save a backup to Files".
public struct BackupArchive: Codable, Sendable {
    public static let formatName = "personal-tunnel-backup"
    public static let currentVersion = 2

    public var format: String
    public var version: Int
    public var createdAt: Date
    public var appVersion: String
    public var library: ServerLibrary
    public var tunnelOptions: TunnelOptions
    /// Interface preferences keyed by their `UserDefaults` name.
    public var preferences: [String: JSON]
    /// Imported font files by file name.
    public var fonts: [String: Data]

    public init(appVersion: String, library: ServerLibrary, tunnelOptions: TunnelOptions, preferences: [String: JSON], fonts: [String: Data], createdAt: Date = Date()) {
        format = BackupArchive.formatName
        version = BackupArchive.currentVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.library = library
        self.tunnelOptions = tunnelOptions
        self.preferences = preferences
        self.fonts = fonts
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public enum ReadError: Error, CustomStringConvertible {
        case unknownFormat
        case newerVersion(Int)
        case noServers

        public var description: String {
            switch self {
            case .unknownFormat: return "Это не резервная копия Personal Tunnel."
            case let .newerVersion(version): return "Копия создана более новой версией приложения (формат \(version)). Обновите приложение."
            case .noServers: return "В резервной копии нет подписок и серверов."
            }
        }
    }

    /// Reads a backup of this version or of Personal Tunnel 1.x.
    public static func read(_ data: Data) throws -> BackupArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let archive = try? decoder.decode(BackupArchive.self, from: data), archive.format == formatName {
            guard archive.version <= currentVersion else { throw ReadError.newerVersion(archive.version) }
            return archive
        }
        if let legacy = try? JSONDecoder().decode(LegacyBackupV1.self, from: data) {
            return try legacy.converted()
        }
        throw ReadError.unknownFormat
    }
}

/// The backup format of Personal Tunnel 1.x (`.ptbackup`, JSON).
struct LegacyBackupV1: Decodable {
    struct Profile: Decodable {
        let name: String
        let config: String
        let remoteURL: String?
        let autoUpdate: Bool?
        let interval: Int32?
        let disabled: Bool?
    }

    let version: Int
    let profiles: [Profile]
    let uiSettings: Data?
    let networkSettings: [String: Data]?
    let fonts: [String: Data]?

    func converted() throws -> BackupArchive {
        let subscriptions = profiles.map(LegacyImport.subscription)
        guard !subscriptions.isEmpty else { throw BackupArchive.ReadError.noServers }
        var library = ServerLibrary(subscriptions: subscriptions)
        library.repairSelection()
        var preferences: [String: JSON] = [:]
        if let uiSettings, let plist = try? PropertyListSerialization.propertyList(from: uiSettings, options: [], format: nil) as? [String: Any] {
            for (key, value) in plist {
                if let json = LegacyImport.json(fromPlist: value) { preferences[key] = json }
            }
        }
        var options = TunnelOptions()
        if let network = networkSettings {
            if let value = LegacyImport.bool(network["ad_blocking_enabled"]) { options.adBlocking = value }
            if let value = LegacyImport.bool(network["bypass_russian_sites"]) { options.bypassRussia = value }
            if let value = LegacyImport.bool(network["exclude_local_networks"]) { preferences["tunnel.excludeLocalNetworks"] = .bool(value) }
            if let value = LegacyImport.bool(network["include_all_networks"]) { preferences["tunnel.includeAllNetworks"] = .bool(value) }
            if let value = LegacyImport.bool(network["exclude_apns"]) { preferences["tunnel.excludeAPNs"] = .bool(value) }
        }
        return BackupArchive(appVersion: "1.x", library: library, tunnelOptions: options, preferences: preferences, fonts: fonts ?? [:])
    }
}

/// Converts data written by Personal Tunnel 1.x.
public enum LegacyImport {
    /// One 1.x profile: a sing-box configuration, optionally from a URL.
    /// `intervalMinutes` is the 1.x auto-update interval.
    public static func subscription(name: String, config: String, remoteURL: String?, autoUpdate: Bool, intervalMinutes: Int, disabled: Bool) -> Subscription {
        let url = remoteURL?.trimmed.nonEmpty
        var subscription = Subscription(name: name, url: url, isEnabled: !disabled, autoUpdate: url != nil && autoUpdate)
        if intervalMinutes > 0 { subscription.updateIntervalHours = max(1, intervalMinutes / 60) }
        if let content = try? ContentDecoder.decode(config) {
            subscription.replaceServers(with: content.servers)
            subscription.skipped = content.skipped
        }
        subscription.hasCustomName = true
        subscription.lastUpdated = url == nil ? nil : Date(timeIntervalSince1970: 0)
        return subscription
    }

    static func subscription(_ profile: LegacyBackupV1.Profile) -> Subscription {
        subscription(
            name: profile.name,
            config: profile.config,
            remoteURL: profile.remoteURL,
            autoUpdate: profile.autoUpdate ?? true,
            intervalMinutes: Int(profile.interval ?? 0),
            disabled: profile.disabled ?? false
        )
    }

    /// 1.x stored booleans as one byte.
    static func bool(_ data: Data?) -> Bool? {
        guard let data, data.count == 1 else { return nil }
        return data[data.startIndex] != 0
    }

    static func json(fromPlist value: Any) -> JSON? {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            let type = String(cString: number.objCType)
            if type == "c" || type == "B" { return .bool(number.boolValue) }
            if type == "d" || type == "f" { return .double(number.doubleValue) }
            return .int(number.intValue)
        case let array as [Any]:
            return .array(array.compactMap(json(fromPlist:)))
        default:
            return nil
        }
    }
}
