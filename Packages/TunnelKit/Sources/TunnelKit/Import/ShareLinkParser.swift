import Foundation

/// Parses single-server share links into sing-box outbounds.
public enum ShareLinkParser {
    public static let supportedSchemes: Set<String> = [
        "vless", "vmess", "trojan", "ss", "hysteria2", "hy2", "hysteria", "hy", "tuic",
        "wireguard", "wg", "naive+https", "naive+quic", "naive", "socks", "socks5", "socks4", "anytls",
    ]

    /// `true` for text that looks like a share link of any proxy scheme,
    /// including the ones that are not supported (so they can be reported).
    public static func looksLikeLink(_ text: String) -> Bool {
        guard let range = text.range(of: "://") else { return false }
        let scheme = text[text.startIndex ..< range.lowerBound].lowercased()
        guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" }) else { return false }
        return supportedSchemes.contains(scheme) || UnsupportedProtocols.schemes[scheme] != nil
    }

    public static func parse(_ link: String) throws -> ImportedServer {
        let text = link.trimmed
        guard let range = text.range(of: "://") else { throw ImportError.invalidLink("нет схемы") }
        let scheme = text[text.startIndex ..< range.lowerBound].lowercased()
        if let name = UnsupportedProtocols.schemes[scheme] { throw ImportError.unsupportedProtocol(name) }
        switch scheme {
        case "vless": return try parseVLESS(text)
        case "vmess": return try parseVMess(text)
        case "trojan": return try parseTrojan(text)
        case "ss": return try parseShadowsocks(text)
        case "hysteria2", "hy2": return try parseHysteria2(text)
        case "hysteria", "hy": return try parseHysteria(text)
        case "tuic": return try parseTUIC(text)
        case "wireguard", "wg": return try parseWireGuard(text)
        case "naive+https", "naive+quic", "naive": return try parseNaive(text)
        case "socks", "socks5", "socks4": return try parseSOCKS(text)
        case "anytls": return try parseAnyTLS(text)
        default: throw ImportError.unsupportedProtocol(scheme)
        }
    }

    // MARK: Helpers

    private static func uri(_ link: String) throws -> ShareURI {
        guard let uri = ShareURI.parse(link) else { throw ImportError.invalidLink("не удалось разобрать адрес") }
        return uri
    }

    private static func authority(_ uri: ShareURI, defaultPort: Int? = nil) throws -> Authority {
        guard var authority = Authority.parse(uri.authority) else { throw ImportError.invalidLink("неверный адрес сервера") }
        if authority.port == nil { authority.port = defaultPort }
        guard authority.port != nil else { throw ImportError.missingField("port") }
        return authority
    }

    static func name(_ fragment: String, fallback: String) -> String {
        let value = fragment.trimmed
        return value.isEmpty ? fallback : value
    }

    private static func userInfo(_ authority: Authority) -> String {
        TextCoding.percentDecoded(authority.userInfo ?? "")
    }

    private static func base(_ type: String, _ authority: Authority) -> [String: JSON] {
        ["type": .string(type), "server": .string(authority.host), "server_port": .int(authority.port ?? 443)]
    }

    private static func flag(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }

    /// sing-box takes a single VLESS flow: XTLS Vision.
    static func normalizedFlow(_ flow: String?) throws -> String? {
        guard let flow = flow?.trimmed.lowercased(), !flow.isEmpty, flow != "none" else { return nil }
        if flow.hasPrefix("xtls-rprx-vision") { return "xtls-rprx-vision" }
        throw ImportError.unsupportedOption("flow \(flow)")
    }

    // MARK: VLESS

    static func parseVLESS(_ link: String) throws -> ImportedServer {
        let uri = try uri(link)
        let authority = try authority(uri, defaultPort: 443)
        let uuid = userInfo(authority)
        guard !uuid.isEmpty else { throw ImportError.missingField("uuid") }
        let stream = StreamSettings.fromQuery(uri.query)
        var object = base("vless", authority)
        object["uuid"] = .string(uuid)
        if let flow = try normalizedFlow(uri.query["flow"]) { object["flow"] = .string(flow) }
        if let encryption = uri.query["encryption"]?.nonEmpty, encryption != "none" {
            object["encryption"] = .string(encryption)
        }
        object["packet_encoding"] = "xudp"
        if let transport = try stream.transport() { object["transport"] = transport }
        if let tls = stream.tls(defaultServerName: authority.host) { object["tls"] = tls }
        return ImportedServer(name: name(uri.fragment, fallback: authority.host), outbound: .object(object), link: link)
    }

    // MARK: VMess

    static func parseVMess(_ link: String) throws -> ImportedServer {
        let body = String(link.trimmed.dropFirst("vmess://".count))
        let payload = body.split(separator: "#", maxSplits: 1).first.map(String.init) ?? body
        if let decoded = TextCoding.base64String(payload), let json = JSON.tryParse(decoded), json.object != nil {
            return try parseVMessJSON(json, link: link)
        }
        // AEAD form: vmess://uuid@host:port?type=ws&security=tls#name
        let uri = try uri(link)
        let authority = try authority(uri, defaultPort: 443)
        let uuid = userInfo(authority)
        guard !uuid.isEmpty else { throw ImportError.missingField("uuid") }
        let stream = StreamSettings.fromQuery(uri.query)
        var object = base("vmess", authority)
        object["uuid"] = .string(uuid)
        object["security"] = .string(uri.query["encryption"]?.nonEmpty ?? uri.query["scy"]?.nonEmpty ?? "auto")
        object["alter_id"] = .int(Int(uri.query["aid"] ?? "") ?? 0)
        if let transport = try stream.transport() { object["transport"] = transport }
        if let tls = stream.tls(defaultServerName: authority.host) { object["tls"] = tls }
        return ImportedServer(name: name(uri.fragment, fallback: authority.host), outbound: .object(object), link: link)
    }

    private static func parseVMessJSON(_ json: JSON, link: String) throws -> ImportedServer {
        guard let host = json["add"]?.text else { throw ImportError.missingField("add") }
        guard let port = json["port"]?.int, (1 ... 65535).contains(port) else { throw ImportError.missingField("port") }
        guard let uuid = json["id"]?.text else { throw ImportError.missingField("id") }
        var stream = StreamSettings()
        stream.network = json["net"]?.text ?? "tcp"
        stream.headerType = json["type"]?.text
        stream.host = json["host"]?.text
        stream.path = json["path"]?.text
        if stream.network == "grpc" { stream.serviceName = json["path"]?.text }
        if let mode = json["mode"]?.text { stream.mode = mode }
        let tls = json["tls"]?.text?.lowercased() ?? ""
        stream.security = tls == "tls" || tls == "reality" ? tls : "none"
        stream.serverName = json["sni"]?.text
        if let alpn = json["alpn"]?.text { stream.alpn = StreamSettings.list(alpn) }
        stream.fingerprint = json["fp"]?.text
        stream.insecure = json["allowInsecure"]?.bool ?? json["insecure"]?.bool ?? false
        stream.realityPublicKey = json["pbk"]?.text
        stream.realityShortID = json["sid"]?.text
        var object: [String: JSON] = [
            "type": "vmess",
            "server": .string(host),
            "server_port": .int(port),
            "uuid": .string(uuid),
            "security": .string(json["scy"]?.text ?? "auto"),
            "alter_id": .int(json["aid"]?.int ?? 0),
        ]
        if let transport = try stream.transport() { object["transport"] = transport }
        if let tlsObject = stream.tls(defaultServerName: stream.host ?? host) { object["tls"] = tlsObject }
        let title = json["ps"]?.text ?? host
        return ImportedServer(name: title, outbound: .object(object), link: link)
    }

    // MARK: Trojan

    static func parseTrojan(_ link: String) throws -> ImportedServer {
        let uri = try uri(link)
        let authority = try authority(uri, defaultPort: 443)
        let password = userInfo(authority)
        guard !password.isEmpty else { throw ImportError.missingField("password") }
        let stream = StreamSettings.fromQuery(uri.query, defaultSecurity: "tls")
        var object = base("trojan", authority)
        object["password"] = .string(password)
        if let transport = try stream.transport() { object["transport"] = transport }
        if let tls = stream.tls(defaultServerName: authority.host) { object["tls"] = tls }
        return ImportedServer(name: name(uri.fragment, fallback: authority.host), outbound: .object(object), link: link)
    }

    // MARK: Shadowsocks

    static let shadowsocksMethods: Set<String> = [
        "none", "plain", "aes-128-gcm", "aes-192-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "chacha20-poly1305",
        "xchacha20-ietf-poly1305", "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
        "aes-128-ctr", "aes-192-ctr", "aes-256-ctr", "aes-128-cfb", "aes-192-cfb", "aes-256-cfb", "rc4-md5",
        "chacha20-ietf", "xchacha20",
    ]

    static func parseShadowsocks(_ link: String) throws -> ImportedServer {
        var text = link.trimmed
        var fragment = ""
        if let hash = text.firstIndex(of: "#") {
            fragment = TextCoding.percentDecoded(String(text[text.index(after: hash)...]))
            text = String(text[text.startIndex ..< hash])
        }
        var body = String(text.dropFirst("ss://".count))
        var query: [String: String] = [:]
        if let question = body.firstIndex(of: "?") {
            query = TextCoding.query(String(body[body.index(after: question)...]))
            body = String(body[body.startIndex ..< question])
        }
        if body.hasSuffix("/") { body.removeLast() }
        // Legacy form: the whole "method:password@host:port" is Base64.
        if !body.contains("@"), let decoded = TextCoding.base64String(body) {
            body = decoded
        }
        guard let at = body.lastIndex(of: "@") else { throw ImportError.invalidLink("нет адреса сервера") }
        var credentials = String(body[body.startIndex ..< at])
        guard let authority = Authority.parse(String(body[body.index(after: at)...])), let port = authority.port else {
            throw ImportError.invalidLink("неверный адрес сервера")
        }
        credentials = TextCoding.percentDecoded(credentials)
        if !credentials.contains(":"), let decoded = TextCoding.base64String(credentials) {
            credentials = decoded
        }
        guard let colon = credentials.firstIndex(of: ":") else { throw ImportError.missingField("password") }
        let method = credentials[credentials.startIndex ..< colon].lowercased()
        let password = String(credentials[credentials.index(after: colon)...])
        guard shadowsocksMethods.contains(method) else { throw ImportError.unsupportedOption("шифр \(method)") }
        var object: [String: JSON] = [
            "type": "shadowsocks",
            "server": .string(authority.host),
            "server_port": .int(port),
            "method": .string(method == "plain" ? "none" : method),
            "password": .string(password),
        ]
        if let plugin = query["plugin"]?.nonEmpty {
            let parts = plugin.split(separator: ";", maxSplits: 1).map(String.init)
            var pluginName = parts[0]
            if pluginName == "simple-obfs" { pluginName = "obfs-local" }
            guard ["obfs-local", "v2ray-plugin"].contains(pluginName) else {
                throw ImportError.unsupportedOption("плагин \(pluginName)")
            }
            object["plugin"] = .string(pluginName)
            if parts.count > 1 { object["plugin_opts"] = .string(parts[1]) }
        }
        if query["uot"].map(flag) == true || query["udp-over-tcp"].map(flag) == true {
            object["udp_over_tcp"] = ["enabled": true, "version": 2]
        }
        return ImportedServer(name: name(fragment, fallback: authority.host), outbound: .object(object), link: link)
    }

    // MARK: Hysteria 2

    /// Converts `443,20000-30000` to sing-box `server_ports` (`20000:30000`).
    static func portRanges(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" }).compactMap { item in
            let value = item.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: ":")
            let bounds = value.split(separator: ":")
            guard !bounds.isEmpty, bounds.count <= 2, bounds.allSatisfy({ Int($0).map { (1 ... 65535).contains($0) } ?? false }) else {
                return nil
            }
            return bounds.count == 1 ? "\(bounds[0]):\(bounds[0])" : value
        }
    }

    static func parseHysteria2(_ link: String) throws -> ImportedServer {
        let uri = try uri(link)
        // Port hopping can be written in the authority: host:443,20000-30000
        var authorityText = uri.authority
        var hopPorts: [String] = []
        if let at = authorityText.lastIndex(of: "@") {
            let hostPart = authorityText[authorityText.index(after: at)...]
            if let colon = hostPart.lastIndex(of: ":"), hostPart[hostPart.index(after: colon)...].contains(where: { $0 == "," || $0 == "-" }) {
                let ports = String(hostPart[hostPart.index(after: colon)...])
                hopPorts = portRanges(ports)
                let first = ports.split(whereSeparator: { $0 == "," || $0 == "-" }).first.map(String.init) ?? "443"
                authorityText = String(authorityText[authorityText.startIndex ... at]) + hostPart[hostPart.startIndex ..< colon] + ":" + first
            }
        } else if let colon = authorityText.lastIndex(of: ":"), authorityText[authorityText.index(after: colon)...].contains(where: { $0 == "," || $0 == "-" }) {
            let ports = String(authorityText[authorityText.index(after: colon)...])
            hopPorts = portRanges(ports)
            let first = ports.split(whereSeparator: { $0 == "," || $0 == "-" }).first.map(String.init) ?? "443"
            authorityText = String(authorityText[authorityText.startIndex ..< colon]) + ":" + first
        }
        guard var authority = Authority.parse(authorityText) else { throw ImportError.invalidLink("неверный адрес сервера") }
        if authority.port == nil { authority.port = 443 }
        let query = uri.query
        var object = base("hysteria2", authority)
        let password = userInfo(authority).nonEmpty ?? query["auth"]?.nonEmpty ?? query["password"]?.nonEmpty
        if let password { object["password"] = .string(password) }
        var tls: [String: JSON] = ["enabled": true]
        if let sni = query["sni"]?.nonEmpty ?? query["peer"]?.nonEmpty {
            tls["server_name"] = .string(sni)
        } else if !StreamSettings.isIPAddress(authority.host) {
            tls["server_name"] = .string(authority.host)
        }
        if flag(query["insecure"] ?? query["allowinsecure"]) { tls["insecure"] = true }
        tls["alpn"] = .strings(query["alpn"].map(StreamSettings.list) ?? ["h3"])
        if let pin = query["pinsha256"]?.nonEmpty {
            tls["certificate_public_key_sha256"] = .strings([pin])
        }
        object["tls"] = .object(tls)
        if let obfs = query["obfs"]?.nonEmpty?.lowercased(), obfs != "none" {
            guard obfs == "salamander" || obfs == "gecko" else { throw ImportError.unsupportedOption("obfs \(obfs)") }
            var obfsObject: [String: JSON] = ["type": .string(obfs)]
            if let password = query["obfs-password"]?.nonEmpty ?? query["obfs_password"]?.nonEmpty {
                obfsObject["password"] = .string(password)
            }
            if obfs == "gecko" {
                if let size = (query["obfs-min-packet-size"] ?? query["obfs_min_packet_size"]).flatMap(Int.init) { obfsObject["min_packet_size"] = .int(size) }
                if let size = (query["obfs-max-packet-size"] ?? query["obfs_max_packet_size"]).flatMap(Int.init) { obfsObject["max_packet_size"] = .int(size) }
            }
            object["obfs"] = .object(obfsObject)
        }
        if let ports = (query["mport"] ?? query["server_ports"] ?? query["ports"])?.nonEmpty {
            hopPorts = portRanges(ports)
        }
        if !hopPorts.isEmpty {
            object["server_ports"] = .strings(hopPorts)
            object["hop_interval"] = .string(durationText(query["hop_interval"] ?? query["hop-interval"] ?? query["hopinterval"]) ?? "30s")
        }
        if let up = mbps(query["upmbps"] ?? query["up_mbps"] ?? query["up"]) { object["up_mbps"] = .int(up) }
        if let down = mbps(query["downmbps"] ?? query["down_mbps"] ?? query["down"]) { object["down_mbps"] = .int(down) }
        return ImportedServer(name: name(uri.fragment, fallback: authority.host), outbound: .object(object), link: link)
    }

    /// "30", "30s", "1m" → sing-box duration text.
    static func durationText(_ value: String?) -> String? {
        guard let value = value?.trimmed, !value.isEmpty else { return nil }
        if Int(value) != nil { return value + "s" }
        return value
    }

    /// "100", "100 mbps", "100Mbps" → 100.
    static func mbps(_ value: String?) -> Int? {
        guard let value = value?.trimmed.lowercased(), !value.isEmpty else { return nil }
        let digits = value.prefix { $0.isNumber }
        guard let number = Int(digits), number > 0 else { return nil }
        if value.contains("g") { return number * 1000 }
        if value.contains("k") { return max(1, number / 1000) }
        return number
    }

    // MARK: Hysteria (v1)

    static func parseHysteria(_ link: String) throws -> ImportedServer {
        let uri = try uri(link)
        let authority = try authority(uri, defaultPort: 443)
        let query = uri.query
        guard let up = mbps(query["upmbps"] ?? query["up"]), let down = mbps(query["downmbps"] ?? query["down"]) else {
            throw ImportError.missingField("upmbps/downmbps")
        }
        if let proto = query["protocol"]?.lowercased(), proto != "udp" {
            throw ImportError.unsupportedOption("Hysteria protocol \(proto)")
        }
        var object = base("hysteria", authority)
        object["up_mbps"] = .int(up)
        object["down_mbps"] = .int(down)
        if let auth = query["auth"]?.nonEmpty ?? userInfo(authority).nonEmpty { object["auth_str"] = .string(auth) }
        if let obfs = query["obfsparam"]?.nonEmpty ?? query["obfs-password"]?.nonEmpty { object["obfs"] = .string(obfs) }
        var tls: [String: JSON] = ["enabled": true]
        if let sni = query["peer"]?.nonEmpty ?? query["sni"]?.nonEmpty {
            tls["server_name"] = .string(sni)
        } else if !StreamSettings.isIPAddress(authority.host) {
            tls["server_name"] = .string(authority.host)
        }
        if flag(query["insecure"]) { tls["insecure"] = true }
        if let alpn = query["alpn"]?.nonEmpty { tls["alpn"] = .strings(StreamSettings.list(alpn)) }
        object["tls"] = .object(tls)
        if let ports = query["mport"]?.nonEmpty {
            object["server_ports"] = .strings(portRanges(ports))
        }
        return ImportedServer(name: name(uri.fragment, fallback: authority.host), outbound: .object(object), link: link)
    }

    // MARK: TUIC

    static func parseTUIC(_ link: String) throws -> ImportedServer {
        let uri = try uri(link)
        let authority = try authority(uri, defaultPort: 443)
        let credentials = userInfo(authority)
        let parts = credentials.split(separator: ":", maxSplits: 1).map(String.init)
        guard let uuid = parts.first?.nonEmpty else { throw ImportError.missingField("uuid") }
        let query = uri.query
        var object = base("tuic", authority)
        object["uuid"] = .string(uuid)
        if parts.count > 1 { object["password"] = .string(parts[1]) } else if let password = query["password"]?.nonEmpty {
            object["password"] = .string(password)
        }
        let congestion = (query["congestion_control"] ?? query["congestion"] ?? query["cc"])?.lowercased()
        if let congestion, ["cubic", "new_reno", "bbr"].contains(congestion) { object["congestion_control"] = .string(congestion) }
        if let relay = (query["udp_relay_mode"] ?? query["udp-relay-mode"])?.lowercased(), ["native", "quic"].contains(relay) {
            object["udp_relay_mode"] = .string(relay)
        }
        if flag(query["zero_rtt_handshake"] ?? query["reduce_rtt"]) { object["zero_rtt_handshake"] = true }
        var tls: [String: JSON] = ["enabled": true]
        if let sni = query["sni"]?.nonEmpty {
            tls["server_name"] = .string(sni)
        } else if !StreamSettings.isIPAddress(authority.host) {
            tls["server_name"] = .string(authority.host)
        }
        if flag(query["allow_insecure"] ?? query["insecure"] ?? query["allowinsecure"]) { tls["insecure"] = true }
        tls["alpn"] = .strings(query["alpn"].map(StreamSettings.list) ?? ["h3"])
        if flag(query["disable_sni"]) { tls["disable_sni"] = true }
        object["tls"] = .object(tls)
        return ImportedServer(name: name(uri.fragment, fallback: authority.host), outbound: .object(object), link: link)
    }

    // MARK: WireGuard

    static func parseWireGuard(_ link: String) throws -> ImportedServer {
        let uri = try uri(link)
        let authority = try authority(uri, defaultPort: 51820)
        let query = uri.query
        guard let privateKey = userInfo(authority).nonEmpty ?? query["privatekey"]?.nonEmpty ?? query["secretkey"]?.nonEmpty else {
            throw ImportError.missingField("private key")
        }
        guard let publicKey = query["publickey"]?.nonEmpty ?? query["peer_public_key"]?.nonEmpty ?? query["pbk"]?.nonEmpty else {
            throw ImportError.missingField("public key")
        }
        var config = WireGuardConfig()
        config.privateKey = privateKey
        config.addresses = (query["address"] ?? query["ip"] ?? query["local_address"]).map(StreamSettings.list) ?? []
        config.mtu = query["mtu"].flatMap(Int.init)
        var peer = WireGuardConfig.Peer()
        peer.host = authority.host
        peer.port = authority.port ?? 51820
        peer.publicKey = publicKey
        peer.preSharedKey = query["presharedkey"]?.nonEmpty ?? query["psk"]?.nonEmpty
        peer.allowedIPs = query["allowedips"].map(StreamSettings.list) ?? []
        peer.keepalive = (query["keepalive"] ?? query["persistentkeepalive"]).flatMap(Int.init)
        if let reserved = query["reserved"]?.nonEmpty {
            peer.reserved = WireGuardConfig.reserved(reserved)
        }
        config.peers = [peer]
        for key in WireGuardConfig.amneziaKeys {
            if let value = query[key]?.nonEmpty { config.amnezia[key] = value }
        }
        let outbound = try config.endpoint()
        return ImportedServer(name: name(uri.fragment, fallback: authority.host), outbound: outbound, link: link)
    }

    // MARK: Naive

    static func parseNaive(_ link: String) throws -> ImportedServer {
        let text = link.trimmed
        let isQUIC = text.lowercased().hasPrefix("naive+quic://")
        let uri = try uri(text)
        let authority = try authority(uri, defaultPort: 443)
        let credentials = userInfo(authority)
        let parts = credentials.split(separator: ":", maxSplits: 1).map(String.init)
        var object = base("naive", authority)
        if let user = parts.first?.nonEmpty { object["username"] = .string(user) }
        if parts.count > 1 { object["password"] = .string(parts[1]) }
        var tls: [String: JSON] = ["enabled": true]
        tls["server_name"] = .string(uri.query["sni"]?.nonEmpty ?? authority.host)
        object["tls"] = .object(tls)
        if isQUIC { object["quic"] = true }
        if let headers = uri.query["extra-headers"]?.nonEmpty {
            var extra: [String: JSON] = [:]
            for line in headers.components(separatedBy: "\r\n") {
                let pair = line.split(separator: ":", maxSplits: 1)
                if pair.count == 2 { extra[pair[0].trimmingCharacters(in: .whitespaces)] = .string(pair[1].trimmingCharacters(in: .whitespaces)) }
            }
            if !extra.isEmpty { object["extra_headers"] = .object(extra) }
        }
        if let concurrency = uri.query["insecure-concurrency"].flatMap(Int.init), concurrency > 1 {
            object["insecure_concurrency"] = .int(concurrency)
        }
        return ImportedServer(name: name(uri.fragment, fallback: authority.host), outbound: .object(object), link: link)
    }

    // MARK: SOCKS

    static func parseSOCKS(_ link: String) throws -> ImportedServer {
        let uri = try uri(link)
        let authority = try authority(uri, defaultPort: 1080)
        var object = base("socks", authority)
        var credentials = userInfo(authority)
        if !credentials.isEmpty, !credentials.contains(":"), let decoded = TextCoding.base64String(credentials) {
            credentials = decoded
        }
        let parts = credentials.split(separator: ":", maxSplits: 1).map(String.init)
        if let user = parts.first?.nonEmpty { object["username"] = .string(user) }
        if parts.count > 1 { object["password"] = .string(parts[1]) }
        if uri.scheme == "socks4" { object["version"] = "4" }
        return ImportedServer(name: name(uri.fragment, fallback: authority.host), outbound: .object(object), link: link)
    }

    // MARK: AnyTLS

    static func parseAnyTLS(_ link: String) throws -> ImportedServer {
        let uri = try uri(link)
        let authority = try authority(uri, defaultPort: 443)
        let password = userInfo(authority)
        guard !password.isEmpty else { throw ImportError.missingField("password") }
        var object = base("anytls", authority)
        object["password"] = .string(password)
        var stream = StreamSettings.fromQuery(uri.query, defaultSecurity: "tls")
        if stream.security == "none" { stream.security = "tls" }
        if let tls = stream.tls(defaultServerName: authority.host) { object["tls"] = tls }
        return ImportedServer(name: name(uri.fragment, fallback: authority.host), outbound: .object(object), link: link)
    }
}
