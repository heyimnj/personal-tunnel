import Foundation

/// Reads Xray JSON: a full configuration, an array of them (Remnawave / Happ
/// `XRAY_JSON` subscriptions) or a bare outbound.
enum XrayImporter {
    static let proxyProtocols: Set<String> = [
        "vless", "vmess", "trojan", "shadowsocks", "hysteria", "hysteria2", "wireguard", "socks", "http",
    ]

    static func looksLikeXray(_ json: JSON) -> Bool {
        func isXrayConfig(_ value: JSON) -> Bool {
            if let outbounds = value["outbounds"]?.array {
                return outbounds.contains { $0["protocol"] != nil }
            }
            return value["protocol"] != nil && (value["settings"] != nil || value["streamSettings"] != nil)
        }
        if let array = json.array { return array.contains(where: isXrayConfig) }
        return isXrayConfig(json)
    }

    static func importServers(_ json: JSON) -> ([ImportedServer], [SkippedEntry]) {
        let configs: [JSON] = json.array ?? [json]
        var servers: [ImportedServer] = []
        var skipped: [SkippedEntry] = []
        for (configIndex, config) in configs.enumerated() {
            let outbounds: [JSON]
            if let list = config["outbounds"]?.array {
                outbounds = list
            } else if config["protocol"] != nil {
                outbounds = [config]
            } else {
                continue
            }
            let remarks = config["remarks"]?.text ?? config["ps"]?.text
            let candidates = outbounds.filter { proxyProtocols.contains($0["protocol"]?.text?.lowercased() ?? "") }
            // Prefer the outbound the routing sends traffic to ("proxy"); otherwise the first proxy.
            let primary = candidates.first { $0["tag"]?.text == "proxy" } ?? candidates.first
            guard let outbound = primary else {
                if let protocolName = outbounds.compactMap({ $0["protocol"]?.text }).first(where: { !["freedom", "blackhole", "dns", "loopback"].contains($0) }) {
                    skipped.append(SkippedEntry(name: remarks ?? "Xray \(configIndex + 1)", reason: ImportError.unsupportedProtocol(protocolName).description))
                }
                continue
            }
            let name = remarks ?? outbound["tag"]?.text ?? "Xray \(configIndex + 1)"
            do {
                if let dialer = outbound["streamSettings"]?["sockopt"]?["dialerProxy"]?.text, !dialer.isEmpty {
                    throw ImportError.unsupportedOption("цепочка через dialerProxy «\(dialer)»")
                }
                servers.append(ImportedServer(name: name, outbound: try convert(outbound)))
            } catch {
                skipped.append(SkippedEntry(name: name, reason: String(describing: error)))
            }
        }
        return (servers, skipped)
    }

    // MARK: Outbound

    static func convert(_ outbound: JSON) throws -> JSON {
        let protocolName = outbound["protocol"]?.text?.lowercased() ?? ""
        let settings = outbound["settings"] ?? .object([:])
        let streamSettings = outbound["streamSettings"] ?? .object([:])
        switch protocolName {
        case "vless", "vmess":
            let (address, port, user) = try vnext(settings)
            var object: [String: JSON] = [
                "type": .string(protocolName), "server": .string(address), "server_port": .int(port),
            ]
            guard let id = user["id"]?.text else { throw ImportError.missingField("id") }
            object["uuid"] = .string(id)
            if protocolName == "vless" {
                if let flow = try ShareLinkParser.normalizedFlow(user["flow"]?.text) { object["flow"] = .string(flow) }
                if let encryption = user["encryption"]?.text, encryption != "none" { object["encryption"] = .string(encryption) }
                object["packet_encoding"] = "xudp"
            } else {
                object["security"] = .string(user["security"]?.text ?? "auto")
                object["alter_id"] = .int(user["alterId"]?.int ?? 0)
            }
            try applyStream(streamSettings, to: &object, server: address)
            return .object(object)
        case "trojan", "shadowsocks", "socks", "http":
            let entry = settings["servers"]?[0] ?? settings
            guard let address = entry["address"]?.text else { throw ImportError.missingField("address") }
            guard let port = entry["port"]?.int else { throw ImportError.missingField("port") }
            var object: [String: JSON] = ["server": .string(address), "server_port": .int(port)]
            switch protocolName {
            case "trojan":
                object["type"] = "trojan"
                guard let password = entry["password"]?.text else { throw ImportError.missingField("password") }
                object["password"] = .string(password)
                try applyStream(streamSettings, to: &object, server: address)
            case "shadowsocks":
                object["type"] = "shadowsocks"
                guard let method = entry["method"]?.text?.lowercased() else { throw ImportError.missingField("method") }
                guard ShareLinkParser.shadowsocksMethods.contains(method) else { throw ImportError.unsupportedOption("шифр \(method)") }
                object["method"] = .string(method)
                object["password"] = .string(entry["password"]?.string ?? "")
                if entry["uot"]?.bool == true { object["udp_over_tcp"] = ["enabled": true, "version": 2] }
            default:
                object["type"] = .string(protocolName)
                if let user = entry["users"]?[0] {
                    if let name = user["user"]?.text { object["username"] = .string(name) }
                    if let pass = user["pass"]?.string { object["password"] = .string(pass) }
                }
                if protocolName == "http" {
                    try applyStream(streamSettings, to: &object, server: address)
                    object["transport"] = nil
                }
            }
            return .object(object)
        case "hysteria", "hysteria2":
            return try hysteria(protocolName, settings: settings, stream: streamSettings)
        case "wireguard":
            return try wireguard(settings)
        default:
            throw ImportError.unsupportedProtocol(protocolName)
        }
    }

    private static func vnext(_ settings: JSON) throws -> (String, Int, JSON) {
        if let server = settings["vnext"]?[0] {
            guard let address = server["address"]?.text else { throw ImportError.missingField("address") }
            guard let port = server["port"]?.int else { throw ImportError.missingField("port") }
            return (address, port, server["users"]?[0] ?? .object([:]))
        }
        // Xray 25+ flat form.
        guard let address = settings["address"]?.text else { throw ImportError.missingField("address") }
        guard let port = settings["port"]?.int else { throw ImportError.missingField("port") }
        return (address, port, settings)
    }

    // MARK: Stream settings

    static func streamSettings(_ stream: JSON) -> StreamSettings {
        var result = StreamSettings()
        result.network = stream["network"]?.text?.lowercased() ?? "tcp"
        result.security = stream["security"]?.text?.lowercased() ?? "none"
        if let tls = stream["tlsSettings"] {
            result.serverName = tls["serverName"]?.text
            result.alpn = tls["alpn"]?.stringList ?? []
            result.fingerprint = tls["fingerprint"]?.text
            result.insecure = tls["allowInsecure"]?.bool ?? false
            result.echConfig = tls["echConfigList"]?.text
        }
        if let reality = stream["realitySettings"] {
            result.serverName = reality["serverName"]?.text ?? result.serverName
            result.realityPublicKey = reality["publicKey"]?.text ?? reality["password"]?.text
            result.realityShortID = reality["shortId"]?.text
            result.fingerprint = reality["fingerprint"]?.text ?? result.fingerprint
        }
        switch result.network {
        case "ws":
            let ws = stream["wsSettings"]
            result.path = ws?["path"]?.text
            result.host = ws?["host"]?.text
            for (key, value) in ws?["headers"]?.object ?? [:] {
                if key.lowercased() == "host" { result.host = result.host ?? value.text } else if let text = value.string { result.headers[key] = text }
            }
        case "grpc":
            result.serviceName = stream["grpcSettings"]?["serviceName"]?.text
        case "httpupgrade":
            let options = stream["httpupgradeSettings"]
            result.path = options?["path"]?.text
            result.host = options?["host"]?.text
            for (key, value) in options?["headers"]?.object ?? [:] {
                if let text = value.string { result.headers[key] = text }
            }
        case "xhttp", "splithttp":
            let options = stream["xhttpSettings"] ?? stream["splithttpSettings"] ?? .object([:])
            result.path = options["path"]?.text
            result.host = options["host"]?.text
            result.mode = options["mode"]?.text
            var extra = options["extra"]?.object ?? [:]
            for (key, value) in options.object ?? [:] where !["path", "host", "mode", "extra"].contains(key) {
                extra[key] = extra[key] ?? value
            }
            result.xhttpExtra = .object(extra)
        case "h2", "http":
            let options = stream["httpSettings"]
            result.host = options?["host"]?.stringList.joined(separator: ",")
            result.path = options?["path"]?.text
        case "tcp", "raw":
            let header = (stream["tcpSettings"] ?? stream["rawSettings"])?["header"]
            if header?["type"]?.text == "http" {
                result.headerType = "http"
                let request = header?["request"]
                result.path = request?["path"]?.stringList.first
                result.method = request?["method"]?.text
                for (key, value) in request?["headers"]?.object ?? [:] where key.lowercased() == "host" {
                    result.host = value.stringList.joined(separator: ",")
                }
            }
        default:
            break
        }
        return result
    }

    private static func applyStream(_ stream: JSON, to object: inout [String: JSON], server: String) throws {
        let settings = streamSettings(stream)
        if let transport = try settings.transport() { object["transport"] = transport }
        if let tls = settings.tls(defaultServerName: server) { object["tls"] = tls }
    }

    // MARK: Hysteria

    private static func hysteria(_ protocolName: String, settings: JSON, stream: JSON) throws -> JSON {
        let hy = stream["hysteriaSettings"] ?? .object([:])
        let server = settings["servers"]?[0] ?? settings
        guard let address = server["address"]?.text else { throw ImportError.missingField("address") }
        guard let port = server["port"]?.int, (1 ... 65535).contains(port) else { throw ImportError.missingField("port") }
        let version = server["version"]?.int ?? hy["version"]?.int ?? 2
        let authKeys = ["auth", "auth_str", "password"]
        let auth: String? = authKeys.lazy.compactMap { hy[$0]?.text }.first
            ?? authKeys.lazy.compactMap { server[$0]?.text }.first

        var obfsType: String?
        var obfsPassword: String?
        var obfsMin: Int?
        var obfsMax: Int?
        var hopPorts: [String] = []
        var hopInterval: (String, String?)?
        var up: Int?
        var down: Int?

        let finalmask = stream["finalmask"] ?? .object([:])
        for mask in finalmask["udp"]?.array ?? [] {
            let type = mask["type"]?.text?.lowercased() ?? ""
            let options = mask["settings"] ?? .object([:])
            switch type {
            case "salamander", "gecko":
                obfsType = type
                obfsPassword = options["password"]?.text
                obfsMin = options["min_packet_size"]?.int
                obfsMax = options["max_packet_size"]?.int
                if let range = StreamSettings.range(options["packetSize"] ?? options["packet_size"] ?? .null) {
                    let bounds = range.split(separator: "-").compactMap { Int($0) }
                    obfsType = "gecko"
                    obfsMin = bounds.first
                    obfsMax = bounds.last
                }
            case "udphop":
                if (options["mode"]?.text ?? "").lowercased().contains("perconnremote") {
                    throw ImportError.unsupportedOption("udphop perConnRemote")
                }
                hopPorts = ports(options["remotePorts"] ?? options["ports"])
                hopInterval = interval(options["interval"]) ?? hopInterval
            case "":
                continue
            default:
                throw ImportError.unsupportedOption("маска finalmask \(type)")
            }
        }
        if let quic = finalmask["quicParams"] {
            if let hop = quic["udpHop"] {
                let parsed = ports(hop["ports"] ?? hop["port"])
                if !parsed.isEmpty { hopPorts = parsed }
                hopInterval = interval(hop["interval"]) ?? hopInterval
            }
            let congestion = quic["congestion"]?.text?.lowercased() ?? ""
            if congestion.isEmpty || congestion.contains("brutal") {
                up = ShareLinkParser.mbps(quic["brutalUp"]?.string)
                down = ShareLinkParser.mbps(quic["brutalDown"]?.string)
            }
        }
        if let hop = hy["udphop"] ?? hy["udpHop"] {
            if hopPorts.isEmpty { hopPorts = ports(hop["port"] ?? hop["ports"]) }
            if hopInterval == nil { hopInterval = interval(hop["interval"]) }
        }
        up = up ?? ShareLinkParser.mbps(hy["up"]?.string)
        down = down ?? ShareLinkParser.mbps(hy["down"]?.string)
        if obfsType == nil, let type = (hy["obfs"] ?? server["obfs"])?.text?.lowercased(), type != "none" {
            obfsType = type
            obfsPassword = (hy["obfsPassword"] ?? hy["obfs_password"] ?? server["obfsPassword"])?.text
        }

        let tlsSettings = stream["tlsSettings"]
        var tls: [String: JSON] = ["enabled": true]
        if let sni = tlsSettings?["serverName"]?.text {
            tls["server_name"] = .string(sni)
        } else if !StreamSettings.isIPAddress(address) {
            tls["server_name"] = .string(address)
        }
        if tlsSettings?["allowInsecure"]?.bool == true { tls["insecure"] = true }
        let alpn = tlsSettings?["alpn"]?.stringList ?? []
        tls["alpn"] = .strings(alpn.isEmpty ? ["h3"] : alpn)

        var object: [String: JSON] = ["server": .string(address), "server_port": .int(port), "tls": .object(tls)]
        if version >= 2 {
            object["type"] = "hysteria2"
            if let auth { object["password"] = .string(auth) }
            if let obfsType {
                guard obfsType == "salamander" || obfsType == "gecko" else { throw ImportError.unsupportedOption("obfs \(obfsType)") }
                var obfs: [String: JSON] = ["type": .string(obfsType)]
                if let obfsPassword { obfs["password"] = .string(obfsPassword) }
                if obfsType == "gecko" {
                    if let obfsMin { obfs["min_packet_size"] = .int(obfsMin) }
                    if let obfsMax { obfs["max_packet_size"] = .int(obfsMax) }
                }
                object["obfs"] = .object(obfs)
            }
        } else {
            object["type"] = "hysteria"
            if let auth { object["auth_str"] = .string(auth) }
            guard up != nil, down != nil else { throw ImportError.missingField("up/down") }
            if let obfsPassword { object["obfs"] = .string(obfsPassword) }
        }
        if !hopPorts.isEmpty {
            object["server_ports"] = .strings(hopPorts)
            let interval = hopInterval ?? ("30s", nil)
            object["hop_interval"] = .string(interval.0)
            if let maximum = interval.1 { object["hop_interval_max"] = .string(maximum) }
        }
        if let up { object["up_mbps"] = .int(up) }
        if let down { object["down_mbps"] = .int(down) }
        return .object(object)
    }

    private static func ports(_ value: JSON?) -> [String] {
        guard let value else { return [] }
        if let list = value.array {
            return list.flatMap { ShareLinkParser.portRanges($0.string ?? "") }
        }
        return ShareLinkParser.portRanges(value.string ?? "")
    }

    /// "30s", 30 or "20-40" (seconds) → hop interval and optional maximum.
    private static func interval(_ value: JSON?) -> (String, String?)? {
        guard let value else { return nil }
        if let number = value.int { return ("\(number)s", nil) }
        guard let text = value.text else { return nil }
        let parts = text.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]) {
            return ("\(low)s", "\(high)s")
        }
        return (ShareLinkParser.durationText(text) ?? "30s", nil)
    }

    // MARK: WireGuard

    private static func wireguard(_ settings: JSON) throws -> JSON {
        var config = WireGuardConfig()
        config.privateKey = settings["secretKey"]?.text ?? ""
        config.addresses = settings["address"]?.stringList ?? []
        config.mtu = settings["mtu"]?.int
        let reserved = settings["reserved"]?.array?.compactMap(\.int)
        for peerJSON in settings["peers"]?.array ?? [] {
            var peer = WireGuardConfig.Peer()
            if let endpoint = peerJSON["endpoint"]?.text, let authority = Authority.parse(endpoint) {
                peer.host = authority.host
                peer.port = authority.port ?? 51820
            }
            peer.publicKey = peerJSON["publicKey"]?.text ?? ""
            peer.preSharedKey = peerJSON["preSharedKey"]?.text
            peer.allowedIPs = peerJSON["allowedIPs"]?.stringList ?? []
            peer.keepalive = peerJSON["keepAlive"]?.int
            if let reserved, reserved.count == 3 { peer.reserved = reserved }
            config.peers.append(peer)
        }
        return try config.endpoint()
    }
}
