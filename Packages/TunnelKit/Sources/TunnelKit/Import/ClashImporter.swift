import Foundation

/// Reads the `proxies` list of a Clash / Mihomo configuration.
enum ClashImporter {
    static func looksLikeClash(_ text: String) -> Bool {
        text.range(of: #"(?m)^proxies\s*:"#, options: .regularExpression) != nil
    }

    static func importServers(_ text: String) throws -> ([ImportedServer], [SkippedEntry]) {
        let document = try YAML.parse(text)
        guard let proxies = document["proxies"]?.array else { throw ImportError.invalidYAML("нет списка proxies") }
        var servers: [ImportedServer] = []
        var skipped: [SkippedEntry] = []
        for proxy in proxies {
            let name = proxy["name"]?.text ?? proxy["server"]?.text ?? "Clash"
            do {
                servers.append(try convert(proxy, name: name))
            } catch {
                skipped.append(SkippedEntry(name: name, reason: String(describing: error)))
            }
        }
        return (servers, skipped)
    }

    static func convert(_ proxy: JSON, name: String) throws -> ImportedServer {
        let type = proxy["type"]?.text?.lowercased() ?? ""
        guard let server = proxy["server"]?.text else { throw ImportError.missingField("server") }
        let port = proxy["port"]?.int ?? 443
        var object: [String: JSON] = ["server": .string(server), "server_port": .int(port)]
        switch type {
        case "vless", "vmess", "trojan":
            object["type"] = .string(type)
            if type == "trojan" {
                guard let password = proxy["password"]?.text else { throw ImportError.missingField("password") }
                object["password"] = .string(password)
            } else {
                guard let uuid = proxy["uuid"]?.text else { throw ImportError.missingField("uuid") }
                object["uuid"] = .string(uuid)
            }
            if type == "vless" {
                if let flow = try ShareLinkParser.normalizedFlow(proxy["flow"]?.text) { object["flow"] = .string(flow) }
                if let encryption = proxy["encryption"]?.text, encryption != "none" { object["encryption"] = .string(encryption) }
                object["packet_encoding"] = "xudp"
            }
            if type == "vmess" {
                object["security"] = .string(proxy["cipher"]?.text ?? "auto")
                object["alter_id"] = .int(proxy["alterId"]?.int ?? proxy["alter-id"]?.int ?? 0)
            }
            let stream = streamSettings(proxy, defaultTLS: type == "trojan")
            if let transport = try stream.transport() { object["transport"] = transport }
            if let tls = stream.tls(defaultServerName: server) { object["tls"] = tls }
        case "ss", "shadowsocks":
            object["type"] = "shadowsocks"
            guard let method = proxy["cipher"]?.text?.lowercased() else { throw ImportError.missingField("cipher") }
            guard ShareLinkParser.shadowsocksMethods.contains(method) else { throw ImportError.unsupportedOption("шифр \(method)") }
            object["method"] = .string(method)
            object["password"] = .string(proxy["password"]?.string ?? "")
            if let plugin = proxy["plugin"]?.text {
                let opts = proxy["plugin-opts"]?.object ?? [:]
                switch plugin {
                case "obfs", "obfs-local", "simple-obfs":
                    object["plugin"] = "obfs-local"
                    var parts: [String] = []
                    if let mode = opts["mode"]?.text { parts.append("obfs=\(mode)") }
                    if let host = opts["host"]?.text { parts.append("obfs-host=\(host)") }
                    object["plugin_opts"] = .string(parts.joined(separator: ";"))
                case "v2ray-plugin":
                    object["plugin"] = "v2ray-plugin"
                    var parts: [String] = []
                    if let mode = opts["mode"]?.text { parts.append("mode=\(mode)") }
                    if opts["tls"]?.bool == true { parts.append("tls") }
                    if let host = opts["host"]?.text { parts.append("host=\(host)") }
                    if let path = opts["path"]?.text { parts.append("path=\(path)") }
                    object["plugin_opts"] = .string(parts.joined(separator: ";"))
                default:
                    throw ImportError.unsupportedOption("плагин \(plugin)")
                }
            }
            if proxy["udp-over-tcp"]?.bool == true { object["udp_over_tcp"] = ["enabled": true, "version": 2] }
        case "hysteria2", "hy2":
            object["type"] = "hysteria2"
            if let password = proxy["password"]?.text ?? proxy["auth"]?.text { object["password"] = .string(password) }
            if let obfs = proxy["obfs"]?.text?.lowercased(), obfs != "none" {
                guard obfs == "salamander" || obfs == "gecko" else { throw ImportError.unsupportedOption("obfs \(obfs)") }
                var obfsObject: [String: JSON] = ["type": .string(obfs)]
                if let password = proxy["obfs-password"]?.text { obfsObject["password"] = .string(password) }
                object["obfs"] = .object(obfsObject)
            }
            if let ports = proxy["ports"]?.text {
                let ranges = ShareLinkParser.portRanges(ports)
                if !ranges.isEmpty {
                    object["server_ports"] = .strings(ranges)
                    object["hop_interval"] = .string(ShareLinkParser.durationText(proxy["hop-interval"]?.string) ?? "30s")
                }
            }
            if let up = ShareLinkParser.mbps(proxy["up"]?.string) { object["up_mbps"] = .int(up) }
            if let down = ShareLinkParser.mbps(proxy["down"]?.string) { object["down_mbps"] = .int(down) }
            object["tls"] = quicTLS(proxy, server: server, defaultALPN: ["h3"])
        case "hysteria":
            object["type"] = "hysteria"
            guard let up = ShareLinkParser.mbps(proxy["up"]?.string), let down = ShareLinkParser.mbps(proxy["down"]?.string) else {
                throw ImportError.missingField("up/down")
            }
            object["up_mbps"] = .int(up)
            object["down_mbps"] = .int(down)
            if let auth = proxy["auth-str"]?.text ?? proxy["auth_str"]?.text { object["auth_str"] = .string(auth) }
            if let obfs = proxy["obfs"]?.text { object["obfs"] = .string(obfs) }
            object["tls"] = quicTLS(proxy, server: server, defaultALPN: [])
        case "tuic":
            object["type"] = "tuic"
            guard let uuid = proxy["uuid"]?.text else { throw ImportError.missingField("uuid") }
            object["uuid"] = .string(uuid)
            if let password = proxy["password"]?.text { object["password"] = .string(password) }
            if let congestion = proxy["congestion-controller"]?.text?.lowercased(), ["cubic", "new_reno", "bbr"].contains(congestion) {
                object["congestion_control"] = .string(congestion)
            }
            if let relay = proxy["udp-relay-mode"]?.text?.lowercased(), ["native", "quic"].contains(relay) {
                object["udp_relay_mode"] = .string(relay)
            }
            if proxy["reduce-rtt"]?.bool == true { object["zero_rtt_handshake"] = true }
            object["tls"] = quicTLS(proxy, server: server, defaultALPN: ["h3"])
        case "wireguard", "wg":
            var config = WireGuardConfig()
            config.privateKey = proxy["private-key"]?.text ?? ""
            config.addresses = [proxy["ip"]?.text, proxy["ipv6"]?.text].compactMap { $0 }
            config.mtu = proxy["mtu"]?.int
            var peer = WireGuardConfig.Peer()
            peer.host = server
            peer.port = port
            peer.publicKey = proxy["public-key"]?.text ?? ""
            peer.preSharedKey = proxy["pre-shared-key"]?.text
            peer.allowedIPs = proxy["allowed-ips"]?.stringList ?? []
            peer.keepalive = proxy["persistent-keepalive"]?.int
            if let reserved = proxy["reserved"] {
                if let list = reserved.array?.compactMap(\.int), list.count == 3 { peer.reserved = list } else if let text = reserved.text { peer.reserved = WireGuardConfig.reserved(text) }
            }
            config.peers = [peer]
            if let options = proxy["amnezia-wg-option"]?.object {
                for (key, value) in options {
                    let lowered = key.lowercased()
                    if WireGuardConfig.amneziaKeys.contains(lowered), let text = value.string { config.amnezia[lowered] = text }
                }
            }
            return ImportedServer(name: name, outbound: try config.endpoint())
        case "socks5", "socks":
            object["type"] = "socks"
            if let user = proxy["username"]?.text { object["username"] = .string(user) }
            if let password = proxy["password"]?.string { object["password"] = .string(password) }
        case "http":
            object["type"] = "http"
            if let user = proxy["username"]?.text { object["username"] = .string(user) }
            if let password = proxy["password"]?.string { object["password"] = .string(password) }
            if proxy["tls"]?.bool == true {
                var tls: [String: JSON] = ["enabled": true]
                if let sni = proxy["sni"]?.text { tls["server_name"] = .string(sni) }
                if proxy["skip-cert-verify"]?.bool == true { tls["insecure"] = true }
                object["tls"] = .object(tls)
            }
        case "anytls":
            object["type"] = "anytls"
            guard let password = proxy["password"]?.text else { throw ImportError.missingField("password") }
            object["password"] = .string(password)
            var stream = streamSettings(proxy, defaultTLS: true)
            stream.security = "tls"
            if let tls = stream.tls(defaultServerName: server) { object["tls"] = tls }
        case "ssr", "shadowsocksr": throw ImportError.unsupportedProtocol("ShadowsocksR")
        case "mieru": throw ImportError.unsupportedProtocol("Mieru")
        case "snell": throw ImportError.unsupportedProtocol("Snell")
        case "ssh": throw ImportError.unsupportedProtocol("SSH")
        default:
            throw ImportError.unsupportedProtocol(type.isEmpty ? "?" : type)
        }
        return ImportedServer(name: name, outbound: .object(object))
    }

    private static func streamSettings(_ proxy: JSON, defaultTLS: Bool) -> StreamSettings {
        var stream = StreamSettings()
        stream.network = proxy["network"]?.text ?? "tcp"
        let reality = proxy["reality-opts"]
        if reality != nil {
            stream.security = "reality"
            stream.realityPublicKey = reality?["public-key"]?.text
            stream.realityShortID = reality?["short-id"]?.text
        } else if proxy["tls"]?.bool ?? defaultTLS {
            stream.security = "tls"
        }
        stream.serverName = proxy["servername"]?.text ?? proxy["sni"]?.text
        stream.alpn = proxy["alpn"]?.stringList ?? []
        stream.fingerprint = proxy["client-fingerprint"]?.text
        stream.insecure = proxy["skip-cert-verify"]?.bool ?? false
        switch stream.network {
        case "ws":
            let options = proxy["ws-opts"]
            stream.path = options?["path"]?.text
            for (key, value) in options?["headers"]?.object ?? [:] {
                if key.lowercased() == "host" { stream.host = value.text } else if let text = value.string { stream.headers[key] = text }
            }
            stream.maxEarlyData = options?["max-early-data"]?.int
            stream.earlyDataHeaderName = options?["early-data-header-name"]?.text
            if options?["v2ray-http-upgrade"]?.bool == true { stream.network = "httpupgrade" }
        case "grpc":
            stream.serviceName = proxy["grpc-opts"]?["grpc-service-name"]?.text
        case "h2":
            stream.host = proxy["h2-opts"]?["host"]?.stringList.joined(separator: ",")
            stream.path = proxy["h2-opts"]?["path"]?.text
        case "http":
            stream.network = "tcp"
            stream.headerType = "http"
            stream.path = proxy["http-opts"]?["path"]?.stringList.first
            stream.host = proxy["http-opts"]?["headers"]?["Host"]?.stringList.first
            stream.method = proxy["http-opts"]?["method"]?.text
        case "xhttp":
            let options = proxy["xhttp-opts"]
            stream.path = options?["path"]?.text
            stream.host = options?["host"]?.text
            stream.mode = options?["mode"]?.text
        default:
            break
        }
        return stream
    }

    private static func quicTLS(_ proxy: JSON, server: String, defaultALPN: [String]) -> JSON {
        var tls: [String: JSON] = ["enabled": true]
        if let sni = proxy["sni"]?.text ?? proxy["servername"]?.text {
            tls["server_name"] = .string(sni)
        } else if !StreamSettings.isIPAddress(server) {
            tls["server_name"] = .string(server)
        }
        if proxy["skip-cert-verify"]?.bool == true { tls["insecure"] = true }
        let alpn = proxy["alpn"]?.stringList ?? []
        if !(alpn.isEmpty ? defaultALPN : alpn).isEmpty { tls["alpn"] = .strings(alpn.isEmpty ? defaultALPN : alpn) }
        return .object(tls)
    }
}
