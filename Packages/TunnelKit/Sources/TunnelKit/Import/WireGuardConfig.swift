import Foundation

/// WireGuard / AmneziaWG parameters from any source, turned into a sing-box
/// `wireguard` endpoint.
struct WireGuardConfig {
    struct Peer {
        var host = ""
        var port = 51820
        var publicKey = ""
        var preSharedKey: String?
        var allowedIPs: [String] = []
        var keepalive: Int?
        var reserved: [Int]?
    }

    var privateKey = ""
    var addresses: [String] = []
    var mtu: Int?
    var peers: [Peer] = []
    /// AmneziaWG obfuscation values keyed by lowercased name (jc, s1, h1, i1…).
    var amnezia: [String: String] = [:]

    static let amneziaKeys = [
        "jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5",
    ]
    private static let integerKeys: Set<String> = ["jc", "jmin", "jmax", "s1", "s2", "s3", "s4"]
    private static let rangeKeys: Set<String> = ["h1", "h2", "h3", "h4"]

    func endpoint() throws -> JSON {
        guard !privateKey.isEmpty else { throw ImportError.missingField("PrivateKey") }
        guard !peers.isEmpty else { throw ImportError.missingField("Peer") }
        var object: [String: JSON] = [
            "type": "wireguard",
            "private_key": .string(privateKey),
        ]
        let prefixes = addresses.compactMap(WireGuardConfig.prefix)
        guard !prefixes.isEmpty else { throw ImportError.missingField("Address") }
        object["address"] = .strings(prefixes)
        if let mtu, mtu > 0 { object["mtu"] = .int(mtu) }
        var peerObjects: [JSON] = []
        for peer in peers {
            guard !peer.host.isEmpty else { throw ImportError.missingField("Endpoint") }
            guard !peer.publicKey.isEmpty else { throw ImportError.missingField("PublicKey") }
            var item: [String: JSON] = [
                "address": .string(peer.host),
                "port": .int(peer.port),
                "public_key": .string(peer.publicKey),
            ]
            if let psk = peer.preSharedKey?.nonEmpty { item["pre_shared_key"] = .string(psk) }
            let allowed = peer.allowedIPs.compactMap(WireGuardConfig.prefix)
            item["allowed_ips"] = .strings(allowed.isEmpty ? ["0.0.0.0/0", "::/0"] : allowed)
            if let keepalive = peer.keepalive, keepalive > 0 { item["persistent_keepalive_interval"] = .int(keepalive) }
            if let reserved = peer.reserved, reserved.count == 3 { item["reserved"] = .array(reserved.map { .int($0) }) }
            peerObjects.append(.object(item))
        }
        object["peers"] = .array(peerObjects)
        for (key, value) in amnezia {
            let trimmed = value.trimmed
            guard !trimmed.isEmpty else { continue }
            if WireGuardConfig.integerKeys.contains(key) {
                guard let number = Int(trimmed), number >= 0 else { throw ImportError.unsupportedOption("AmneziaWG \(key)=\(trimmed)") }
                if number > 0 { object[key] = .int(number) }
            } else if WireGuardConfig.rangeKeys.contains(key) {
                if let number = Int(trimmed) {
                    if number > 0 { object[key] = .int(number) }
                } else if StreamSettings.range(.string(trimmed)) != nil {
                    object[key] = .string(trimmed)
                } else {
                    throw ImportError.unsupportedOption("AmneziaWG \(key)=\(trimmed)")
                }
            } else {
                object[key] = .string(trimmed)
            }
        }
        return .object(object)
    }

    /// "10.0.0.2" → "10.0.0.2/32", "fd00::2" → "fd00::2/128".
    static func prefix(_ text: String) -> String? {
        let value = text.trimmed
        guard !value.isEmpty else { return nil }
        if value.contains("/") { return value }
        return value.contains(":") ? value + "/128" : value + "/32"
    }

    /// "1,2,3" or Base64 of three bytes.
    static func reserved(_ text: String) -> [Int]? {
        let numbers = text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if numbers.count == 3, numbers.allSatisfy({ (0 ... 255).contains($0) }) { return numbers }
        if let data = TextCoding.base64Data(text), data.count == 3 { return data.map { Int($0) } }
        return nil
    }

    /// Parses a WireGuard / AmneziaWG `.conf` file.
    static func parseConf(_ text: String) throws -> WireGuardConfig {
        var config = WireGuardConfig()
        var section = ""
        var currentPeer: Peer?
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine
            if let hash = line.firstIndex(of: "#") { line = String(line[line.startIndex ..< hash]) }
            line = line.trimmed
            guard !line.isEmpty else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                if let peer = currentPeer { config.peers.append(peer) }
                currentPeer = nil
                section = line.dropFirst().dropLast().lowercased()
                if section == "peer" { currentPeer = Peer() }
                continue
            }
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { continue }
            let key = pair[0].lowercased()
            let value = pair[1]
            if section == "interface" {
                switch key {
                case "privatekey": config.privateKey = value
                case "address": config.addresses += StreamSettings.list(value)
                case "mtu": config.mtu = Int(value)
                default:
                    if amneziaKeys.contains(key) { config.amnezia[key] = value }
                }
            } else if section == "peer" {
                switch key {
                case "publickey": currentPeer?.publicKey = value
                case "presharedkey": currentPeer?.preSharedKey = value
                case "allowedips": currentPeer?.allowedIPs += StreamSettings.list(value)
                case "persistentkeepalive": currentPeer?.keepalive = Int(value)
                case "endpoint":
                    if let authority = Authority.parse(value) {
                        currentPeer?.host = authority.host
                        currentPeer?.port = authority.port ?? 51820
                    }
                case "reserved": currentPeer?.reserved = reserved(value)
                default: continue
                }
            }
        }
        if let peer = currentPeer { config.peers.append(peer) }
        return config
    }
}
