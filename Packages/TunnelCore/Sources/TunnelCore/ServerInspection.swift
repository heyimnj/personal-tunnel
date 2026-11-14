import Foundation

/// «Ссылка, QR и JSON»: what a server's page shows about it.
public enum ServerInspection {
    /// Keys whose values are secrets: masked in the JSON a person can show or copy.
    static let secretKeys: Set<String> = [
        "uuid", "password", "private_key", "pre_shared_key", "psk", "auth", "auth_str", "token", "secret", "short_id",
        // Xray's own names.
        "id", "privatekey", "presharedkey", "shortid", "seed",
    ]

    /// Flow, uTLS fingerprint and ALPN, as in 1.5.0.
    public static func details(_ node: ServerNode) -> [(String, String)] {
        let object = node.isGroup ? (node.members.first ?? node.outbound) : node.outbound
        let tls = object["tls"]
        let alpn = tls?["alpn"]?.stringList ?? []
        return [
            ("Flow", object["flow"]?.stringValue ?? "—"),
            ("uTLS", tls?["utls"]?["fingerprint"]?.stringValue ?? "—"),
            ("ALPN", alpn.isEmpty ? "—" : alpn.joined(separator: ", ")),
        ]
    }

    /// How the server's certificate is checked (3.1.2), for its page.
    public static func certificateCheck(_ node: ServerNode) -> String {
        let object = node.isGroup ? (node.members.first ?? node.outbound) : node.outbound
        if object["type"]?.stringValue == XrayBacked.type { return CoreText.t("проверяет Xray-core") }
        guard let tls = object["tls"], tls["enabled"]?.boolValue == true else { return "—" }
        if tls["reality"]?["enabled"]?.boolValue == true { return "REALITY" }
        if tls["insecure"]?.boolValue == true { return CoreText.t("не проверяется") }
        if tls["certificate_sha256"] != nil || tls["certificate_public_key_sha256"] != nil { return CoreText.t("по отпечатку") }
        if tls["certificate"] != nil { return CoreText.t("свой центр сертификации") }
        return CoreText.t("по корням Mozilla")
    }

    /// The server as the provider gave it (3.1.2), secrets and addresses replaced
    /// by `***`: the Xray JSON it came in, or its link. Nil for servers that have
    /// neither (added from a sing-box file).
    public static func safeSource(_ node: ServerNode) -> String? {
        if let source = node.source {
            return mask(source, hidingAddresses: true).serialized(pretty: true)
        }
        guard let link = node.link, let schemeEnd = link.range(of: "://") else { return nil }
        let scheme = link[..<schemeEnd.lowerBound]
        var rest = String(link[schemeEnd.upperBound...])
        // vmess:// carries base64 JSON: shown decoded, masked.
        if scheme.lowercased() == "vmess", let data = TextCoding.decodeBase64(rest.components(separatedBy: "#").first ?? rest),
           let json = try? JSONValue.parse(String(decoding: data, as: UTF8.self)) {
            var fields = json.objectValue ?? [:]
            for key in ["id", "add", "host"] where fields[key] != nil { fields[key] = "***" }
            return "vmess:// " + JSONValue.object(fields).serialized(pretty: true)
        }
        // user@host:port → ***@***:port; query and name stay.
        let end = rest.firstIndex(where: { $0 == "?" || $0 == "#" || $0 == "/" }) ?? rest.endIndex
        let authority = String(rest[..<end])
        let port = authority.range(of: ":", options: .backwards).map { String(authority[$0.lowerBound...]) } ?? ""
        let safePort = port.allSatisfy { $0 == ":" || $0.isNumber || $0 == "," || $0 == "-" } && !port.contains("]") ? port : ""
        rest.replaceSubrange(rest.startIndex ..< end, with: (authority.contains("@") ? "***@" : "") + "***" + safePort)
        var query = rest
        for key in ["password", "pwd", "auth", "sid", "obfs-password", "obfsParam", "key"] {
            query = query.replacingOccurrences(of: "(?i)([?&]" + NSRegularExpression.escapedPattern(for: key) + "=)[^&#]*", with: "$1***", options: .regularExpression)
        }
        return scheme + "://" + query
    }

    /// The server's outbounds as sing-box JSON with every secret replaced by `***`.
    public static func safeJSON(_ node: ServerNode) -> String {
        let objects = [node.outbound] + node.members
        let document: JSONValue = ["outbounds": .array(objects.map { mask($0) })]
        return document.serialized(pretty: true)
    }

    /// Keys whose values are a server's address (hidden in the provider's config).
    static let addressKeys: Set<String> = ["address", "server"]

    static func mask(_ value: JSONValue, hidingAddresses: Bool = false) -> JSONValue {
        switch value {
        case var .object(fields):
            for (key, field) in fields {
                let lower = key.lowercased()
                if secretKeys.contains(lower) || (hidingAddresses && addressKeys.contains(lower)), field.stringValue != nil || field.intValue != nil {
                    fields[key] = "***"
                } else {
                    fields[key] = mask(field, hidingAddresses: hidingAddresses)
                }
            }
            return .object(fields)
        case let .array(items):
            return .array(items.map { mask($0, hidingAddresses: hidingAddresses) })
        default:
            return value
        }
    }
}
