import Foundation
import SQLite3
import TunnelCore

/// Read-only access to the 1.x `settings.db` (profiles and preferences).
enum LegacyDatabase {
    struct Snapshot {
        var profiles: [LegacyProfile] = []
        var preferences: [String: Data] = [:]
    }

    static func read(paths: SharedPaths) -> Snapshot? {
        guard FileManager.default.fileExists(atPath: paths.legacyDatabase.path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(paths.legacyDatabase.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(db) }
        var snapshot = Snapshot()
        let groupDefaults = AppGroup.defaults

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id, name, \"order\", path, remoteURL, lastUpdated FROM profiles", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                let name = text(statement, 1) ?? ""
                let order = Int(sqlite3_column_int64(statement, 2))
                let path = text(statement, 3) ?? ""
                let url = text(statement, 4)
                let updated = text(statement, 5).flatMap(date)
                snapshot.profiles.append(LegacyProfile(id: id, name: name, order: order, remoteURL: url, lastUpdated: updated,
                                                       config: config(path: path, paths: paths),
                                                       disabled: groupDefaults.bool(forKey: "profile.disabled.\(id)")))
            }
        }
        sqlite3_finalize(statement)

        statement = nil
        if sqlite3_prepare_v2(db, "SELECT name, data FROM preferences", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let name = text(statement, 0) else { continue }
                let count = Int(sqlite3_column_bytes(statement, 1))
                if let bytes = sqlite3_column_blob(statement, 1), count > 0 {
                    snapshot.preferences[name] = Data(bytes: bytes, count: count)
                }
            }
        }
        sqlite3_finalize(statement)
        return snapshot
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// 1.x stored absolute paths; the container may have moved since.
    private static func config(path: String, paths: SharedPaths) -> String? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let candidates = [paths.legacyConfigs.appendingPathComponent(name), URL(fileURLWithPath: path),
                          paths.legacyConfigs.appendingPathComponent(name + ".last-good")]
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8), text.count > 2 { return text }
        }
        return nil
    }
}
