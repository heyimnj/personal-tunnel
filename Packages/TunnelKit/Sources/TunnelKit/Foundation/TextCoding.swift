import Foundation

/// Lenient decoders for the text encodings subscription panels use.
public enum TextCoding {
    /// Decodes standard or URL-safe Base64 with or without padding and with
    /// embedded whitespace. Returns `nil` when the text is not Base64.
    public static func base64Data(_ input: String) -> Data? {
        var text = input.filter { !$0.isWhitespace }
        guard !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=") }) else {
            return nil
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let remainder = text.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { text += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: text)
    }

    /// Decodes Base64 into UTF-8 text.
    public static func base64String(_ input: String) -> String? {
        guard let data = base64Data(input) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func base64Encode(_ text: String, urlSafe: Bool = false, padded: Bool = true) -> String {
        var value = Data(text.utf8).base64EncodedString()
        if urlSafe {
            value = value.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        if !padded {
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        }
        return value
    }

    /// Percent-decodes, tolerating malformed sequences.
    public static func percentDecoded(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }

    /// Encodes a URL component (user info, fragment or query value).
    public static func percentEncoded(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// Parses `a=1&b=2` into a dictionary with lowercased keys. Later keys win.
    public static func query(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = percentDecoded(String(parts[0]).replacingOccurrences(of: "+", with: " ")).lowercased()
            guard !key.isEmpty else { continue }
            let value = parts.count > 1 ? percentDecoded(String(parts[1])) : ""
            result[key] = value
        }
        return result
    }

    /// Hex string to bytes.
    public static func hexBytes(_ text: String) -> [UInt8]? {
        let clean = text.filter { !$0.isWhitespace }
        guard clean.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var nonEmpty: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }
}

/// Splits `user@host:port` style authorities, including bracketed IPv6.
public struct Authority: Equatable {
    public var userInfo: String?
    public var host: String
    public var port: Int?

    public init(userInfo: String? = nil, host: String, port: Int?) {
        self.userInfo = userInfo
        self.host = host
        self.port = port
    }

    public static func parse(_ text: String) -> Authority? {
        var rest = Substring(text)
        var userInfo: String?
        if let at = rest.lastIndex(of: "@") {
            userInfo = String(rest[rest.startIndex ..< at])
            rest = rest[rest.index(after: at)...]
        }
        var host: String
        var port: Int?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = String(rest[rest.index(after: rest.startIndex) ..< close])
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") {
                port = Int(after.dropFirst())
                if port == nil, !after.dropFirst().isEmpty { return nil }
            }
        } else if let colon = rest.lastIndex(of: ":"), rest.filter({ $0 == ":" }).count == 1 {
            host = String(rest[rest.startIndex ..< colon])
            let portText = rest[rest.index(after: colon)...]
            port = Int(portText)
            if port == nil, !portText.isEmpty { return nil }
        } else {
            host = String(rest)
        }
        host = TextCoding.percentDecoded(host)
        guard !host.isEmpty else { return nil }
        if let port, !(1 ... 65535).contains(port) { return nil }
        return Authority(userInfo: userInfo, host: host, port: port)
    }

    /// `host:port` with IPv6 literals bracketed.
    public static func format(host: String, port: Int) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

/// A generic `scheme://userinfo@host:port/path?query#fragment` split that
/// tolerates the non-standard characters proxy share links contain.
public struct ShareURI {
    public var scheme: String
    public var authority: String
    public var path: String
    public var query: [String: String]
    public var rawQuery: String
    public var fragment: String

    public static func parse(_ link: String) -> ShareURI? {
        let text = link.trimmed
        guard let schemeEnd = text.range(of: "://") else { return nil }
        let scheme = text[text.startIndex ..< schemeEnd.lowerBound].lowercased()
        guard !scheme.isEmpty else { return nil }
        var rest = text[schemeEnd.upperBound...]
        var fragment = ""
        if let hash = rest.firstIndex(of: "#") {
            fragment = TextCoding.percentDecoded(String(rest[rest.index(after: hash)...]))
            rest = rest[rest.startIndex ..< hash]
        }
        var rawQuery = ""
        if let question = rest.firstIndex(of: "?") {
            rawQuery = String(rest[rest.index(after: question)...])
            rest = rest[rest.startIndex ..< question]
        }
        var path = ""
        // The authority ends at the first "/" after the last "@" (passwords may contain "/").
        let searchStart = rest.lastIndex(of: "@").map { rest.index(after: $0) } ?? rest.startIndex
        if let slash = rest[searchStart...].firstIndex(of: "/") {
            path = String(rest[slash...])
            rest = rest[rest.startIndex ..< slash]
        }
        return ShareURI(
            scheme: scheme,
            authority: String(rest),
            path: TextCoding.percentDecoded(path),
            query: TextCoding.query(rawQuery),
            rawQuery: rawQuery,
            fragment: fragment
        )
    }
}
