import Foundation

/// One server of a subscription: a sing-box outbound (or WireGuard endpoint)
/// plus the supporting outbounds it needs.
public struct ServerNode: Codable, Hashable, Identifiable, Sendable {
    /// The outbound tag. Unique inside its subscription; never shown translated.
    public var id: String
    /// The name exactly as the provider or the user gave it.
    public var name: String
    /// The outbound, endpoint or group that carries the traffic. Its `tag` equals `id`.
    public var outbound: JSONValue
    /// Outbounds the main one refers to: members of a provider group, detours.
    public var members: [JSONValue]
    /// The share link the node came from, when it came from one.
    public var link: String?
    /// The server's outbounds as the provider's Xray JSON wrote them (3.1.2): what
    /// its page shows without secrets, to see what the conversion made of it.
    public var source: JSONValue?

    public init(id: String, name: String, outbound: JSONValue, members: [JSONValue] = [], link: String? = nil, source: JSONValue? = nil) {
        self.id = id
        self.name = name
        self.outbound = outbound
        self.members = members
        self.link = link
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case id, name, outbound, members, link, source }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        outbound = try container.decode(JSONValue.self, forKey: .outbound)
        members = try container.decodeIfPresent([JSONValue].self, forKey: .members) ?? []
        link = try container.decodeIfPresent(String.self, forKey: .link)
        source = try container.decodeIfPresent(JSONValue.self, forKey: .source)
    }
}

public extension ServerNode {
    /// sing-box type of the main object: `vless`, `hysteria2`, `urltest`...
    var type: String { outbound["type"]?.stringValue?.lowercased() ?? "" }

    /// Provider-made group (Xray balancer, sing-box urltest) shown as one server.
    var isGroup: Bool { type == "urltest" || type == "selector" }

    /// WireGuard-family objects live under `endpoints` in sing-box 1.11+.
    var isEndpoint: Bool { ServerNode.endpointTypes.contains(type) }

    static let endpointTypes: Set<String> = ["wireguard", "awg", "amneziawg"]

    /// The object a direct probe should reach: the node itself or, for a group, its
    /// first server, looked up through nested groups as 1.5.0 did (1.x locations are
    /// groups of groups).
    var probeObject: JSONValue {
        guard isGroup else { return outbound }
        func grouped(_ object: JSONValue) -> Bool {
            let type = object["type"]?.stringValue?.lowercased() ?? ""
            return type == "urltest" || type == "selector"
        }
        func leaf(in group: JSONValue, depth: Int) -> JSONValue? {
            guard depth < 6 else { return nil }
            for tag in group["outbounds"]?.stringList ?? [] {
                guard let member = members.first(where: { $0["tag"]?.stringValue == tag }) else { continue }
                if !grouped(member) { return member }
                if let found = leaf(in: member, depth: depth + 1) { return found }
            }
            return nil
        }
        return leaf(in: outbound, depth: 0) ?? members.first { !grouped($0) } ?? outbound
    }

    /// Address a TCP probe connects to, if the node has one.
    var address: (host: String, port: Int)? {
        let object = probeObject
        if let host = object["server"]?.stringValue, !host.isEmpty {
            if let port = object["server_port"]?.looseInt, port > 0 { return (host, port) }
            if let first = object["server_ports"]?.stringList.first {
                let head = first.split(whereSeparator: { $0 == ":" || $0 == "-" }).first.map(String.init) ?? first
                if let port = Int(head), port > 0 { return (host, port) }
            }
        }
        if let peer = object["peers"]?.arrayValue?.first, let host = peer["address"]?.stringValue, !host.isEmpty,
           let port = peer["port"]?.looseInt, port > 0
        {
            return (host, port)
        }
        return nil
    }

    /// QUIC and UDP protocols: a TCP connect says nothing about them.
    var isUDPBased: Bool {
        let object = probeObject
        let type = object["type"]?.stringValue?.lowercased() ?? ""
        switch type {
        case "hysteria", "hysteria2", "tuic", "wireguard", "awg", "amneziawg", "masque": return true
        case "naive": return object["quic"]?.boolValue ?? false
        default: return object.at("transport", "type")?.stringValue?.lowercased() == "quic"
        }
    }

    /// The name a direct probe puts in its TLS ClientHello: the server's SNI, or for
    /// REALITY the site it borrows. Without VPN a bare TCP connect proves nothing
    /// where the network answers handshakes itself or drops them; a TLS handshake
    /// with this name cannot be faked by the network and gives a real round trip.
    var tlsServerName: String? {
        let object = probeObject
        guard !isUDPBased, object.at("tls", "enabled")?.looseBool == true else { return nil }
        if let name = object.at("tls", "server_name")?.stringValue, !name.isEmpty { return name }
        // TLS without a name: the server's own host, when it is a name and not an address.
        guard let host = object["server"]?.stringValue, host.contains(where: \.isLetter), !host.contains(":") else { return nil }
        return host
    }
}

/// What the provider reports about the subscription itself.
public struct SubscriptionInfo: Codable, Hashable, Sendable {
    public var expiresAt: Date?
    public var uploadBytes: Int64?
    public var downloadBytes: Int64?
    public var totalBytes: Int64?
    public var deviceLimit: Int?
    public var devicesUsed: Int?
    public var supportURL: String?
    public var webPageURL: String?
    public var updateIntervalHours: Int?
    public var announcement: String?

    public init() {}

    public var usedBytes: Int64? {
        guard uploadBytes != nil || downloadBytes != nil else { return nil }
        return (uploadBytes ?? 0) + (downloadBytes ?? 0)
    }

    /// A subscription with a traffic cap. Zero or absent totals mean unlimited.
    public var isLimited: Bool { (totalBytes ?? 0) > 0 }
}

public struct Subscription: Codable, Hashable, Identifiable, Sendable {
    public var id: Int64
    public var name: String
    /// Remote subscription address; `nil` for servers added by link, file or QR.
    public var url: String?
    public var nodes: [ServerNode]
    public var updatedAt: Date?
    public var info: SubscriptionInfo
    public var warnings: [String]
    public var isDisabled: Bool
    /// Device headers (HWID, OS, model) are sent when refreshing.
    public var sendsDeviceIdentity: Bool

    public init(id: Int64, name: String, url: String? = nil, nodes: [ServerNode] = [], updatedAt: Date? = nil,
                info: SubscriptionInfo = SubscriptionInfo(), warnings: [String] = [], isDisabled: Bool = false,
                sendsDeviceIdentity: Bool = true)
    {
        self.id = id
        self.name = name
        self.url = url
        self.nodes = nodes
        self.updatedAt = updatedAt
        self.info = info
        self.warnings = warnings
        self.isDisabled = isDisabled
        self.sendsDeviceIdentity = sendsDeviceIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, url, nodes, updatedAt, info, warnings, isDisabled, sendsDeviceIdentity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url)
        nodes = try container.decodeIfPresent([ServerNode].self, forKey: .nodes) ?? []
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        info = try container.decodeIfPresent(SubscriptionInfo.self, forKey: .info) ?? SubscriptionInfo()
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        isDisabled = try container.decodeIfPresent(Bool.self, forKey: .isDisabled) ?? false
        sendsDeviceIdentity = try container.decodeIfPresent(Bool.self, forKey: .sendsDeviceIdentity) ?? true
    }

    /// 3.1.4: only an http(s) address can be fetched again; a subscription kept
    /// with anything else (an app link, say) is not refreshed and raises no error.
    public var isRemote: Bool {
        let text = (url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.hasPrefix("https://") || text.hasPrefix("http://")
    }

    /// A one-server entry is listed as that server, not as a folder.
    public var isStandalone: Bool { nodes.count == 1 }

    public func node(_ id: String) -> ServerNode? { nodes.first { $0.id == id } }
}

/// Everything the user has added, with the current choice.
public struct Library: Codable, Hashable, Sendable {
    public var version: Int
    public var subscriptions: [Subscription]
    /// The subscription whose configuration the tunnel runs.
    public var activeSubscriptionID: Int64?
    /// Chosen server per subscription.
    public var selectedNodes: [String: String]
    public var nextID: Int64

    public init(subscriptions: [Subscription] = [], activeSubscriptionID: Int64? = nil,
                selectedNodes: [String: String] = [:], nextID: Int64 = 1)
    {
        version = 2
        self.subscriptions = subscriptions
        self.activeSubscriptionID = activeSubscriptionID
        self.selectedNodes = selectedNodes
        self.nextID = nextID
    }

    private enum CodingKeys: String, CodingKey { case version, subscriptions, activeSubscriptionID, selectedNodes, nextID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 2
        subscriptions = try container.decodeIfPresent([Subscription].self, forKey: .subscriptions) ?? []
        activeSubscriptionID = try container.decodeIfPresent(Int64.self, forKey: .activeSubscriptionID)
        selectedNodes = try container.decodeIfPresent([String: String].self, forKey: .selectedNodes) ?? [:]
        let stored = try container.decodeIfPresent(Int64.self, forKey: .nextID) ?? 1
        nextID = max(stored, (subscriptions.map(\.id).max() ?? 0) + 1)
    }

    public func subscription(_ id: Int64?) -> Subscription? {
        guard let id else { return nil }
        return subscriptions.first { $0.id == id }
    }

    /// The chosen subscription, or the first usable one. A subscription without
    /// servers is never active: 1.x left empty placeholders behind.
    public var activeSubscription: Subscription? {
        subscription(activeSubscriptionID).flatMap { $0.nodes.isEmpty ? nil : $0 } ?? subscriptions.first { !$0.isDisabled && !$0.nodes.isEmpty }
    }

    public func selectedNodeID(in subscription: Subscription) -> String? {
        if let stored = selectedNodes[String(subscription.id)], subscription.node(stored) != nil { return stored }
        return subscription.nodes.first?.id
    }

    public var activeNode: ServerNode? {
        guard let subscription = activeSubscription, let id = selectedNodeID(in: subscription) else { return nil }
        return subscription.node(id)
    }

    public mutating func allocateID() -> Int64 {
        let id = max(nextID, (subscriptions.map(\.id).max() ?? 0) + 1)
        nextID = id + 1
        return id
    }

    public mutating func select(node: String, in subscription: Int64) {
        activeSubscriptionID = subscription
        selectedNodes[String(subscription)] = node
    }

    public mutating func replace(_ subscription: Subscription) {
        if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
            subscriptions[index] = subscription
        } else {
            subscriptions.append(subscription)
        }
    }

    public mutating func remove(subscription id: Int64) {
        subscriptions.removeAll { $0.id == id }
        selectedNodes[String(id)] = nil
        if activeSubscriptionID == id { activeSubscriptionID = nil }
    }
}

/// Makes outbound tags that cannot collide with each other or with the tags the
/// configuration reserves for itself.
public struct TagAllocator {
    public static let reserved: Set<String> = [
        "proxy", "auto", "direct", "block", "dns-out", "dns-remote", "dns-local", "tun-in", "any",
    ]

    private var used: Set<String>

    public init(used: Set<String> = []) {
        self.used = used.union(TagAllocator.reserved)
    }

    public mutating func make(_ wanted: String) -> String {
        let base = wanted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Сервер" : wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        if used.insert(base).inserted { return base }
        var index = 2
        while true {
            let candidate = "\(base) (\(index))"
            if used.insert(candidate).inserted { return candidate }
            index += 1
        }
    }
}
