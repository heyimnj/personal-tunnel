import Foundation

/// A server that was skipped during import, with the reason shown to the user.
public struct ImportIssue: Hashable, Sendable, Codable {
    public var name: String
    public var reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }
}

/// Xray JSON (what Remnawave and Happ serve to clients that send a HWID) →
/// sing-box outbounds. One Xray config is one server; several proxy outbounds in
/// one config (a balancer) become one server backed by a `urltest` group.
public enum XrayImport {
    static let proxyProtocols: Set<String> = [
        "vless", "vmess", "trojan", "shadowsocks", "socks", "http", "wireguard", "hysteria", "hysteria2",
    ]

    public static func isXray(_ document: JSONValue) -> Bool {
        let first = document.arrayValue?.first ?? document
        guard let outbounds = first["outbounds"]?.arrayValue else { return false }
        return outbounds.contains { $0["protocol"]?.stringValue != nil }
    }

    public static func parse(_ document: JSONValue) -> (nodes: [ParsedNode], issues: [ImportIssue]) {
        var nodes: [ParsedNode] = []
        var issues: [ImportIssue] = []
        for (offset, config) in document.listValue.enumerated() {
            let title = config["remarks"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (title?.isEmpty == false ? title : nil) ?? "Сервер \(offset + 1)"
            do {
                nodes.append(try node(from: config, name: name))
            } catch {
                // What sing-box cannot run, Xray-core can: the server keeps its own outbounds.
                if let backed = XrayBacked.node(config: config, name: name) {
                    nodes.append(backed)
                } else {
                    issues.append(ImportIssue(name: name, reason: (error as? ImportError)?.message ?? error.localizedDescription))
                }
            }
        }
        return (nodes, issues)
    }

    static func node(from config: JSONValue, name: String) throws -> ParsedNode {
        let proxies = (config["outbounds"]?.arrayValue ?? []).filter {
            proxyProtocols.contains($0["protocol"]?.stringValue?.lowercased() ?? "")
        }
        guard !proxies.isEmpty else { throw ImportError(CoreText.t("В конфигурации Xray нет прокси-сервера.")) }

        // Convert every proxy; a chain (`dialerProxy`) becomes a sing-box `detour`.
        var converted: [(tag: String, object: JSONValue, dialer: String?)] = []
        var firstError: Error?
        for (index, proxy) in proxies.enumerated() {
            do {
                let object = try outbound(from: proxy)
                let tag = proxy["tag"]?.stringValue ?? "proxy-\(index)"
                let dialer = proxy.at("streamSettings", "sockopt", "dialerProxy")?.stringValue
                converted.append((tag, object, dialer?.isEmpty == false ? dialer : nil))
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        guard !converted.isEmpty else { throw firstError ?? ImportError(CoreText.t("Сервер не удалось преобразовать.")) }
        // A hop sing-box cannot run (a chain's exit, say): the whole server goes to Xray-core.
        if let firstError { throw firstError }

        let placeholders = Dictionary(converted.enumerated().map { ($1.tag, "#\($0)") }, uniquingKeysWith: { first, _ in first })
        var detourTargets = Set<String>()
        var objects: [JSONValue] = []
        for (index, item) in converted.enumerated() {
            var object = item.object
            object["tag"] = .string("#\(index)")
            if let dialer = item.dialer, let target = placeholders[dialer], target != "#\(index)" {
                object["detour"] = .string(target)
                detourTargets.insert(target)
            }
            objects.append(object)
        }
        let heads = objects.filter { !detourTargets.contains($0["tag"]?.stringValue ?? "") }
        if heads.count == 1, let head = heads.first {
            var main = head
            let headTag = main["tag"]?.stringValue ?? ""
            main["tag"] = nil
            let members = objects.filter { $0["tag"]?.stringValue != headTag }
            return ParsedNode(name: name, outbound: main, members: members)
        }
        let group: JSONValue = [
            "type": "urltest",
            "outbounds": JSONValue(heads.compactMap { $0["tag"]?.stringValue }),
            "url": "https://www.gstatic.com/generate_204",
            "interval": "3m",
            "tolerance": 150,
            "idle_timeout": "30m",
        ]
        return ParsedNode(name: name, outbound: group, members: objects)
    }

    // MARK: One outbound

    private static func firstUserAndServer(_ settings: JSONValue, list: String) -> (server: JSONValue, user: JSONValue) {
        if let server = settings[list]?.arrayValue?.first {
            return (server, server["users"]?.arrayValue?.first ?? server)
        }
        // Xray 25+ flat form: the fields sit in `settings` itself.
        return (settings, settings)
    }

    static func outbound(from xray: JSONValue) throws -> JSONValue {
        let kind = xray["protocol"]?.stringValue?.lowercased() ?? ""
        let settings = xray["settings"] ?? .object([:])
        let stream = xray["streamSettings"] ?? .object([:])
        if kind == "hysteria" || kind == "hysteria2" { return try hysteria(xray, settings: settings, stream: stream) }
        if kind == "wireguard" { return try wireguard(settings) }

        let listName = (kind == "vless" || kind == "vmess") ? "vnext" : "servers"
        let (server, user) = firstUserAndServer(settings, list: listName)
        guard let host = server["address"]?.text, !host.isEmpty else { throw ImportError(CoreText.t("В конфигурации Xray нет адреса сервера.")) }
        guard let port = server["port"]?.looseInt, port > 0, port < 65536 else { throw ImportError(CoreText.t("В конфигурации Xray нет порта сервера.")) }
        if ["0.0.0.0", "127.0.0.1", "localhost", "::1"].contains(host.lowercased()) {
            throw ImportError(CoreText.f("Адрес сервера не настоящий (%@): провайдер вернул заглушку.", "\(host)"))
        }
        var outbound: [String: JSONValue] = ["server": .string(host), "server_port": .int(Int64(port))]
        let spec = try streamSpec(stream)

        switch kind {
        case "vless":
            guard let uuid = user["id"]?.text, !uuid.isEmpty else { throw ImportError(CoreText.t("VLESS: нет идентификатора пользователя.")) }
            outbound["type"] = "vless"
            outbound["uuid"] = .string(uuid)
            outbound["packet_encoding"] = "xudp"
            if var flow = user["flow"]?.stringValue, !flow.isEmpty, flow != "none" {
                if flow.hasSuffix("-udp443") { flow.removeLast("-udp443".count) }
                outbound["flow"] = .string(flow)
            }
            if let encryption = user["encryption"]?.stringValue, !encryption.isEmpty, encryption != "none" {
                outbound["encryption"] = .string(encryption)
            }
        case "vmess":
            guard let uuid = user["id"]?.text, !uuid.isEmpty else { throw ImportError(CoreText.t("VMess: нет идентификатора пользователя.")) }
            outbound["type"] = "vmess"
            outbound["uuid"] = .string(uuid)
            outbound["security"] = .string((user["security"]?.stringValue).flatMap { $0.isEmpty ? nil : $0 } ?? "auto")
            if let alterID = user["alterId"]?.looseInt, alterID > 0 { outbound["alter_id"] = .int(Int64(alterID)) }
        case "trojan":
            guard let password = server["password"]?.text, !password.isEmpty else { throw ImportError(CoreText.t("Trojan: нет пароля.")) }
            outbound["type"] = "trojan"
            outbound["password"] = .string(password)
        case "shadowsocks":
            guard let method = server["method"]?.stringValue, let password = server["password"]?.text, !method.isEmpty else {
                throw ImportError(CoreText.t("Shadowsocks: нет метода или пароля."))
            }
            outbound["type"] = "shadowsocks"
            outbound["method"] = .string(method.lowercased())
            outbound["password"] = .string(password)
            return .object(outbound)
        case "socks", "http":
            outbound["type"] = .string(kind)
            if kind == "socks" { outbound["version"] = "5" }
            if let name = user["user"]?.text, !name.isEmpty {
                outbound["username"] = .string(name)
                outbound["password"] = .string(user["pass"]?.text ?? "")
            }
            if kind == "http", let tls = try spec.tls(server: host) { outbound["tls"] = tls }
            return .object(outbound)
        default:
            throw ImportError(CoreText.f("Протокол «%@» не поддерживается.", "\(kind)"))
        }
        if let tls = try spec.tls(server: host, required: kind == "trojan" && spec.security == "none" && stream["security"] == nil) {
            outbound["tls"] = tls
        }
        if let transport = try spec.transport() { outbound["transport"] = transport }
        return .object(outbound)
    }

    /// `pinnedPeerCertSha256`: hex hashes, one string with commas or a list.
    static func certificatePins(_ tlsSettings: JSONValue) -> [String] {
        guard let value = tlsSettings["pinnedPeerCertSha256"] else { return [] }
        if let list = value.arrayValue { return CertificatePins.hex(list.compactMap(\.text)) }
        return CertificatePins.hex(value.text.map { [$0] } ?? [])
    }

    static func streamSpec(_ stream: JSONValue) throws -> StreamSpec {
        var spec = StreamSpec()
        spec.network = stream["network"]?.stringValue?.lowercased() ?? "tcp"
        spec.security = stream["security"]?.stringValue?.lowercased() ?? "none"
        if let tls = stream["tlsSettings"] {
            spec.sni = tls["serverName"]?.stringValue
            spec.allowInsecure = tls["allowInsecure"]?.looseBool ?? false
            spec.pinnedCertificates = Self.certificatePins(tls)
            spec.pinnedPublicKeys = CertificatePins.publicKeys(tls["pinnedPeerCertificatePublicKeySha256"]?.stringList ?? [])
            spec.alpn = tls["alpn"]?.stringList ?? []
            spec.fingerprint = tls["fingerprint"]?.stringValue
        }
        if spec.security == "reality", let reality = stream["realitySettings"] {
            spec.sni = reality["serverName"]?.stringValue ?? spec.sni
            spec.realityPublicKey = reality["publicKey"]?.stringValue ?? reality["password"]?.stringValue
            spec.realityShortID = reality["shortId"]?.stringValue
            spec.fingerprint = reality["fingerprint"]?.stringValue ?? spec.fingerprint
        }
        func headers(_ value: JSONValue?) -> [String: String] {
            var result: [String: String] = [:]
            for (key, item) in value?.objectValue ?? [:] {
                if let text = item.text ?? item.arrayValue?.first?.text { result[key] = text }
            }
            return result
        }
        func adoptHost(from fields: inout [String: String]) {
            if let key = fields.keys.first(where: { $0.lowercased() == "host" }), let host = fields.removeValue(forKey: key), spec.hosts.isEmpty {
                spec.hosts = [host]
            }
        }
        switch spec.network {
        case "ws", "websocket":
            let ws = stream["wsSettings"]
            spec.path = ws?["path"]?.stringValue
            if let host = ws?["host"]?.stringValue, !host.isEmpty { spec.hosts = [host] }
            var fields = headers(ws?["headers"])
            adoptHost(from: &fields)
            spec.headers = fields
            if let early = ws?["maxEarlyData"]?.looseInt { spec.earlyData = early }
            if let header = ws?["earlyDataHeaderName"]?.stringValue { spec.earlyDataHeader = header }
        case "grpc", "gun":
            spec.serviceName = stream.at("grpcSettings", "serviceName")?.stringValue
        case "httpupgrade":
            let upgrade = stream["httpupgradeSettings"]
            spec.path = upgrade?["path"]?.stringValue
            if let host = upgrade?["host"]?.stringValue, !host.isEmpty { spec.hosts = [host] }
            var fields = headers(upgrade?["headers"])
            adoptHost(from: &fields)
            spec.headers = fields
        case "xhttp", "splithttp":
            let xhttp = stream["xhttpSettings"] ?? stream["splithttpSettings"] ?? .object([:])
            spec.path = xhttp["path"]?.stringValue
            if let host = xhttp["host"]?.stringValue, !host.isEmpty { spec.hosts = [host] }
            spec.mode = xhttp["mode"]?.stringValue
            // Tuning fields come either inside `extra` or next to `path`.
            var extra = xhttp["extra"]?.objectValue ?? [:]
            for (key, value) in xhttp.objectValue ?? [:] where !["path", "host", "mode", "extra"].contains(key) && extra[key] == nil {
                extra[key] = value
            }
            if extra["downloadSettings"] != nil {
                throw ImportError(CoreText.t("XHTTP с отдельным каналом загрузки (downloadSettings) не поддерживается ядром."))
            }
            spec.xhttpExtra = .object(extra)
        case "h2", "http":
            let http = stream["httpSettings"]
            spec.hosts = http?["host"]?.stringList ?? []
            spec.path = http?["path"]?.stringValue
        case "tcp", "raw":
            let header = (stream["tcpSettings"] ?? stream["rawSettings"])?["header"]
            if header?["type"]?.stringValue == "http" {
                spec.headerType = "http"
                spec.path = header?.at("request", "path")?.stringList.first
                spec.hosts = header?.at("request", "headers", "Host")?.stringList ?? []
            }
        default:
            break
        }
        if let mask = stream["finalmask"]?.objectValue, !mask.isEmpty {
            try applyFinalmask(mask, to: &spec)
        }
        return spec
    }

    /// Xray's `finalmask` outside Hysteria. Masks that only the client applies are
    /// kept where the core has them and dropped otherwise, since the server never
    /// sees them: `fragment` (split ClientHello) becomes `tls.fragment`, `noise`
    /// is left out, and UDP masks and QUIC parameters do not touch a TCP transport.
    /// A mask the server must undo cannot be served by sing-box: such a server is
    /// skipped, with the mask named.
    static let clientMasks: Set<String> = ["fragment", "noise"]

    static func applyFinalmask(_ mask: [String: JSONValue], to spec: inout StreamSpec) throws {
        func types(_ key: String) -> [String] {
            (mask[key]?.arrayValue ?? (mask[key].map { [$0] } ?? [])).compactMap { $0["type"]?.stringValue?.lowercased() }
        }
        for type in types("tcp") {
            guard clientMasks.contains(type) else {
                throw ImportError(CoreText.f("Маскировка finalmask «%@» не поддерживается ядром sing-box.", type))
            }
            if type == "fragment" { spec.tlsFragment = true }
        }
        let udpTransport = ["quic", "kcp", "mkcp"].contains(spec.network.lowercased())
        if udpTransport {
            for type in types("udp") where !clientMasks.contains(type) {
                throw ImportError(CoreText.f("Маскировка finalmask «%@» не поддерживается ядром sing-box.", type))
            }
        }
    }

    // MARK: Hysteria (Xray 26 layout)

    private static func megabits(_ value: JSONValue?) -> Int? {
        guard let value else { return nil }
        if let number = value.intValue { return number > 0 ? number : nil }
        guard let text = value.stringValue?.lowercased().trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let digits = text.prefix { $0.isNumber || $0 == "." }
        guard let amount = Double(digits), amount > 0 else { return nil }
        let unit = text.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        if unit.hasPrefix("g") { return Int(amount * 1000) }
        if unit.hasPrefix("k") { return max(1, Int(amount / 1000)) }
        return Int(amount)
    }

    private static func duration(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let seconds = value.intValue { return seconds > 0 ? "\(seconds)s" : nil }
        guard let text = value.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text.last?.isNumber == true ? text + "s" : text
    }

    static func hysteria(_ xray: JSONValue, settings: JSONValue, stream: JSONValue) throws -> JSONValue {
        let hy = stream["hysteriaSettings"] ?? .object([:])
        guard let host = settings["address"]?.text, !host.isEmpty, let port = settings["port"]?.looseInt, port > 0 else {
            throw ImportError(CoreText.t("Hysteria: нет адреса или порта сервера."))
        }
        let version = settings["version"]?.looseInt ?? hy["version"]?.looseInt ?? (xray["protocol"]?.stringValue == "hysteria2" ? 2 : 1)
        let isV2 = version >= 2
        let auth = hy["auth"]?.text ?? hy["password"]?.text ?? settings["auth"]?.text ?? settings["password"]?.text

        var obfsType: String?
        var obfsPassword: String?
        var packetSize: (Int, Int)?
        var hopPorts: [String] = []
        var hopInterval: String?
        var up = megabits(hy["up"])
        var down = megabits(hy["down"])

        let mask = stream["finalmask"] ?? .object([:])
        for item in mask["udp"]?.arrayValue ?? [] {
            let type = item["type"]?.stringValue?.lowercased() ?? ""
            let options = item["settings"] ?? .object([:])
            switch type {
            case "salamander", "gecko":
                guard obfsType == nil else { throw ImportError(CoreText.t("Hysteria: два слоя обфускации не поддерживаются.")) }
                obfsType = type
                obfsPassword = options["password"]?.text
                if let range = (options["packetSize"] ?? options["packet_size"]).flatMap(XHTTPOptions.range) {
                    let bounds = range.split(separator: "-").compactMap { Int($0) }
                    if let low = bounds.first { packetSize = (low, bounds.count > 1 ? bounds[1] : low); obfsType = "gecko" }
                }
            case "udphop":
                if options["mode"]?.stringValue?.lowercased().contains("perconnremote") == true {
                    throw ImportError(CoreText.t("Hysteria: смена адресов сервера не поддерживается."))
                }
                if let ports = (options["remotePorts"] ?? options["ports"])?.text { hopPorts = ShareLink.portRanges(ports) }
                hopInterval = duration(options["interval"]) ?? hopInterval
            case "":
                continue
            default:
                throw ImportError(CoreText.f("Hysteria: маска «%@» не поддерживается ядром.", "\(type)"))
            }
        }
        if let quic = mask["quicParams"] {
            if let hop = quic["udpHop"] {
                if let ports = (hop["ports"] ?? hop["port"])?.text { hopPorts = ShareLink.portRanges(ports) }
                hopInterval = duration(hop["interval"]) ?? hopInterval
            }
            let congestion = quic["congestion"]?.stringValue?.lowercased() ?? ""
            if congestion.isEmpty || congestion.contains("brutal") {
                up = megabits(quic["brutalUp"]) ?? up
                down = megabits(quic["brutalDown"]) ?? down
            }
        }
        if hopPorts.isEmpty, let hop = hy["udphop"] ?? hy["udpHop"], let ports = (hop["port"] ?? hop["ports"])?.text {
            hopPorts = ShareLink.portRanges(ports)
            hopInterval = duration(hop["interval"]) ?? hopInterval
        }
        if obfsType == nil, let legacy = hy["obfs"]?.stringValue?.lowercased(), !legacy.isEmpty { obfsType = legacy }
        obfsPassword = obfsPassword ?? hy["obfsPassword"]?.text ?? hy["obfs_password"]?.text

        let tlsSettings = stream["tlsSettings"] ?? .object([:])
        var tls: [String: JSONValue] = ["enabled": true]
        if let sni = tlsSettings["serverName"]?.stringValue, !sni.isEmpty {
            tls["server_name"] = .string(sni)
        } else if !TextCoding.isIPAddress(host) {
            tls["server_name"] = .string(host)
        }
        if tlsSettings["allowInsecure"]?.looseBool == true { tls["insecure"] = true }
        CertificatePins.apply(certificates: certificatePins(tlsSettings),
                              publicKeys: CertificatePins.publicKeys(tlsSettings["pinnedPeerCertificatePublicKeySha256"]?.stringList ?? []), to: &tls)
        let alpn = tlsSettings["alpn"]?.stringList ?? []
        if !alpn.isEmpty { tls["alpn"] = JSONValue(alpn) }

        var outbound: [String: JSONValue] = [
            "type": .string(isV2 ? "hysteria2" : "hysteria"), "server": .string(host), "server_port": .int(Int64(port)), "tls": .object(tls),
        ]
        if let auth, !auth.isEmpty { outbound[isV2 ? "password" : "auth_str"] = .string(auth) }
        if let up { outbound["up_mbps"] = .int(Int64(up)) }
        if let down { outbound["down_mbps"] = .int(Int64(down)) }
        if !isV2 {
            outbound["up_mbps"] = outbound["up_mbps"] ?? 20
            outbound["down_mbps"] = outbound["down_mbps"] ?? 100
        }
        if !hopPorts.isEmpty { outbound["server_ports"] = JSONValue(hopPorts) }
        if let hopInterval, !hopPorts.isEmpty { outbound["hop_interval"] = .string(hopInterval) }
        if let obfsType, !obfsType.isEmpty {
            if isV2 {
                guard obfsType == "salamander" || obfsType == "gecko" else {
                    throw ImportError(CoreText.f("Hysteria2: обфускация «%@» не поддерживается.", "\(obfsType)"))
                }
                var object: [String: JSONValue] = ["type": .string(obfsType), "password": .string(obfsPassword ?? "")]
                if obfsType == "gecko", let packetSize {
                    object["min_packet_size"] = .int(Int64(packetSize.0))
                    object["max_packet_size"] = .int(Int64(packetSize.1))
                }
                outbound["obfs"] = .object(object)
            } else if let obfsPassword, !obfsPassword.isEmpty {
                outbound["obfs"] = .string(obfsPassword)
            }
        }
        return .object(outbound)
    }

    // MARK: WireGuard

    static func wireguard(_ settings: JSONValue) throws -> JSONValue {
        guard let key = settings["secretKey"]?.stringValue, !key.isEmpty else { throw ImportError(CoreText.t("WireGuard: нет закрытого ключа.")) }
        guard let peer = settings["peers"]?.arrayValue?.first, let publicKey = peer["publicKey"]?.stringValue,
              let endpoint = peer["endpoint"]?.stringValue, let parts = LinkParts("wg://" + endpoint), let port = parts.port
        else { throw ImportError(CoreText.t("WireGuard: нет адреса или ключа сервера.")) }
        let addresses = (settings["address"]?.stringList ?? ["10.0.0.2/32"]).map { text in
            text.contains("/") ? text : text + (text.contains(":") ? "/128" : "/32")
        }
        var peerObject: [String: JSONValue] = [
            "address": .string(parts.host), "port": .int(Int64(port)), "public_key": .string(publicKey),
            "allowed_ips": JSONValue(peer["allowedIPs"]?.stringList.isEmpty == false ? peer["allowedIPs"]!.stringList : ["0.0.0.0/0", "::/0"]),
        ]
        if let shared = peer["preSharedKey"]?.stringValue, !shared.isEmpty { peerObject["pre_shared_key"] = .string(shared) }
        if let keepalive = peer["keepAlive"]?.looseInt, keepalive > 0 { peerObject["persistent_keepalive_interval"] = .int(Int64(keepalive)) }
        if let reserved = settings["reserved"]?.arrayValue, reserved.count == 3 { peerObject["reserved"] = .array(reserved) }
        var endpointObject: [String: JSONValue] = [
            "type": "wireguard", "address": JSONValue(addresses), "private_key": .string(key), "peers": [.object(peerObject)],
        ]
        if let mtu = settings["mtu"]?.looseInt, mtu >= 576 { endpointObject["mtu"] = .int(Int64(mtu)) }
        return .object(endpointObject)
    }
}
