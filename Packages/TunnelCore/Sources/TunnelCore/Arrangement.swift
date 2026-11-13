import Foundation

/// Order of subscriptions and servers in lists. Same JSON as 1.x
/// (`personal.serverArrangement`), so pins and manual order carry over.
public struct Arrangement: Codable, Equatable, Sendable {
    public static let defaultsKey = "personal.serverArrangement"
    public var pinned: [String] = []
    public var manual: [String] = []
    public var recent: [String] = []
    public var byName = false

    public init() {}

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
        byName = false
    }

    /// Pinned first (in pin order), then by name or by manual rank, then as given.
    public func sorted<T>(_ items: [T], key: (T) -> String, name: (T) -> String) -> [T] {
        let pins = Dictionary(pinned.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        let ranks = Dictionary(manual.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return items.enumerated().sorted { left, right in
            let a = key(left.element), b = key(right.element)
            let ap = pins[a] ?? Int.max, bp = pins[b] ?? Int.max
            if ap != bp { return ap < bp }
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
