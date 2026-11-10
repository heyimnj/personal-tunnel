import Foundation

/// Public facts about a server's protocol: never credentials, hosts or paths.
public struct ProtocolFacts: Hashable, Sendable {
    /// `VLESS`, `HYSTERIA2`...
    public var proto: String
    /// `REALITY`, `TLS`, `Шифрование протокола` or `Без транспортного TLS`.
    public var security: String
    /// `TCP/RAW`, `WebSocket`, `gRPC`, `HTTPUpgrade`, `XHTTP`, `QUIC`...
    public var transport: String
    /// `Vision` when the XTLS flow is on.
    public var flow: String?
    /// Provider group whose members differ.
    public var isMixedGroup = false

    /// The line the Classic interface prints under a server.
    public var summary: String {
        if isMixedGroup { return "Группа · разные протоколы" }
        return ([proto, security, transport] + (flow.map { [$0] } ?? [])).joined(separator: " · ")
    }

    /// Short tags for the Minimal interface, in display order.
    public var badges: [String] {
        if isMixedGroup { return ["Группа"] }
        var result = [proto]
        switch security {
        case "REALITY": result.append("Reality")
        case "Без транспортного TLS": result.append("без TLS")
        case "Шифрование протокола": break
        default: result.append(security)
        }
        result.append(transport == "TCP/RAW" ? "TCP" : transport)
        if let flow { result.append(flow) }
        return result
    }

    static let transportNames: [String: String] = [
        "tcp": "TCP/RAW", "ws": "WebSocket", "grpc": "gRPC", "httpupgrade": "HTTPUpgrade",
        "xhttp": "XHTTP", "quic": "QUIC", "http": "HTTP",
    ]

    public init(object: JSONValue) {
        let type = object["type"]?.stringValue?.lowercased() ?? ""
        let tls = object["tls"]
        let isQUIC = ["hysteria", "hysteria2", "tuic"].contains(type)
        proto = type.uppercased()
        if tls?.at("reality", "enabled")?.boolValue == true {
            security = "REALITY"
        } else if tls?["enabled"]?.boolValue == true || isQUIC {
            security = "TLS"
        } else if ["wireguard", "awg", "amneziawg", "shadowsocks"].contains(type) {
            security = "Шифрование протокола"
        } else {
            security = "Без транспортного TLS"
        }
        let raw = object.at("transport", "type")?.stringValue?.lowercased() ?? (isQUIC ? "quic" : "tcp")
        transport = ProtocolFacts.transportNames[raw] ?? raw
        flow = object["flow"]?.stringValue == "xtls-rprx-vision" ? "Vision" : nil
    }
}

public extension ServerNode {
    var facts: ProtocolFacts {
        guard isGroup else { return ProtocolFacts(object: outbound) }
        let all = Set(members.map { ProtocolFacts(object: $0) })
        if all.count == 1, let only = all.first { return only }
        var mixed = ProtocolFacts(object: members.first ?? outbound)
        mixed.isMixedGroup = true
        return mixed
    }
}
