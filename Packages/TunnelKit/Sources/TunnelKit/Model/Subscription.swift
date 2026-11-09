import Foundation

/// A group of servers. Remote subscriptions have a URL and are refreshed from
/// it; a subscription without a URL holds servers the user added by hand.
public struct Subscription: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// `true` once the user renamed the subscription: refreshes keep the name.
    public var hasCustomName: Bool
    public var url: String?
    public var servers: [Server]
    public var isEnabled: Bool
    /// Send HWID, device model and OS version with refresh requests.
    public var sendsDeviceInfo: Bool
    public var autoUpdate: Bool
    public var updateIntervalHours: Int
    public var lastUpdated: Date?
    public var lastError: String?
    public var info: SubscriptionInfo
    /// Servers the last refresh could not import, with reasons.
    public var skipped: [SkippedEntry]

    public init(
        id: UUID = UUID(),
        name: String,
        url: String? = nil,
        servers: [Server] = [],
        isEnabled: Bool = true,
        sendsDeviceInfo: Bool = true,
        autoUpdate: Bool = true,
        updateIntervalHours: Int = 12
    ) {
        self.id = id
        self.name = name
        hasCustomName = false
        self.url = url
        self.servers = servers
        self.isEnabled = isEnabled
        self.sendsDeviceInfo = sendsDeviceInfo
        self.autoUpdate = autoUpdate
        self.updateIntervalHours = updateIntervalHours
        lastUpdated = nil
        lastError = nil
        info = SubscriptionInfo()
        skipped = []
    }

    public var isRemote: Bool { url != nil }

    public func isDue(now: Date = Date()) -> Bool {
        guard isRemote, autoUpdate, isEnabled else { return false }
        guard let lastUpdated else { return true }
        let hours = max(1, info.updateIntervalHours ?? updateIntervalHours)
        return now.timeIntervalSince(lastUpdated) >= Double(hours) * 3600
    }

    /// Replaces the server list with a fresh import, keeping identities,
    /// favourites and the user's order hints of servers that are still there.
    ///
    /// A server keeps its `id` when its connection parameters are unchanged,
    /// or failing that when exactly one new server carries its old name.
    public mutating func replaceServers(with imported: [ImportedServer]) {
        var byFingerprint: [String: Server] = [:]
        var byName: [String: [Server]] = [:]
        for server in servers {
            byFingerprint[server.fingerprint] = server
            byName[server.name, default: []].append(server)
        }
        var used = Set<UUID>()
        var result: [Server] = []
        result.reserveCapacity(imported.count)
        for item in imported {
            var server = Server(imported: item)
            if let old = byFingerprint[server.fingerprint], !used.contains(old.id) {
                server.id = old.id
                server.isFavorite = old.isFavorite
            } else if let candidates = byName[item.name], candidates.count == 1, let old = candidates.first, !used.contains(old.id) {
                server.id = old.id
                server.isFavorite = old.isFavorite
            }
            used.insert(server.id)
            result.append(server)
        }
        servers = result
    }
}

/// Values a panel reports about a subscription.
public struct SubscriptionInfo: Codable, Hashable, Sendable {
    public var uploadBytes: Int64?
    public var downloadBytes: Int64?
    public var totalBytes: Int64?
    public var expiresAt: Date?
    public var supportURL: String?
    public var webPageURL: String?
    public var announce: String?
    public var updateIntervalHours: Int?
    public var deviceLimit: Int?
    public var devicesUsed: Int?
    public var deviceLimitReached: Bool

    public init() {
        deviceLimitReached = false
    }

    public var usedBytes: Int64? {
        guard uploadBytes != nil || downloadBytes != nil else { return nil }
        return (uploadBytes ?? 0) + (downloadBytes ?? 0)
    }

    /// `0...1`, or `nil` for unlimited or unknown quotas.
    public var usageFraction: Double? {
        guard let total = totalBytes, total > 0, let used = usedBytes else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }
}

/// A server line that was not imported.
public struct SkippedEntry: Codable, Hashable, Sendable {
    public var name: String
    public var reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }
}

/// Everything the user has added, persisted as one document.
public struct ServerLibrary: Codable, Hashable, Sendable {
    public static let currentFormat = 2

    public var format: Int
    public var subscriptions: [Subscription]
    public var selectedServerID: UUID?

    public init(subscriptions: [Subscription] = [], selectedServerID: UUID? = nil) {
        format = ServerLibrary.currentFormat
        self.subscriptions = subscriptions
        self.selectedServerID = selectedServerID
    }

    public var isEmpty: Bool { subscriptions.allSatisfy(\.servers.isEmpty) && subscriptions.allSatisfy { !$0.isRemote } }

    public var allServers: [Server] { subscriptions.flatMap(\.servers) }

    public func server(id: UUID?) -> Server? {
        guard let id else { return nil }
        for subscription in subscriptions {
            if let server = subscription.servers.first(where: { $0.id == id }) { return server }
        }
        return nil
    }

    public func subscription(containing serverID: UUID?) -> Subscription? {
        guard let serverID else { return nil }
        return subscriptions.first { $0.servers.contains { $0.id == serverID } }
    }

    public func subscriptionIndex(id: UUID) -> Int? {
        subscriptions.firstIndex { $0.id == id }
    }

    public var selectedServer: Server? { server(id: selectedServerID) }

    /// The selected server, or the first server of the first enabled
    /// subscription when nothing usable is selected.
    public var effectiveSelection: Server? {
        if let selected = server(id: selectedServerID),
           subscription(containing: selected.id)?.isEnabled == true
        {
            return selected
        }
        return subscriptions.first { $0.isEnabled && !$0.servers.isEmpty }?.servers.first
    }

    /// Keeps the selection valid after edits.
    public mutating func repairSelection() {
        if effectiveSelection?.id != selectedServerID {
            selectedServerID = effectiveSelection?.id
        }
    }

    /// The manual group servers added by hand go to, created on demand.
    public mutating func manualSubscriptionIndex(named name: String) -> Int {
        if let index = subscriptions.firstIndex(where: { !$0.isRemote }) { return index }
        subscriptions.insert(Subscription(name: name, autoUpdate: false), at: 0)
        return 0
    }

    public mutating func removeServer(id: UUID) {
        for index in subscriptions.indices {
            subscriptions[index].servers.removeAll { $0.id == id }
        }
        repairSelection()
    }

    public mutating func updateServer(_ server: Server) {
        for index in subscriptions.indices {
            if let serverIndex = subscriptions[index].servers.firstIndex(where: { $0.id == server.id }) {
                subscriptions[index].servers[serverIndex] = server
                return
            }
        }
    }
}
