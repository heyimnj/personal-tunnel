import Foundation

/// A row of the 1.x `profiles` table plus the text of its configuration file.
public struct LegacyProfile: Sendable {
    public var id: Int64
    public var name: String
    public var order: Int
    public var remoteURL: String?
    public var lastUpdated: Date?
    public var config: String?
    public var disabled: Bool

    public init(id: Int64, name: String, order: Int, remoteURL: String?, lastUpdated: Date?, config: String?, disabled: Bool = false) {
        self.id = id; self.name = name; self.order = order; self.remoteURL = remoteURL
        self.lastUpdated = lastUpdated; self.config = config; self.disabled = disabled
    }
}

/// 1.x data → the 2.0 library. Profile ids and outbound tags are kept, so the
/// stored order, pins, favourites and recents still point at the same servers.
public enum LegacyMigration {
    public static func library(from profiles: [LegacyProfile], selectedProfileID: Int64?, preferredTag: String?) -> Library {
        var library = Library()
        for profile in profiles.sorted(by: { ($0.order, $0.id) < ($1.order, $1.id) }) {
            var nodes: [ServerNode] = []
            var warnings: [String] = []
            if let text = profile.config, let document = try? JSONValue.parse(text), SingBoxImport.isSingBox(document) {
                nodes = keepingTags(SingBoxImport.parse(document))
            } else {
                warnings.append(CoreText.t("Конфигурация 1.x не прочитана. Обновите подписку."))
            }
            let url = profile.remoteURL?.trimmingCharacters(in: .whitespaces)
            library.subscriptions.append(Subscription(id: profile.id, name: profile.name, url: url?.isEmpty == false ? url : nil, nodes: nodes,
                                                      updatedAt: profile.lastUpdated, warnings: warnings, isDisabled: profile.disabled))
        }
        library.nextID = (profiles.map(\.id).max() ?? 0) + 1
        if let selectedProfileID, library.subscription(selectedProfileID) != nil {
            library.activeSubscriptionID = selectedProfileID
            if let preferredTag, !preferredTag.isEmpty { library.selectedNodes[String(selectedProfileID)] = preferredTag }
        }
        return library
    }

    /// Like `NodeAssembler`, but the head keeps its original tag.
    static func keepingTags(_ parsed: [ParsedNode]) -> [ServerNode] {
        parsed.map { item in
            var main = item.outbound
            main["tag"] = .string(item.name)
            return ServerNode(id: item.name, name: item.name, outbound: main, members: item.members)
        }
    }

    /// BinaryCodable (1.x `preferences` blobs): a Bool is one byte.
    public static func decodeBool(_ data: Data?) -> Bool? {
        guard let byte = data?.first, data?.count == 1 else { return nil }
        return byte != 0
    }

    /// BinaryCodable Int64: zig-zag varint.
    public static func decodeInt(_ data: Data?) -> Int64? {
        guard let data, !data.isEmpty, data.count <= 10 else { return nil }
        var value: UInt64 = 0
        var shift: UInt64 = 0
        for byte in data {
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return Int64(bitPattern: (value >> 1) ^ (0 &- (value & 1))) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}
