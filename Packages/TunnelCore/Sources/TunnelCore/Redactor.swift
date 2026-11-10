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
