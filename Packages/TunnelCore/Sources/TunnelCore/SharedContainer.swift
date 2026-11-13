import Foundation

/// The App Group shared by the app and the packet tunnel.
public enum AppGroup {
    /// The group the build was made for (`AppGroupIdentifier` in Info.plist).
    public static var identifier: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
        return (value?.isEmpty == false ? value : nil) ?? "group.com.personaltunnelapp"
    }

    public static var defaults: UserDefaults { UserDefaults(suiteName: identifier) ?? .standard }

    #if canImport(Darwin)
    /// `nil` when the signature does not grant the group: the tunnel cannot work then.
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
    #endif
}

/// Where things live inside the shared container. The core's own paths are the
/// ones 1.x used, so its working files stay where they were.
public struct SharedPaths: Sendable {
    public let container: URL

    public init(container: URL) {
        self.container = container
    }

    /// Libbox base path: the command socket is created here.
    public var base: URL { container }
    public var temp: URL { container.appendingPathComponent("Library/Caches", isDirectory: true) }
    public var working: URL { temp.appendingPathComponent("Working", isDirectory: true) }

    /// Everything 2.0 stores itself.
    public var data: URL { container.appendingPathComponent("PersonalTunnel", isDirectory: true) }
    public var library: URL { data.appendingPathComponent("library.json") }
    /// The configuration the tunnel runs; read when the system starts it on its own.
    public var activeConfig: URL { data.appendingPathComponent("tunnel.json") }
    /// The Xray-core configuration the tunnel runs beside sing-box; absent when
    /// the subscription has no server only Xray can run.
    public var activeXrayConfig: URL { data.appendingPathComponent("tunnel-xray.json") }
    /// Xray-core's warnings from the running tunnel.
    public var xrayLog: URL { working.appendingPathComponent("xray.log") }
    /// Where the core keeps what it wrote before it fell (one folder per crash).
    public var crashReports: URL { working.appendingPathComponent("crash_reports", isDirectory: true) }
    public var coreCrashLog: URL { working.appendingPathComponent("CrashReport-packet-tunnel.log") }
    public var networkActivity: URL { data.appendingPathComponent("network-activity.json") }

    /// 1.x storage, read once by the migration and left untouched.
    public var legacyDatabase: URL { container.appendingPathComponent("settings.db") }
    public var legacyConfigs: URL { container.appendingPathComponent("configs", isDirectory: true) }

    public func prepare() throws {
        for directory in [data, temp, working] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

/// Keys of the group defaults both processes read.
public enum SharedKey {
    /// Why the tunnel failed to start last time; cleared on a successful start.
    public static let lastTunnelError = "pt.tunnel.lastError"
    /// Time the tunnel last started, seconds since 1970.
    public static let tunnelStartedAt = "pt.tunnel.startedAt"
    /// The extension's last memory sample (`MemorySample`, JSON).
    public static let tunnelMemory = "pt.tunnel.memory"
}

/// Start options and messages the app sends to the packet tunnel.
public enum TunnelIPC {
    /// `startVPNTunnel(options:)` key carrying the configuration text.
    public static let configOption = "config"
    /// App message: read the stored configuration again and reload the service.
    public static let reloadMessage = "reload"
}
