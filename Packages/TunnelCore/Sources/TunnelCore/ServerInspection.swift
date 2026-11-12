import Foundation

/// «Ссылка, QR и JSON»: what a server's page shows about it.
public enum ServerInspection {
    /// Keys whose values are secrets: masked in the JSON a person can show or copy.
    static let secretKeys: Set<String> = [
        "uuid", "password", "private_key", "pre_shared_key", "psk", "auth", "auth_str", "token", "secret", "short_id",
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

    /// The server's outbounds as sing-box JSON with every secret replaced by `***`.
    public static func safeJSON(_ node: ServerNode) -> String {
        let objects = [node.outbound] + node.members
        let document: JSONValue = ["outbounds": .array(objects.map(mask))]
        return document.serialized(pretty: true)
    }

    static func mask(_ value: JSONValue) -> JSONValue {
        switch value {
        case var .object(fields):
            for (key, field) in fields {
                if secretKeys.contains(key.lowercased()), field.stringValue != nil || field.intValue != nil {
                    fields[key] = "***"
                } else {
                    fields[key] = mask(field)
                }
            }
            return .object(fields)
        case let .array(items):
            return .array(items.map(mask))
        default:
            return value
        }
    }
}
