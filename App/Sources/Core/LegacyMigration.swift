import Foundation
import SQLite3
import TunnelKit

/// Brings the data of Personal Tunnel 1.x into 2.0 on first launch.
///
/// 1.x kept its profiles in `settings.db` (SQLite) with configurations in
/// `configs/`, and wrote an automatic backup to
/// `Documents/PersonalTunnelRecovery/latest.ptbackup`. The old files are left
/// untouched.
enum LegacyMigration {
    private static let doneKey = "migration.2_0.done"

    struct Result {
        var library: ServerLibrary
        var options: TunnelOptions?
        var preferences: [String: JSON]
        var fonts: [String: Data]
    }

    static func runIfNeeded() -> Result? {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return nil }
        defaults.set(true, forKey: doneKey)
        if let subscriptions = readDatabase(), !subscriptions.isEmpty {
            var library = ServerLibrary(subscriptions: subscriptions)
            library.repairSelection()
            return Result(library: library, options: nil, preferences: [:], fonts: [:])
        }
        let recovery = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PersonalTunnelRecovery", isDirectory: true)
            .appendingPathComponent("latest.ptbackup")
        if let data = try? Data(contentsOf: recovery), let archive = try? BackupArchive.read(data) {
            return Result(library: archive.library, options: archive.tunnelOptions, preferences: archive.preferences, fonts: archive.fonts)
        }
        return nil
    }

    private static func readDatabase() -> [Subscription]? {
        let databaseURL = SharedContainer.directory.appendingPathComponent("settings.db")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else {
            return nil
        }
        defer { sqlite3_close(database) }
        let sql = "SELECT name, type, path, remoteURL, autoUpdate, autoUpdateInterval FROM profiles ORDER BY \"order\""
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        var result: [Subscription] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let name = text(statement, 0) ?? "Profile"
            let type = Int(sqlite3_column_int(statement, 1))
            let path = text(statement, 2) ?? ""
            let remoteURL = type == 2 ? text(statement, 3) : nil
            let autoUpdate = sqlite3_column_int(statement, 4) != 0
            let interval = Int(sqlite3_column_int(statement, 5))
            guard let config = readConfig(path: path) else { continue }
            let subscription = LegacyImport.subscription(
                name: name,
                config: config,
                remoteURL: remoteURL,
                autoUpdate: autoUpdate,
                intervalMinutes: interval,
                disabled: false
            )
            if !subscription.servers.isEmpty || subscription.isRemote { result.append(subscription) }
        }
        return result
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private static func readConfig(path: String) -> String? {
        let original = URL(fileURLWithPath: path)
        let candidates = [
            original,
            SharedContainer.directory.appendingPathComponent("configs", isDirectory: true).appendingPathComponent(original.lastPathComponent),
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PersonalTunnelRecovery", isDirectory: true)
                .appendingPathComponent(original.lastPathComponent),
        ]
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty { return text }
        }
        return nil
    }
}
