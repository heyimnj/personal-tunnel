import Foundation

/// Reads the proxy outbounds and endpoints of a sing-box configuration.
enum SingBoxImporter {
    static let proxyTypes: Set<String> = [
        "vless", "vmess", "trojan", "shadowsocks", "hysteria2", "hysteria", "tuic", "naive", "socks", "http",
        "anytls", "wireguard", "masque",
    ]
    static let groupTypes: Set<String> = ["selector", "urltest", "direct", "block", "dns", "chain"]
    static let unsupportedTypes: [String: String] = [
        "tailscale": "Tailscale", "openvpn-client": "OpenVPN", "openconnect": "OpenConnect", "mieru": "Mieru",
        "shadowsocksr": "ShadowsocksR", "ssh": "SSH", "tor": "Tor", "shadowtls": "ShadowTLS (цепочка)",
    ]
    /// Dial fields that reference tags of the source configuration.
    static let foreignReferenceKeys = ["tag", "detour", "domain_resolver", "domain_strategy", "bind_interface", "routing_mark", "netns"]

    static func looksLikeSingBox(_ json: JSON) -> Bool {
        let outbounds = json["outbounds"]?.array ?? []
        let endpoints = json["endpoints"]?.array ?? []
        return (outbounds + endpoints).contains { $0["type"] != nil && $0["protocol"] == nil }
    }

    static func importServers(_ json: JSON) -> ([ImportedServer], [SkippedEntry]) {
        var servers: [ImportedServer] = []
        var skipped: [SkippedEntry] = []
        let items = (json["endpoints"]?.array ?? []) + (json["outbounds"]?.array ?? [])
        for item in items {
            let type = item["type"]?.text ?? ""
            let name = item["tag"]?.text ?? type
            if groupTypes.contains(type) { continue }
            if let label = unsupportedTypes[type] {
                skipped.append(SkippedEntry(name: name, reason: ImportError.unsupportedProtocol(label).description))
                continue
            }
            guard proxyTypes.contains(type) else {
                skipped.append(SkippedEntry(name: name, reason: ImportError.unsupportedProtocol(type).description))
                continue
            }
            do {
                servers.append(ImportedServer(name: name, outbound: try normalize(item)))
            } catch {
                skipped.append(SkippedEntry(name: name, reason: String(describing: error)))
            }
        }
        return (servers, skipped)
    }

    /// Strips references to the source configuration and converts the
    /// pre-1.11 WireGuard outbound to an endpoint.
    static func normalize(_ item: JSON) throws -> JSON {
        guard var object = item.object else { throw ImportError.invalidJSON("outbound не объект") }
        for key in foreignReferenceKeys { object[key] = nil }
        if object["type"]?.string == "wireguard", object["peers"] == nil || object["local_address"] != nil {
            var config = WireGuardConfig()
            config.privateKey = object["private_key"]?.text ?? ""
            config.addresses = object["local_address"]?.stringList ?? object["address"]?.stringList ?? []
            config.mtu = object["mtu"]?.int
            if let peers = object["peers"]?.array, !peers.isEmpty {
                for peerJSON in peers {
                    var peer = WireGuardConfig.Peer()
                    peer.host = peerJSON["server"]?.text ?? peerJSON["address"]?.text ?? ""
                    peer.port = peerJSON["server_port"]?.int ?? peerJSON["port"]?.int ?? 51820
                    peer.publicKey = peerJSON["public_key"]?.text ?? ""
                    peer.preSharedKey = peerJSON["pre_shared_key"]?.text
                    peer.allowedIPs = peerJSON["allowed_ips"]?.stringList ?? []
                    peer.reserved = peerJSON["reserved"]?.array?.compactMap(\.int)
                    config.peers.append(peer)
                }
            } else {
                var peer = WireGuardConfig.Peer()
                peer.host = object["server"]?.text ?? ""
                peer.port = object["server_port"]?.int ?? 51820
                peer.publicKey = object["peer_public_key"]?.text ?? ""
                peer.preSharedKey = object["pre_shared_key"]?.text
                peer.reserved = object["reserved"]?.array?.compactMap(\.int)
                config.peers = [peer]
            }
            for key in WireGuardConfig.amneziaKeys {
                if let value = object[key]?.string { config.amnezia[key] = value }
            }
            return try config.endpoint()
        }
        return .object(object)
    }
}
