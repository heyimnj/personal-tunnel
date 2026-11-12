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
    /// Run by Xray-core instead of sing-box.
    public var xray = false

    /// The line the Classic interface prints under a server.
    public var summary: String {
        if isMixedGroup { return CoreText.t("Группа · разные протоколы") }
        return ([proto, security, transport] + (flow.map { [$0] } ?? []) + (xray ? ["Xray"] : [])).joined(separator: " · ")
    }

    /// Short tags for the Minimal interface, in display order.
    public var badges: [String] {
        if isMixedGroup { return [CoreText.t("Группа")] }
        var result = [proto]
        switch security {
        case "REALITY": result.append("Reality")
        case CoreText.t("Без транспортного TLS"): result.append(CoreText.t("без TLS"))
        case CoreText.t("Шифрование протокола"): break
        default: result.append(security)
        }
        result.append(transport == "TCP/RAW" ? "TCP" : transport)
        if let flow { result.append(flow) }
        if xray { result.append("Xray") }
        return result
    }

    static let transportNames: [String: String] = [
        "tcp": "TCP/RAW", "ws": "WebSocket", "grpc": "gRPC", "httpupgrade": "HTTPUpgrade",
        "xhttp": "XHTTP", "quic": "QUIC", "http": "HTTP",
    ]

    public init(object: JSONValue) {
        let type = object["type"]?.stringValue?.lowercased() ?? ""
        if type == XrayBacked.type {
            let facts = XrayBacked.facts(object)
            proto = facts.proto
            switch facts.security {
            case "reality": security = "REALITY"
            case "tls": security = "TLS"
            default: security = facts.proto == "SHADOWSOCKS" ? CoreText.t("Шифрование протокола") : CoreText.t("Без транспортного TLS")
            }
            transport = ProtocolFacts.transportNames[facts.network] ?? facts.network
            flow = facts.vision ? "Vision" : nil
            xray = true
            return
        }
        let tls = object["tls"]
        let isQUIC = ["hysteria", "hysteria2", "tuic"].contains(type)
        proto = type.uppercased()
        if tls?.at("reality", "enabled")?.boolValue == true {
            security = "REALITY"
        } else if tls?["enabled"]?.boolValue == true || isQUIC {
            security = "TLS"
        } else if ["wireguard", "awg", "amneziawg", "shadowsocks"].contains(type) {
            security = CoreText.t("Шифрование протокола")
        } else {
            security = CoreText.t("Без транспортного TLS")
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
