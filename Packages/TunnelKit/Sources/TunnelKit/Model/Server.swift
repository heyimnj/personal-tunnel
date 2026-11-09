import Foundation

/// One proxy server. The connection parameters are kept as the sing-box
/// outbound (or, for WireGuard, endpoint) object they translate to, without a
/// `tag`; tags are assigned when a configuration is built.
public struct Server: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var outbound: JSON
    /// The share link the server was imported from, when there was one.
    public var link: String?
    public var isFavorite: Bool

    public init(id: UUID = UUID(), name: String, outbound: JSON, link: String? = nil, isFavorite: Bool = false) {
        self.id = id
        self.name = name
        self.outbound = outbound
        self.link = link
        self.isFavorite = isFavorite
    }

    public init(imported: ImportedServer, id: UUID = UUID()) {
        self.init(id: id, name: imported.name, outbound: imported.outbound, link: imported.link)
    }

    public var type: String { outbound["type"]?.string ?? "" }

    /// WireGuard is an endpoint in sing-box 1.11+, everything else an outbound.
    public var isEndpoint: Bool { type == "wireguard" }

    public var host: String? {
        if let server = outbound["server"]?.text { return server }
        if let peer = outbound["peers"]?[0], let address = peer["address"]?.text { return address }
        return nil
    }

    public var port: Int? {
        if let port = outbound["server_port"]?.int { return port }
        if let peer = outbound["peers"]?[0], let port = peer["port"]?.int { return port }
        return nil
    }

    public var descriptor: ServerDescriptor { ServerDescriptor(outbound: outbound) }

    /// Identity of the connection parameters. Two imports of the same server
    /// produce the same fingerprint even if the panel renamed it.
    public var fingerprint: String {
        var copy = outbound
        copy["tag"] = nil
        return copy.serialized()
    }

    /// Country derived from the server name.
    public var country: Country? { Country.detect(in: name) }

    /// The name without a leading flag emoji (the flag is shown separately).
    public var displayName: String { Country.stripFlags(from: name) }
}

/// A server as produced by an importer, before it is stored.
public struct ImportedServer: Hashable, Sendable {
    public var name: String
    public var outbound: JSON
    public var link: String?

    public init(name: String, outbound: JSON, link: String? = nil) {
        self.name = name
        self.outbound = outbound
        self.link = link
    }
}

/// Human readable facts about a server, derived from its outbound.
public struct ServerDescriptor: Hashable, Sendable {
    public var protocolName: String
    public var transport: String?
    public var security: String?
    public var flow: String?
    /// QUIC/UDP protocols: a TCP connect test says nothing about them.
    public var isUDPBased: Bool
    public var allowsInsecure: Bool

    public init(outbound: JSON) {
        let type = outbound["type"]?.string ?? ""
        protocolName = ServerDescriptor.protocolName(type)
        isUDPBased = ["hysteria", "hysteria2", "tuic", "wireguard"].contains(type) || outbound["quic"]?.bool == true
        if let transportType = outbound["transport"]?["type"]?.string {
            transport = ServerDescriptor.transportName(transportType)
        } else if ["vless", "vmess", "trojan"].contains(type) {
            transport = "TCP"
        } else {
            transport = nil
        }
        let tls = outbound["tls"]
        if tls?["reality"]?["enabled"]?.bool == true {
            security = "Reality"
        } else if tls?["enabled"]?.bool == true, !["hysteria", "hysteria2", "tuic", "naive", "anytls"].contains(type) {
            security = "TLS"
        } else {
            security = nil
        }
        allowsInsecure = tls?["insecure"]?.bool == true
        if let value = outbound["flow"]?.text, value.contains("vision") {
            flow = "Vision"
        } else {
            flow = nil
        }
    }

    public static func protocolName(_ type: String) -> String {
        switch type {
        case "vless": return "VLESS"
        case "vmess": return "VMess"
        case "trojan": return "Trojan"
        case "shadowsocks": return "Shadowsocks"
        case "hysteria2": return "Hysteria2"
        case "hysteria": return "Hysteria"
        case "tuic": return "TUIC"
        case "wireguard": return "WireGuard"
        case "naive": return "Naive"
        case "socks": return "SOCKS"
        case "http": return "HTTP"
        case "anytls": return "AnyTLS"
        case "shadowtls": return "ShadowTLS"
        default: return type.uppercased()
        }
    }

    public static func transportName(_ type: String) -> String {
        switch type {
        case "ws": return "WS"
        case "grpc": return "gRPC"
        case "httpupgrade": return "HTTPUpgrade"
        case "xhttp": return "XHTTP"
        case "http": return "HTTP"
        case "quic": return "QUIC"
        default: return type.uppercased()
        }
    }

    /// Short tags for a server row, e.g. ["VLESS", "Reality", "Vision"].
    public var tags: [String] {
        var tags = [protocolName]
        if let transport, transport != "TCP" { tags.append(transport) }
        if let security { tags.append(security) }
        if let flow { tags.append(flow) }
        if protocolName == "WireGuard", isAmneziaWG { tags[0] = "AmneziaWG" }
        return tags
    }

    var isAmneziaWG = false
}

public extension Server {
    /// Tags including the AmneziaWG distinction.
    var protocolTags: [String] {
        var descriptor = self.descriptor
        descriptor.isAmneziaWG = type == "wireguard" && ["jc", "jmin", "jmax", "s1", "s2", "h1", "i1"].contains { outbound[$0] != nil }
        return descriptor.tags
    }
}
