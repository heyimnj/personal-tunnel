import Foundation

/// The journal of requests the app makes by itself (subscription refreshes,
/// connection checks, TCP pings). Kept on the device, at most 200 entries.
public enum NetworkActivityLog {
    public static let capacity = 200
    private static let lock = NSLock()

    public static func entries(_ defaults: UserDefaults = SharedContainer.defaults) -> [NetworkActivityEntry] {
        guard let data = defaults.data(forKey: SharedKey.networkActivity) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([NetworkActivityEntry].self, from: data)) ?? []
    }

    public static func record(_ entry: NetworkActivityEntry, defaults: UserDefaults = SharedContainer.defaults) {
        lock.lock()
        defer { lock.unlock() }
        var list = entries(defaults)
        list.insert(entry, at: 0)
        if list.count > capacity { list.removeLast(list.count - capacity) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(list) {
            defaults.set(data, forKey: SharedKey.networkActivity)
        }
    }

    public static func clear(_ defaults: UserDefaults = SharedContainer.defaults) {
        defaults.removeObject(forKey: SharedKey.networkActivity)
    }
}
