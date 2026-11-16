import Foundation

/// Order of subscriptions and servers in lists. Same JSON as 1.x
/// (`personal.serverArrangement`), so pins and manual order carry over.
public struct Arrangement: Codable, Equatable, Sendable {
    public static let defaultsKey = "personal.serverArrangement"
    public var pinned: [String] = []
    public var manual: [String] = []
    public var recent: [String] = []
    public var byName = false
    /// 3.3 beta 3: subscriptions the VPN connected to, the latest first. A
    /// connected subscription rises to the top (under the pinned ones) and stays
    /// there after disconnecting, until another one is connected or the order is
    /// set by hand. Not in 1.x's JSON: missing means none.
    public var raised: [String] = []

    public init() {}

    private enum CodingKeys: String, CodingKey { case pinned, manual, recent, byName, raised }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pinned = try container.decodeIfPresent([String].self, forKey: .pinned) ?? []
        manual = try container.decodeIfPresent([String].self, forKey: .manual) ?? []
        recent = try container.decodeIfPresent([String].self, forKey: .recent) ?? []
        byName = try container.decodeIfPresent(Bool.self, forKey: .byName) ?? false
        raised = try container.decodeIfPresent([String].self, forKey: .raised) ?? []
    }

    /// The VPN connected to this subscription: it goes to the top of the raised ones.
    public mutating func raise(_ key: String) {
        raised.removeAll { $0 == key }
        raised.insert(key, at: 0)
        raised = Array(raised.prefix(100))
    }

    public static func subscription(_ id: Int64) -> String { "subscription:\(id)" }
    public static func server(_ id: Int64, _ tag: String) -> String { "server:\(id):\(tag)" }

    public static func decode(_ text: String?) -> Arrangement {
        guard let text, let value = try? JSONDecoder().decode(Arrangement.self, from: Data(text.utf8)) else { return Arrangement() }
        return value
    }

    public var encoded: String { String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "" }

    public func isPinned(_ key: String) -> Bool { pinned.contains(key) }

    public mutating func togglePin(_ key: String) {
        if pinned.contains(key) { pinned.removeAll { $0 == key } } else { pinned.append(key) }
    }

    public mutating func remember(_ key: String) {
        recent.removeAll { $0 == key }
        recent.insert(key, at: 0)
        recent = Array(recent.prefix(100))
    }

    /// Dragging switches to manual order.
    public mutating func setManualOrder(_ keys: [String], replacing old: [String]) {
        let dropped = Set(old)
        manual = manual.filter { !dropped.contains($0) } + keys
        // The order set by hand wins over the order of connecting.
        raised.removeAll { dropped.contains($0) }
        byName = false
    }

    /// Pinned first (in pin order); then `lifted` (3.3 beta 3: the server the VPN
    /// is connected to, only while it is); then the raised subscriptions (latest
    /// connection first); then by name or by manual rank; then as given.
    public func sorted<T>(_ items: [T], key: (T) -> String, name: (T) -> String, lifted: String? = nil) -> [T] {
        let pins = Dictionary(pinned.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        let ranks = Dictionary(manual.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        let rises = Dictionary(raised.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return items.enumerated().sorted { left, right in
            let a = key(left.element), b = key(right.element)
            let ap = pins[a] ?? Int.max, bp = pins[b] ?? Int.max
            if ap != bp { return ap < bp }
            if let lifted, (a == lifted) != (b == lifted) { return a == lifted }
            let ar0 = rises[a] ?? Int.max, br0 = rises[b] ?? Int.max
            if ar0 != br0 { return ar0 < br0 }
            if byName {
                let order = name(left.element).localizedStandardCompare(name(right.element))
                if order != .orderedSame { return order == .orderedAscending }
            } else {
                let ar = ranks[a] ?? Int.max, br = ranks[b] ?? Int.max
                if ar != br { return ar < br }
            }
            return left.offset < right.offset
        }.map(\.element)
    }
}
