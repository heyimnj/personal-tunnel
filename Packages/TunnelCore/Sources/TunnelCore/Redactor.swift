import Foundation

/// Removes secrets from text that leaves the app: logs, copied reports, errors.
public enum Redactor {
    private static let rules: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            // Share links: keep the scheme, drop everything after it.
            (#"(?i)\b(vless|vmess|trojan|ss|ssr|hysteria2?|hy2|tuic|wireguard|wg|awg|socks5?|anytls|naive\+https|naive\+quic)://[^\s"']+"#, "$1://***"),
            // Subscription addresses carry a token in the path or the query.
            (#"(?i)\bhttps?://[^\s"'/]+/[^\s"']+"#, "https://***"),
            (#"(?i)\b(uuid|password|passwd|pass|token|auth|auth_str|authorization|private[_-]?key|public[_-]?key|pre[_-]?shared[_-]?key|psk|hwid|short[_-]?id|secret)("?\s*[:=]\s*"?)[^"'&\s,}]+"#, "$1$2***"),
            (#"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#, "********-****-****-****-************"),
        ]
        return patterns.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()

    public static func redact(_ text: String) -> String {
        var result = text
        for (expression, template) in rules {
            result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }
}

public extension Redactor {
    private static let ipAddress = try! NSRegularExpression(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b|\b[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{0,4}){2,7}\b"#)

    /// Every IP address in the text becomes `<адрес>`. For lines about the user's
    /// own servers (a failed probe names the address it dialled), where a
    /// server's name may be missing and only its address shows.
    static func hideAddresses(_ text: String) -> String {
        ipAddress.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "<адрес>")
    }

    /// Hides the user's own servers in a text that leaves the app: their names
    /// become `<сервер>`, and a line that named one loses its IP addresses too
    /// (the core logs what a server's name resolved to).
    static func hideServers(_ text: String, hosts: Set<String>) -> String {
        let names = hosts.filter { $0.count > 3 }.sorted { $0.count > $1.count }
        guard !names.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var line = String(line)
            var named = false
            for name in names where line.range(of: name, options: .caseInsensitive) != nil {
                line = line.replacingOccurrences(of: name, with: "<сервер>", options: .caseInsensitive)
                named = true
            }
            if named {
                line = ipAddress.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "<адрес>")
            }
            return line
        }.joined(separator: "\n")
    }
}
