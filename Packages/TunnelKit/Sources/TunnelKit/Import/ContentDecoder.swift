import Foundation

public enum ContentFormat: String, Codable, Sendable {
    case shareLinks
    case base64Links
    case singBox
    case xray
    case clash
    case wireGuard

    public var title: String {
        switch self {
        case .shareLinks: return "Ссылки"
        case .base64Links: return "Base64-список"
        case .singBox: return "sing-box JSON"
        case .xray: return "Xray JSON"
        case .clash: return "Clash YAML"
        case .wireGuard: return "WireGuard"
        }
    }
}

/// The servers found in a subscription body, a pasted text or a file.
public struct DecodedContent: Sendable {
    public var format: ContentFormat
    public var servers: [ImportedServer]
    public var skipped: [SkippedEntry]
    /// `#key: value` lines some panels put into the body (Happ style).
    public var bodyMetadata: [String: String]
}

public enum ContentDecoder {
    public static func decode(_ input: String) throws -> DecodedContent {
        try decode(input, depth: 0)
    }

    private static func decode(_ input: String, depth: Int) throws -> DecodedContent {
        let text = input.trimmed
        guard !text.isEmpty else { throw ImportError.empty }

        if text.contains("[Interface]"), text.lowercased().contains("privatekey") {
            let config = try WireGuardConfig.parseConf(text)
            let server = ImportedServer(name: config.peers.first?.host ?? "WireGuard", outbound: try config.endpoint())
            return DecodedContent(format: .wireGuard, servers: [server], skipped: [], bodyMetadata: [:])
        }

        if text.hasPrefix("{") || text.hasPrefix("[") {
            let json: JSON
            do {
                json = try JSON.parse(text)
            } catch {
                throw ImportError.invalidJSON(String(describing: error))
            }
            if XrayImporter.looksLikeXray(json) {
                let (servers, skipped) = XrayImporter.importServers(json)
                return try finish(.xray, servers, skipped, [:])
            }
            if SingBoxImporter.looksLikeSingBox(json) {
                let (servers, skipped) = SingBoxImporter.importServers(json)
                return try finish(.singBox, servers, skipped, [:])
            }
            // A single sing-box outbound object.
            if json["type"] != nil, json["server"] != nil || json["peers"] != nil {
                let wrapped: JSON = ["outbounds": [json]]
                let (servers, skipped) = SingBoxImporter.importServers(wrapped)
                return try finish(.singBox, servers, skipped, [:])
            }
            throw ImportError.unrecognizedFormat
        }

        if ClashImporter.looksLikeClash(text) {
            let (servers, skipped) = try ClashImporter.importServers(text)
            return try finish(.clash, servers, skipped, [:])
        }

        let lines = text.components(separatedBy: .newlines).map(\.trimmed).filter { !$0.isEmpty }
        if lines.contains(where: ShareLinkParser.looksLikeLink) {
            var servers: [ImportedServer] = []
            var skipped: [SkippedEntry] = []
            var metadata: [String: String] = [:]
            for line in lines {
                if line.hasPrefix("#") || line.hasPrefix("//") {
                    if let (key, value) = metadataLine(line) { metadata[key] = value }
                    continue
                }
                guard ShareLinkParser.looksLikeLink(line) else { continue }
                do {
                    servers.append(try ShareLinkParser.parse(line))
                } catch {
                    skipped.append(SkippedEntry(name: linkName(line), reason: String(describing: error)))
                }
            }
            return try finish(depth > 0 ? .base64Links : .shareLinks, servers, skipped, metadata)
        }

        if depth == 0, let decoded = TextCoding.base64String(text) {
            var result = try decode(decoded, depth: 1)
            if result.format == .shareLinks { result.format = .base64Links }
            return result
        }
        throw ImportError.unrecognizedFormat
    }

    private static func finish(_ format: ContentFormat, _ servers: [ImportedServer], _ skipped: [SkippedEntry], _ metadata: [String: String]) throws -> DecodedContent {
        if servers.isEmpty, skipped.isEmpty { throw ImportError.empty }
        return DecodedContent(format: format, servers: servers, skipped: skipped, bodyMetadata: metadata)
    }

    /// `#profile-title: base64:...` → ("profile-title", "base64:...").
    static func metadataLine(_ line: String) -> (String, String)? {
        let body = line.drop { $0 == "#" || $0 == "/" }.trimmingCharacters(in: .whitespaces)
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let key = body[body.startIndex ..< colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(" "), !value.isEmpty else { return nil }
        return (key, value)
    }

    static func linkName(_ link: String) -> String {
        if let hash = link.firstIndex(of: "#") {
            let fragment = TextCoding.percentDecoded(String(link[link.index(after: hash)...])).trimmed
            if !fragment.isEmpty { return fragment }
        }
        return String(link.prefix { $0 != ":" }).uppercased()
    }
}
