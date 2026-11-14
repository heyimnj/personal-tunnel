import Foundation

/// A server read from a link or a file, before it gets its tag.
public struct ParsedNode: Equatable {
    public var name: String
    /// sing-box outbound or endpoint without `tag`.
    public var outbound: JSONValue
    /// Outbounds the main one refers to, already tagged relative to each other.
    public var members: [JSONValue]
    public var link: String?
    /// The server as the provider wrote it, when it came as Xray JSON (3.1.2).
    public var source: JSONValue?

    public init(name: String, outbound: JSONValue, members: [JSONValue] = [], link: String? = nil, source: JSONValue? = nil) {
        self.name = name
        self.outbound = outbound
        self.members = members
        self.link = link
        self.source = source
    }
}

/// Server share links (`vless://`, `ss://`, `hysteria2://`...) → sing-box outbounds.
public enum ShareLink {
    public static let schemes: Set<String> = [
        "vless", "vmess", "trojan", "ss", "hysteria2", "hy2", "hysteria", "tuic", "wireguard", "wg", "awg",
        "socks", "socks5", "socks4", "anytls", "naive+https", "naive+quic", "http-proxy", "https-proxy",
    ]

    /// Schemes that are recognised only to say why they cannot be used.
    static let rejected: [String: String] = [
        "ssr": CoreText.t("ShadowsocksR не входит в сборку ядра."),
        "mieru": CoreText.t("Mieru не входит в сборку ядра."),
        "openvpn": CoreText.t("OpenVPN не входит в сборку ядра."),
        "tailscale": CoreText.t("Tailscale не входит в сборку ядра."),
    ]

    public static func isLink(_ text: String) -> Bool {
        guard let end = text.range(of: "://") else { return false }
        let scheme = text[..<end.lowerBound].lowercased()
        return schemes.contains(scheme) || rejected[scheme] != nil
    }

    public static func parse(_ raw: String) throws -> ParsedNode {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let end = link.range(of: "://") else { throw ImportError(CoreText.t("Это не ссылка сервера.")) }
        let scheme = link[..<end.lowerBound].lowercased()
        if let reason = rejected[scheme] { throw ImportError(reason) }
        var node: ParsedNode
        switch scheme {
        case "vless": node = try vless(link)
        case "vmess": node = try vmess(link)
        case "trojan": node = try trojan(link)
        case "ss": node = try shadowsocks(link)
        case "hysteria2", "hy2": node = try hysteria2(link)
        case "hysteria": node = try hysteria(link)
        case "tuic": node = try tuic(link)
        case "wireguard", "wg", "awg": node = try wireguard(link)
        case "socks", "socks5", "socks4": node = try socks(link, version: scheme == "socks4" ? "4" : "5")
        case "anytls": node = try anytls(link)
        case "naive+https", "naive+quic": node = try naive(link, quic: scheme == "naive+quic")
        case "http-proxy", "https-proxy": node = try httpProxy(link, tls: scheme == "https-proxy")
        default: throw ImportError(CoreText.f("Ссылки «%@://» не поддерживаются.", "\(scheme)"))
        }
        node.link = link
        return node
    }

    // MARK: Helpers

    private static func parts(_ link: String) throws -> LinkParts {
        guard let parts = LinkParts(link) else { throw ImportError(CoreText.t("Ссылка повреждена.")) }
        return parts
    }

    private static func endpoint(_ parts: LinkParts, defaultPort: Int? = nil) throws -> (String, Int) {
        guard !parts.host.isEmpty else { throw ImportError(CoreText.t("В ссылке нет адреса сервера.")) }
        guard let port = parts.port ?? defaultPort, port > 0, port < 65536 else { throw ImportError(CoreText.t("В ссылке нет порта сервера.")) }
        return (parts.host, port)
    }

    private static func name(_ parts: LinkParts, fallback: String) -> String {
        parts.fragment.isEmpty ? fallback : parts.fragment
    }

    /// Stream fields shared by VLESS, Trojan and the URL form of VMess.
    static func stream(from parts: LinkParts, defaultSecurity: String) -> StreamSpec {
        var spec = StreamSpec()
        spec.network = parts.value("type", "net") ?? "tcp"
        spec.security = parts.value("security") ?? defaultSecurity
        if let host = parts.value("host") { spec.hosts = host.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        spec.path = parts.value("path")
        spec.serviceName = parts.value("serviceName", "servicename")
        spec.mode = parts.value("mode")
        spec.headerType = parts.value("headerType", "headertype")
        spec.sni = parts.value("sni", "peer", "servername")
        if let alpn = parts.value("alpn") { spec.alpn = alpn.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        spec.fingerprint = parts.value("fp", "fingerprint")
        spec.allowInsecure = parts.flag("allowInsecure", "allowinsecure", "insecure", "allow_insecure")
        spec.pinnedCertificates = CertificatePins.hex(parts.value("pcs", "pinnedPeerCertSha256", "pinSHA256"))
        spec.realityPublicKey = parts.value("pbk", "publicKey")
        spec.realityShortID = parts.value("sid", "shortId")
        if let extra = parts.value("extra"), let value = try? JSONValue.parse(extra) { spec.xhttpExtra = value }
        if let early = parts.value("ed"), let value = Int(early) { spec.earlyData = value }
        if let header = parts.value("eh") { spec.earlyDataHeader = header }
        return spec
    }

    // MARK: VLESS

    static func vless(_ link: String) throws -> ParsedNode {
        let parts = try parts(link)
        let (host, port) = try endpoint(parts)
        let uuid = TextCoding.percentDecode(parts.userInfo ?? "")
        guard !uuid.isEmpty else { throw ImportError(CoreText.t("VLESS: в ссылке нет идентификатора пользователя.")) }
        let spec = stream(from: parts, defaultSecurity: "none")
        var outbound: [String: JSONValue] = [
            "type": "vless", "server": .string(host), "server_port": .int(Int64(port)), "uuid": .string(uuid),
            "packet_encoding": "xudp",
        ]
        if var flow = parts.value("flow"), flow != "none" {
            if flow.hasSuffix("-udp443") { flow.removeLast("-udp443".count) }
            outbound["flow"] = .string(flow)
        }
        if let encryption = parts.value("encryption"), encryption != "none" { outbound["encryption"] = .string(encryption) }
        if let tls = try spec.tls(server: host) { outbound["tls"] = tls }
        if let transport = try spec.transport() { outbound["transport"] = transport }
        return ParsedNode(name: name(parts, fallback: host), outbound: .object(outbound))
    }

    // MARK: VMess

    static func vmess(_ link: String) throws -> ParsedNode {
        let body = String(link.dropFirst("vmess://".count))
        let payload = body.split(separator: "#", maxSplits: 1).first.map(String.init) ?? body
        if let decoded = TextCoding.decodeBase64String(payload), let json = try? JSONValue.parse(decoded), json.objectValue != nil {
            return try vmess(json: json)
        }
        // URL form: vmess://uuid@host:port?type=ws&security=tls#name
        let parts = try parts(link)
        let (host, port) = try endpoint(parts)
        let uuid = TextCoding.percentDecode(parts.userInfo ?? "")
        guard !uuid.isEmpty else { throw ImportError(CoreText.t("VMess: ссылка повреждена.")) }
        let spec = stream(from: parts, defaultSecurity: "none")
        var outbound: [String: JSONValue] = [
            "type": "vmess", "server": .string(host), "server_port": .int(Int64(port)), "uuid": .string(uuid),
            "security": .string(parts.value("encryption", "scy") ?? "auto"),
        ]
        if let alterID = parts.value("alterId", "aid").flatMap({ Int($0) }), alterID > 0 { outbound["alter_id"] = .int(Int64(alterID)) }
        if let tls = try spec.tls(server: host) { outbound["tls"] = tls }
        if let transport = try spec.transport() { outbound["transport"] = transport }
        return ParsedNode(name: name(parts, fallback: host), outbound: .object(outbound))
    }

    private static func vmess(json: JSONValue) throws -> ParsedNode {
        guard let host = json["add"]?.text, !host.isEmpty, let port = json["port"]?.looseInt, port > 0 else {
            throw ImportError(CoreText.t("VMess: в ссылке нет адреса или порта."))
        }
        guard let uuid = json["id"]?.text, !uuid.isEmpty else { throw ImportError(CoreText.t("VMess: в ссылке нет идентификатора пользователя.")) }
        var spec = StreamSpec()
        spec.network = json["net"]?.text ?? "tcp"
        spec.headerType = json["type"]?.text
        if let hostHeader = json["host"]?.text, !hostHeader.isEmpty {
            spec.hosts = hostHeader.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        spec.path = json["path"]?.text
        if spec.network == "grpc" { spec.serviceName = json["path"]?.text }
        let tlsValue = json["tls"]?.text?.lowercased() ?? ""
        spec.security = (tlsValue == "tls" || tlsValue == "reality") ? tlsValue : "none"
        spec.sni = json["sni"]?.text
        if let alpn = json["alpn"]?.text, !alpn.isEmpty { spec.alpn = alpn.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        spec.fingerprint = json["fp"]?.text
        spec.allowInsecure = json["allowInsecure"]?.looseBool ?? json["skip-cert-verify"]?.looseBool ?? false
        spec.pinnedCertificates = CertificatePins.hex(json["pcs"]?.text ?? json["pinnedPeerCertSha256"]?.text)
        var outbound: [String: JSONValue] = [
            "type": "vmess", "server": .string(host), "server_port": .int(Int64(port)), "uuid": .string(uuid),
            "security": .string((json["scy"]?.text).flatMap { $0.isEmpty ? nil : $0 } ?? "auto"),
        ]
        if let alterID = json["aid"]?.looseInt, alterID > 0 { outbound["alter_id"] = .int(Int64(alterID)) }
        if let tls = try spec.tls(server: host) { outbound["tls"] = tls }
        if let transport = try spec.transport() { outbound["transport"] = transport }
        let title = json["ps"]?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ParsedNode(name: title.isEmpty ? host : title, outbound: .object(outbound))
    }

    // MARK: Trojan

    static func trojan(_ link: String) throws -> ParsedNode {
        let parts = try parts(link)
        let (host, port) = try endpoint(parts, defaultPort: 443)
        let password = TextCoding.percentDecode(parts.userInfo ?? "")
        guard !password.isEmpty else { throw ImportError(CoreText.t("Trojan: в ссылке нет пароля.")) }
        let spec = stream(from: parts, defaultSecurity: "tls")
        var outbound: [String: JSONValue] = [
            "type": "trojan", "server": .string(host), "server_port": .int(Int64(port)), "password": .string(password),
        ]
        if let tls = try spec.tls(server: host) { outbound["tls"] = tls }
        if let transport = try spec.transport() { outbound["transport"] = transport }
        return ParsedNode(name: name(parts, fallback: host), outbound: .object(outbound))
    }

    // MARK: Shadowsocks

    static func shadowsocks(_ link: String) throws -> ParsedNode {
        var source = link
        let body = link.dropFirst("ss://".count)
        let main = body.prefix { $0 != "#" && $0 != "?" }
        if !main.contains("@") {
            // Old form: ss://base64(method:password@host:port)#name
            guard let decoded = TextCoding.decodeBase64String(String(main)), decoded.contains("@") else {
                throw ImportError(CoreText.t("Shadowsocks: ссылка повреждена."))
            }
            source = "ss://" + decoded + body.dropFirst(main.count)
        }
        let parts = try parts(source)
        let (host, port) = try endpoint(parts)
        let userInfo = TextCoding.percentDecode(parts.userInfo ?? "")
        let pair: String
        if userInfo.contains(":") {
            pair = userInfo
        } else if let decoded = TextCoding.decodeBase64String(userInfo) {
            pair = decoded
        } else {
            throw ImportError(CoreText.t("Shadowsocks: не удалось прочитать метод и пароль."))
        }
        guard let colon = pair.firstIndex(of: ":") else { throw ImportError(CoreText.t("Shadowsocks: не удалось прочитать метод и пароль.")) }
        let method = String(pair[..<colon]).lowercased()
        let password = String(pair[pair.index(after: colon)...])
        guard !method.isEmpty, !password.isEmpty else { throw ImportError(CoreText.t("Shadowsocks: пустой метод или пароль.")) }
        var outbound: [String: JSONValue] = [
            "type": "shadowsocks", "server": .string(host), "server_port": .int(Int64(port)),
            "method": .string(method), "password": .string(password),
        ]
        if let plugin = parts.value("plugin") {
            let pieces = plugin.split(separator: ";", maxSplits: 1).map(String.init)
            var pluginName = pieces[0]
            if pluginName == "simple-obfs" || pluginName == "obfs" { pluginName = "obfs-local" }
            guard pluginName == "obfs-local" || pluginName == "v2ray-plugin" else {
                throw ImportError(CoreText.f("Shadowsocks: плагин «%@» не поддерживается.", "\(pluginName)"))
            }
            outbound["plugin"] = .string(pluginName)
            if pieces.count > 1 { outbound["plugin_opts"] = .string(pieces[1]) }
        }
        return ParsedNode(name: name(parts, fallback: host), outbound: .object(outbound))
    }

    // MARK: Hysteria2

    /// `20000-30000,443` → `["20000:30000", "443:443"]`, the form sing-box takes.
    static func portRanges(_ text: String) -> [String] {
        text.split(separator: ",").compactMap { item in
            let bounds = item.split(whereSeparator: { $0 == "-" || $0 == ":" }).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let first = bounds.first, first > 0, first < 65536 else { return nil }
            let last = bounds.count > 1 ? bounds[1] : first
            guard last >= first, last < 65536 else { return nil }
            return "\(first):\(last)"
        }
    }

    static func hysteria2(_ link: String) throws -> ParsedNode {
        // The port may be a list ("443,20000-30000"), which the generic splitter does not read.
        var normalized = link
        var hopPorts: String?
        if let schemeEnd = link.range(of: "://") {
            let afterScheme = link[schemeEnd.upperBound...]
            let authorityEnd = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? afterScheme.endIndex
            let authority = afterScheme[..<authorityEnd]
            if let colon = authority.lastIndex(of: ":"), !authority.hasSuffix("]") {
                let portText = String(authority[authority.index(after: colon)...])
                if portText.contains(",") || portText.contains("-") {
                    hopPorts = portText
                    let first = portText.split(whereSeparator: { $0 == "," || $0 == "-" }).first.map(String.init) ?? "443"
                    normalized = String(link[..<colon]) + ":" + first + String(link[authorityEnd...])
                }
            }
        }
        let parts = try parts(normalized)
        let (host, port) = try endpoint(parts, defaultPort: 443)
        let password = TextCoding.percentDecode(parts.userInfo ?? "")
        var tls: [String: JSONValue] = ["enabled": true]
        if let sni = parts.value("sni", "peer") { tls["server_name"] = .string(sni) } else if !TextCoding.isIPAddress(host) { tls["server_name"] = .string(host) }
        if parts.flag("insecure", "allowInsecure") { tls["insecure"] = true }
        CertificatePins.apply(certificates: CertificatePins.hex(parts.value("pinSHA256", "pcs")), publicKeys: [], to: &tls)
        if let alpn = parts.value("alpn") { tls["alpn"] = JSONValue(alpn.split(separator: ",").map(String.init)) }
        var outbound: [String: JSONValue] = [
            "type": "hysteria2", "server": .string(host), "server_port": .int(Int64(port)), "tls": .object(tls),
        ]
        if !password.isEmpty { outbound["password"] = .string(password) }
        if let obfs = parts.value("obfs"), obfs != "none" {
            guard obfs == "salamander" || obfs == "gecko" else { throw ImportError(CoreText.f("Hysteria2: обфускация «%@» не поддерживается.", "\(obfs)")) }
            outbound["obfs"] = ["type": .string(obfs), "password": .string(parts.value("obfs-password", "obfsParam") ?? "")]
        }
        if let ranges = (parts.value("mport", "ports") ?? hopPorts).map(portRanges), !ranges.isEmpty {
            outbound["server_ports"] = JSONValue(ranges)
        }
        if let up = parts.value("upmbps", "up").flatMap({ Int($0) }), up > 0 { outbound["up_mbps"] = .int(Int64(up)) }
        if let down = parts.value("downmbps", "down").flatMap({ Int($0) }), down > 0 { outbound["down_mbps"] = .int(Int64(down)) }
        return ParsedNode(name: name(parts, fallback: host), outbound: .object(outbound))
    }

    static func hysteria(_ link: String) throws -> ParsedNode {
        let parts = try parts(link)
        let (host, port) = try endpoint(parts)
        if let proto = parts.value("protocol"), proto != "udp" { throw ImportError(CoreText.f("Hysteria: протокол «%@» не поддерживается.", "\(proto)")) }
        var tls: [String: JSONValue] = ["enabled": true]
        if let sni = parts.value("peer", "sni") { tls["server_name"] = .string(sni) } else if !TextCoding.isIPAddress(host) { tls["server_name"] = .string(host) }
        if parts.flag("insecure", "allowInsecure") { tls["insecure"] = true }
        CertificatePins.apply(certificates: CertificatePins.hex(parts.value("pinSHA256", "pcs")), publicKeys: [], to: &tls)
        if let alpn = parts.value("alpn") { tls["alpn"] = JSONValue(alpn.split(separator: ",").map(String.init)) }
        var outbound: [String: JSONValue] = [
            "type": "hysteria", "server": .string(host), "server_port": .int(Int64(port)), "tls": .object(tls),
            "up_mbps": .int(Int64(parts.value("upmbps").flatMap { Int($0) } ?? 20)),
            "down_mbps": .int(Int64(parts.value("downmbps").flatMap { Int($0) } ?? 100)),
        ]
        if let auth = parts.value("auth") { outbound["auth_str"] = .string(auth) }
        if let obfs = parts.value("obfsParam") { outbound["obfs"] = .string(obfs) }
        return ParsedNode(name: name(parts, fallback: host), outbound: .object(outbound))
    }

    // MARK: TUIC

    static func tuic(_ link: String) throws -> ParsedNode {
        let parts = try parts(link)
        let (host, port) = try endpoint(parts)
        let userInfo = parts.userInfo ?? ""
        let pieces = userInfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map { TextCoding.percentDecode(String($0)) }
        guard let uuid = pieces.first, !uuid.isEmpty else { throw ImportError(CoreText.t("TUIC: в ссылке нет идентификатора пользователя.")) }
        var tls: [String: JSONValue] = ["enabled": true]
        if let sni = parts.value("sni", "peer") { tls["server_name"] = .string(sni) } else if !TextCoding.isIPAddress(host) { tls["server_name"] = .string(host) }
        if parts.flag("allow_insecure", "allowInsecure", "insecure") { tls["insecure"] = true }
        if parts.flag("disable_sni") { tls["disable_sni"] = true }
        CertificatePins.apply(certificates: CertificatePins.hex(parts.value("pinSHA256", "pcs")), publicKeys: [], to: &tls)
        tls["alpn"] = JSONValue((parts.value("alpn") ?? "h3").split(separator: ",").map(String.init))
        var outbound: [String: JSONValue] = [
            "type": "tuic", "server": .string(host), "server_port": .int(Int64(port)), "uuid": .string(uuid), "tls": .object(tls),
        ]
        if pieces.count > 1, !pieces[1].isEmpty { outbound["password"] = .string(pieces[1]) } else if let password = parts.value("password") {
            outbound["password"] = .string(password)
        }
        if let control = parts.value("congestion_control", "congestion-control"), ["cubic", "new_reno", "bbr"].contains(control) {
            outbound["congestion_control"] = .string(control)
        }
        if let mode = parts.value("udp_relay_mode", "udp-relay-mode"), ["native", "quic"].contains(mode) {
            outbound["udp_relay_mode"] = .string(mode)
        }
        return ParsedNode(name: name(parts, fallback: host), outbound: .object(outbound))
    }

    // MARK: WireGuard / AmneziaWG

    static let awgNumbers = ["jc", "jmin", "jmax", "s1", "s2", "s3", "s4"]
    static let awgTexts = ["h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5"]

    static func wireguard(_ link: String) throws -> ParsedNode {
        let parts = try parts(link)
        let (host, port) = try endpoint(parts, defaultPort: 51820)
        let privateKey = TextCoding.percentDecode(parts.userInfo ?? parts.value("privatekey", "private_key") ?? "")
        guard !privateKey.isEmpty else { throw ImportError(CoreText.t("WireGuard: в ссылке нет закрытого ключа.")) }
        guard let publicKey = parts.value("publickey", "public_key", "peer") else { throw ImportError(CoreText.t("WireGuard: в ссылке нет открытого ключа сервера.")) }
        let addresses = (parts.value("address", "ip") ?? "10.0.0.2/32").split(separator: ",").map { item -> String in
            let text = item.trimmingCharacters(in: .whitespaces)
            return text.contains("/") ? text : text + (text.contains(":") ? "/128" : "/32")
        }
        var peer: [String: JSONValue] = [
            "address": .string(host), "port": .int(Int64(port)), "public_key": .string(publicKey),
            "allowed_ips": JSONValue((parts.value("allowedips", "allowed_ips") ?? "0.0.0.0/0,::/0").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }),
        ]
        if let key = parts.value("presharedkey", "pre_shared_key", "psk") { peer["pre_shared_key"] = .string(key) }
        if let keepalive = parts.value("keepalive", "persistent_keepalive").flatMap({ Int($0) }), keepalive > 0 {
            peer["persistent_keepalive_interval"] = .int(Int64(keepalive))
        }
        if let reserved = parts.value("reserved") {
            let bytes = reserved.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if bytes.count == 3, bytes.allSatisfy({ (0 ... 255).contains($0) }) { peer["reserved"] = .array(bytes.map { .int(Int64($0)) }) }
        }
        var endpoint: [String: JSONValue] = [
            "type": "wireguard", "address": JSONValue(addresses), "private_key": .string(privateKey), "peers": [.object(peer)],
        ]
        if let mtu = parts.value("mtu").flatMap({ Int($0) }), mtu >= 576 { endpoint["mtu"] = .int(Int64(mtu)) }
        for key in awgNumbers {
            if let value = parts.value(key, key.uppercased()).flatMap({ Int($0) }) { endpoint[key] = .int(Int64(value)) }
        }
        for key in awgTexts {
            if let value = parts.value(key, key.uppercased()) { endpoint[key] = Int(value).map { JSONValue.int(Int64($0)) } ?? .string(value) }
        }
        return ParsedNode(name: name(parts, fallback: host), outbound: .object(endpoint))
    }

    // MARK: Simple proxies

    private static func credentials(_ parts: LinkParts) -> (String, String)? {
        guard let info = parts.userInfo, !info.isEmpty else { return nil }
        let text = info.contains(":") ? info : (TextCoding.decodeBase64String(info) ?? info)
        let pieces = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map { TextCoding.percentDecode(String($0)) }
        return (pieces[0], pieces.count > 1 ? pieces[1] : "")
    }

    static func socks(_ link: String, version: String) throws -> ParsedNode {
        let parts = try parts(link)
        let (host, port) = try endpoint(parts, defaultPort: 1080)
        var outbound: [String: JSONValue] = ["type": "socks", "server": .string(host), "server_port": .int(Int64(port)), "version": .string(version)]
        if let (user, password) = credentials(parts), !user.isEmpty {
            outbound["username"] = .string(user)
            outbound["password"] = .string(password)
        }
        return ParsedNode(name: name(parts, fallback: host), outbound: .object(outbound))
    }

    static func httpProxy(_ link: String, tls: Bool) throws -> ParsedNode {
        let parts = try parts(link)
        let (host, port) = try endpoint(parts, defaultPort: tls ? 443 : 8080)
        var outbound: [String: JSONValue] = ["type": "http", "server": .string(host), "server_port": .int(Int64(port))]
        if let (user, password) = credentials(parts), !user.isEmpty {
            outbound["username"] = .string(user)
            outbound["password"] = .string(password)
        }
        if tls {
            var options: [String: JSONValue] = ["enabled": true]
            if !TextCoding.isIPAddress(host) { options["server_name"] = .string(parts.value("sni") ?? host) }
            outbound["tls"] = .object(options)
        }
        return ParsedNode(name: name(parts, fallback: host), outbound: .object(outbound))
    }

    static func anytls(_ link: String) throws -> ParsedNode {
        let parts = try parts(link)
        let (host, port) = try endpoint(parts, defaultPort: 443)
        let password = TextCoding.percentDecode(parts.userInfo ?? "")
        guard !password.isEmpty else { throw ImportError(CoreText.t("AnyTLS: в ссылке нет пароля.")) }
        var spec = stream(from: parts, defaultSecurity: "tls")
        spec.network = "tcp"
        var outbound: [String: JSONValue] = [
            "type": "anytls", "server": .string(host), "server_port": .int(Int64(port)), "password": .string(password),
        ]
        if let tls = try spec.tls(server: host, required: true) { outbound["tls"] = tls }
        return ParsedNode(name: name(parts, fallback: host), outbound: .object(outbound))
    }

    static func naive(_ link: String, quic: Bool) throws -> ParsedNode {
        let parts = try parts(link)
        let (host, port) = try endpoint(parts, defaultPort: 443)
        var outbound: [String: JSONValue] = ["type": "naive", "server": .string(host), "server_port": .int(Int64(port))]
        if let (user, password) = credentials(parts) {
            outbound["username"] = .string(user)
            outbound["password"] = .string(password)
        }
        var tls: [String: JSONValue] = ["enabled": true]
        if !TextCoding.isIPAddress(host) { tls["server_name"] = .string(parts.value("sni") ?? host) }
        outbound["tls"] = .object(tls)
        if quic { outbound["quic"] = true }
        return ParsedNode(name: name(parts, fallback: host), outbound: .object(outbound))
    }
}
