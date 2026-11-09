import Foundation

/// Hides secrets in text shown on screen or copied out of the app: share
/// links, subscription tokens, UUIDs, passwords, keys and long identifiers.
public enum Redactor {
    private static let rules: [(NSRegularExpression, String)] = {
        let patterns: [(String, String)] = [
            // Whole share links.
            (#"(?i)\b(vless|vmess|trojan|ss|ssr|hysteria2?|hy2|tuic|wireguard|wg|naive\+https|naive\+quic|socks5?|anytls)://[^\s"'<>]+"#, "$1://•••"),
            // Secret JSON fields.
            (#"(?i)"(uuid|password|private_key|pre_shared_key|public_key|short_id|auth_str|obfs_password|username|id|secretKey|publicKey|shortId)"\s*:\s*"[^"]*""#, "\"$1\":\"•••\""),
            // key=value secrets in queries and logs.
            (#"(?i)\b(pbk|sid|password|passwd|pass|token|key|secret|auth|uuid|hwid|obfs-password)=([^&\s"']+)"#, "$1=•••"),
            // URL paths and queries after the host.
            (#"(?i)(https?://[^/\s"']+)/[^\s"'<>]*"#, "$1/•••"),
            // UUIDs.
            (#"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#, "••••-uuid"),
            // Long hex or Base64 identifiers (HWID, keys, tokens).
            (#"\b[A-Za-z0-9+/_\-]{24,}={0,2}"#, "•••"),
        ]
        return patterns.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()

    public static func redact(_ text: String) -> String {
        var result = text
        for (expression, template) in rules {
            let range = NSRange(result.startIndex ..< result.endIndex, in: result)
            result = expression.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    /// Masks a header value, keeping a short prefix so values stay distinguishable.
    public static func mask(_ value: String) -> String {
        guard value.count > 6 else { return "•••" }
        return String(value.prefix(3)) + "•••"
    }

    /// Keeps the first path component of a URL path, masks the rest
    /// (subscription tokens usually live in the path).
    public static func redactPath(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = components.first else { return path.isEmpty ? "" : "/" }
        if components.count == 1 {
            return first.count > 12 ? "/•••" : "/\(first)"
        }
        return "/\(first)/•••"
    }
}
