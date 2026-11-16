import Foundation

/// Removes secrets from text that leaves the app: logs, copied reports, errors.
public enum Redactor {
    /// 3.3 (PT-16): every share-link scheme the app reads or recognises, so a new
    /// one cannot be forgotten here, and a few more that clients use.
    static var linkSchemes: [String] {
        let known = ShareLink.schemes.union(ShareLink.rejected.keys)
            .union(["vmess", "ssr", "hysteria", "hy2", "tuic", "juicity", "mieru", "shadowtls", "naive", "sudoku", "xhttp", "brook", "snell"])
        return known.sorted { $0.count > $1.count }
    }

    private static let rules: [(NSRegularExpression, String)] = {
        let schemes = linkSchemes.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let fields = "uuid|password|passwd|pass|token|auth|auth_str|authorization|private[_-]?key|public[_-]?key|pre[_-]?shared[_-]?key|psk|hwid|short[_-]?id|secret|username|user|pbk|sid|obfs[_-]?password|id"
        let patterns: [(String, String)] = [
            // Share links: keep the scheme, drop everything after it.
            ("(?i)(?<![A-Za-z0-9+.-])(\(schemes))://[^\\s\"']+", "$1://***"),
            // Subscription addresses carry a token in the path or the query.
            (#"(?i)\bhttps?://[^\s"'/?#]+[/?#][^\s"']+"#, "https://***"),
            // A bearer token, whatever header carries it.
            (#"(?i)\bBearer\s+[^\s"',}]+"#, "Bearer ***"),
            // Secret fields, in JSON (also escaped inside a string), in queries and in `key: value`.
            ("(?i)(?<![A-Za-z0-9])(\(fields))(\\\\?\"?\\s*[:=]\\s*\\\\?\"?)[^\"'&\\s,}\\\\]+", "$1$2***"),
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

    /// 3.3 (PT-16): text that leaves the app — a copied log, a report, a crash
    /// report. Secrets go (`redact`), the user's servers go (`hideServers`), the
    /// destinations of connections become `<назначение>`, and every IP address but
    /// the tunnel's own becomes `<адрес>`.
    public static func forSharing(_ text: String, hosts: Set<String>) -> String {
        hideAddresses(hideDestinations(hideServers(redact(text), hosts: hosts)), keeping: tunnelAddresses)
    }

    /// The tunnel's own addresses (`ConfigBuilder`'s TUN): they say nothing about anyone.
    public static let tunnelAddresses: Set<String> = ["172.19.0.1", "172.19.0.2", "fdfe:dcba:9876::1", "fdfe:dcba:9876::2"]

    private static let destinations: [(NSRegularExpression, String)] = [
        // sing-box: «inbound connection to www.example.com:443», «outbound packet connection to 1.2.3.4:53».
        (try! NSRegularExpression(pattern: #"(?i)(connection to )(\[[0-9a-f:.]+\]|[^\s\[\]]+?)(:\d+)?(?=$|[\s,;)])"#), "$1<назначение>"),
        // Xray-core: «tunneling request to tcp:www.example.com:443», «for [tcp:1.2.3.4:443]».
        (try! NSRegularExpression(pattern: #"(?i)(request to |for \[)(tcp|udp):[^\s\]]+"#), "$1$2:<назначение>"),
    ]

    /// Where connections went: the sites the user opened.
    public static func hideDestinations(_ text: String) -> String {
        var result = text
        for (expression, template) in destinations {
            result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                         withTemplate: template.replacingOccurrences(of: "<назначение>", with: NSRegularExpression.escapedTemplate(for: CoreText.t("<назначение>"))))
        }
        return result
    }
}

public extension Redactor {
    /// IPv4, and IPv6 with `::` or all eight groups — so a time like 08:02:01 is
    /// not taken for an address (3.3).
    private static let ipAddress = try! NSRegularExpression(pattern: #"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])|(?<![0-9A-Fa-f:])(?:(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|(?:[0-9A-Fa-f]{1,4}:){1,7}:(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6})?|::(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6}))(?![0-9A-Fa-f:])"#)

    /// Every IP address in the text becomes `<адрес>`, but those in `keeping`. For
    /// lines about the user's own servers (a failed probe names the address it
    /// dialled), where a server's name may be missing and only its address shows.
    static func hideAddresses(_ text: String, keeping: Set<String> = []) -> String {
        let placeholder = CoreText.t("<адрес>")
        var result = ""
        var last = text.startIndex
        for match in ipAddress.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[last ..< range.lowerBound]
            let address = String(text[range])
            result += keeping.contains(address.lowercased()) ? address : placeholder
            last = range.upperBound
        }
        result += text[last...]
        return result
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
                line = line.replacingOccurrences(of: name, with: CoreText.t("<сервер>"), options: .caseInsensitive)
                named = true
            }
            if named { line = hideAddresses(line, keeping: tunnelAddresses) }
            return line
        }.joined(separator: "\n")
    }
}
