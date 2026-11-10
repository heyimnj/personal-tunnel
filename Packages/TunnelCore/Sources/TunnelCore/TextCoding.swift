import Foundation

public enum TextCoding {
    /// Base64 in any of the forms subscriptions use: standard or URL-safe,
    /// padded or not, with line breaks.
    public static func decodeBase64(_ text: String) -> Data? {
        var cleaned = ""
        cleaned.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "-": cleaned.unicodeScalars.append("+")
            case "_": cleaned.unicodeScalars.append("/")
            case " ", "\n", "\r", "\t": continue
            default: cleaned.unicodeScalars.append(scalar)
            }
        }
        while cleaned.hasSuffix("=") { cleaned.removeLast() }
        guard !cleaned.isEmpty, cleaned.utf8.allSatisfy({ isBase64Byte($0) }) else { return nil }
        let remainder = cleaned.utf8.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { cleaned += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: cleaned)
    }

    public static func decodeBase64String(_ text: String) -> String? {
        guard let data = decodeBase64(text) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func isBase64Byte(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
            || byte == 0x2B || byte == 0x2F
    }

    /// Percent-decoding that leaves malformed sequences alone instead of failing.
    public static func percentDecode(_ text: String, plusIsSpace: Bool = false) -> String {
        guard text.contains("%") || (plusIsSpace && text.contains("+")) else { return text }
        var bytes: [UInt8] = []
        let source = Array(text.utf8)
        var index = 0
        while index < source.count {
            let byte = source[index]
            if byte == 0x25, index + 2 < source.count, let high = hexValue(source[index + 1]), let low = hexValue(source[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
            } else if plusIsSpace, byte == 0x2B {
                bytes.append(0x20)
                index += 1
            } else {
                bytes.append(byte)
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30 ... 0x39: return byte - 0x30
        case 0x41 ... 0x46: return byte - 0x41 + 10
        case 0x61 ... 0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func percentEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    public static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return host.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF:.%").contains($0) } }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard let value = Int(part) else { return false }
            return value >= 0 && value <= 255 && !part.isEmpty
        }
    }
}

/// A share link taken apart without `URLComponents`, which rejects many links
/// that clients accept (raw Unicode names, base64 with `/`, spaces).
public struct LinkParts: Equatable {
    public var scheme: String
    /// Text before `@`, still percent-encoded.
    public var userInfo: String?
    public var host: String
    public var port: Int?
    /// Everything between the scheme and the query when it has no `host:port` shape.
    public var authority: String
    public var path: String
    public var query: [String: String]
    public var fragment: String

    public init?(_ link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = trimmed.range(of: "://") else { return nil }
        scheme = trimmed[..<schemeEnd.lowerBound].lowercased()
        guard !scheme.isEmpty, scheme.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0) }) else {
            return nil
        }
        var rest = String(trimmed[schemeEnd.upperBound...])
        if let hash = rest.firstIndex(of: "#") {
            fragment = TextCoding.percentDecode(String(rest[rest.index(after: hash)...])).trimmingCharacters(in: .whitespacesAndNewlines)
            rest = String(rest[..<hash])
        } else {
            fragment = ""
        }
        var items: [String: String] = [:]
        if let mark = rest.firstIndex(of: "?") {
            let queryText = rest[rest.index(after: mark)...]
            for pair in queryText.split(separator: "&") {
                let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = TextCoding.percentDecode(String(pieces[0]), plusIsSpace: true)
                let value = pieces.count > 1 ? TextCoding.percentDecode(String(pieces[1]), plusIsSpace: false) : ""
                if !key.isEmpty, items[key] == nil { items[key] = value }
            }
            rest = String(rest[..<mark])
        }
        query = items
        // Credentials may contain "/" (standard base64), so the path starts after the last "@".
        let hostStart = rest.lastIndex(of: "@").map { rest.index(after: $0) } ?? rest.startIndex
        if let slash = rest[hostStart...].firstIndex(of: "/") {
            path = String(rest[slash...])
            rest = String(rest[..<slash])
        } else {
            path = ""
        }
        authority = rest
        var hostPort = rest
        if let at = rest.lastIndex(of: "@") {
            userInfo = String(rest[..<at])
            hostPort = String(rest[rest.index(after: at)...])
        } else {
            userInfo = nil
        }
        if hostPort.hasPrefix("["), let close = hostPort.firstIndex(of: "]") {
            host = String(hostPort[hostPort.index(after: hostPort.startIndex) ..< close])
            let tail = hostPort[hostPort.index(after: close)...]
            port = tail.hasPrefix(":") ? Int(tail.dropFirst().prefix { $0.isNumber }) : nil
        } else if let colon = hostPort.lastIndex(of: ":"), hostPort.filter({ $0 == ":" }).count == 1 {
            host = String(hostPort[..<colon])
            port = Int(hostPort[hostPort.index(after: colon)...].prefix { $0.isNumber })
        } else {
            host = hostPort
            port = nil
        }
    }

    /// First present, non-empty query value among the given spellings.
    public func value(_ keys: String...) -> String? {
        for key in keys {
            if let value = query[key], !value.isEmpty { return value }
            if let match = query.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame && !$0.value.isEmpty }) {
                return match.value
            }
        }
        return nil
    }

    public func flag(_ keys: String...) -> Bool {
        for key in keys {
            if let value = query[key]?.lowercased(), value == "1" || value == "true" || value == "yes" { return true }
        }
        return false
    }
}
