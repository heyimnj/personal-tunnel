import Foundation

/// Servers only Xray-core can run (masks such as `finalmask` `header-custom` or
/// `sudoku`). Such a server keeps its own Xray outbounds; sing-box hands its
/// connections to the Xray instance in the same process (3.3 beta 2: an
/// `xray-local` outbound; before, a local SOCKS port).
///
/// In the library it is an outbound of type `xray`: the Xray outbounds under
/// `xray`, the main hop's `server` / `server_port` for display and probes. It is
/// never written into a sing-box configuration as it is.
public enum XrayBacked {
    public static let type = "xray"

    static let proxyProtocols: Set<String> = ["vless", "vmess", "trojan", "shadowsocks", "hysteria", "hysteria2", "socks", "http", "wireguard"]

    /// The library form of an Xray server config, or nil when Xray could not run it either.
    static func node(config: JSONValue, name: String) -> ParsedNode? {
        let outbounds = config["outbounds"]?.arrayValue ?? []
        guard let main = outbounds.first(where: { proxyProtocols.contains($0["protocol"]?.stringValue?.lowercased() ?? "") }),
              let endpoint = endpoint(of: main) else { return nil }
        if ["0.0.0.0", "127.0.0.1", "localhost", "::1"].contains(endpoint.host.lowercased()) { return nil }
        let outbound: JSONValue = [
            "type": .string(type),
            "server": .string(endpoint.host),
            "server_port": .int(Int64(endpoint.port)),
            "xray": ["outbounds": .array(outbounds)],
        ]
        return ParsedNode(name: name, outbound: outbound)
    }

    /// Address and port of an Xray outbound, in either of Xray's two layouts.
    static func endpoint(of outbound: JSONValue) -> (host: String, port: Int)? {
        let settings = outbound["settings"] ?? .object([:])
        let server = settings["vnext"]?.arrayValue?.first ?? settings["servers"]?.arrayValue?.first
            ?? settings["peers"]?.arrayValue?.first ?? settings
        let host = server["address"]?.text ?? server["endpoint"]?.text.flatMap { $0.split(separator: ":").first.map(String.init) }
        let port = server["port"]?.looseInt ?? server["endpoint"]?.text.flatMap { $0.split(separator: ":").last.flatMap { Int($0) } }
        guard let host, !host.isEmpty, let port, port > 0, port < 65536 else { return nil }
        return (host, port)
    }

    /// The main proxy hop of an Xray-backed outbound.
    static func main(_ outbound: JSONValue) -> JSONValue? {
        (outbound.at("xray", "outbounds")?.arrayValue ?? []).first { proxyProtocols.contains($0["protocol"]?.stringValue?.lowercased() ?? "") }
    }

    /// Protocol facts read from the Xray outbound, so the server is labelled like the others.
    static func facts(_ outbound: JSONValue) -> (proto: String, security: String, network: String, vision: Bool) {
        let proxy = main(outbound) ?? .object([:])
        let stream = proxy["streamSettings"] ?? .object([:])
        let network = stream["network"]?.stringValue?.lowercased() ?? "tcp"
        let flow = proxy.at("settings", "vnext")?[0]?["users"]?[0]?["flow"]?.stringValue ?? proxy.at("settings", "flow")?.stringValue ?? ""
        return (proxy["protocol"]?.stringValue?.uppercased() ?? "XRAY", stream["security"]?.stringValue?.lowercased() ?? "none",
                network == "raw" ? "tcp" : network, flow.hasPrefix("xtls-rprx-vision"))
    }

    /// The instance name of the tunnel's Xray-core (the extension's).
    public static let tunnelInstance = "tunnel"

    /// The instance name of the app's measuring Xray-core for a subscription.
    public static func appInstance(_ subscription: Int64) -> String { "s\(subscription)" }

    /// 3.3 beta 2 (PT-01, PT-02): the sing-box side — an `xray-local` outbound
    /// (core/bridge) that hands each connection to the Xray-core instance in the
    /// same process, picked by its inbound tag in Xray's routing. There is no local
    /// port or socket any more: nothing another app could find or connect to.
    static func local(tag: String, instance: String, inbound: String) -> JSONValue {
        ["type": .string(localType), "tag": .string(tag), "instance": .string(instance), "inbound": .string(inbound)]
    }

    /// The outbound type core/bridge registers in sing-box (patch 0005).
    public static let localType = "xray-local"

    /// Each Xray-backed server → the prefix of its outbound tags in the runtime,
    /// by which its failures are found in Xray's log (`failure(inLog:prefix:)`).
    public static func prefixes(for nodes: [ServerNode], instance: String) -> [String: String] {
        var result: [String: String] = [:]
        for (index, node) in nodes.filter({ $0.type == type }).enumerated() { result[node.id] = tagPrefix(instance: instance, index: index) }
        return result
    }

    /// Each Xray-backed server of the list → the inbound tag its connections carry.
    static func inbounds(for nodes: [ServerNode]) -> [String: String] {
        var result: [String: String] = [:]
        for (index, node) in nodes.filter({ $0.type == type }).enumerated() { result[node.id] = "in\(index)" }
        return result
    }

    /// One Xray configuration that serves every Xray-backed server of the list.
    /// 3.3 beta 2: no inbounds — sing-box's `xray-local` outbounds dial into the
    /// instance; a rule per server sends its inbound tag to its outbounds. Nil when
    /// there are none.
    public static func runtime(_ nodes: [ServerNode], instance: String) -> JSONValue? {
        let tags = inbounds(for: nodes)
        let backed = nodes.filter { $0.type == type && tags[$0.id] != nil }
        guard !backed.isEmpty else { return nil }
        var outbounds: [JSONValue] = [["protocol": "blackhole", "tag": "pt-block"]]
        var rules: [JSONValue] = []
        for (index, node) in backed.enumerated() {
            guard let inbound = tags[node.id] else { continue }
            let prefix = tagPrefix(instance: instance, index: index)
            let own = node.outbound.at("xray", "outbounds")?.arrayValue ?? []
            var renamed: [String: String] = [:]
            for (offset, item) in own.enumerated() {
                renamed[item["tag"]?.stringValue ?? "#\(offset)"] = prefix + (item["tag"]?.stringValue ?? "out\(offset)")
            }
            var mainTag: String?
            for (offset, item) in own.enumerated() {
                var item = withoutAllowInsecure(item)
                let tag = renamed[item["tag"]?.stringValue ?? "#\(offset)"] ?? prefix + "out\(offset)"
                item["tag"] = .string(tag)
                if let dialer = item.at("streamSettings", "sockopt", "dialerProxy")?.stringValue, let next = renamed[dialer] {
                    var stream = item["streamSettings"] ?? .object([:])
                    var sockopt = stream["sockopt"] ?? .object([:])
                    sockopt["dialerProxy"] = .string(next)
                    stream["sockopt"] = sockopt
                    item["streamSettings"] = stream
                }
                if let proxy = item.at("proxySettings", "tag")?.stringValue, let next = renamed[proxy] {
                    item["proxySettings"] = ["tag": .string(next)]
                }
                if mainTag == nil, proxyProtocols.contains(item["protocol"]?.stringValue?.lowercased() ?? "") { mainTag = tag }
                outbounds.append(item)
            }
            rules.append(["type": "field", "inboundTag": [.string(inbound)], "outboundTag": .string(mainTag ?? "pt-block")])
        }
        let config: JSONValue = [
            "log": ["loglevel": "warning"],
            // Small per-connection buffers: the extension has about 50 MiB in all.
            "policy": ["levels": ["0": ["bufferSize": 4]]],
            "outbounds": .array(outbounds),
            "routing": ["domainStrategy": "AsIs", "rules": .array(rules)],
        ]
        return config
    }

    /// 3.3 (PT-04): `allowInsecure` taken out of an Xray outbound. Xray-core
    /// v26.11.9 refuses the field as a removed feature, and one server with it
    /// kept the whole runtime from starting; the certificate is then checked (or
    /// pinned with `pinnedPeerCertSha256`).
    static func withoutAllowInsecure(_ outbound: JSONValue) -> JSONValue {
        guard var stream = outbound["streamSettings"], var tls = stream["tlsSettings"], tls["allowInsecure"] != nil else { return outbound }
        tls["allowInsecure"] = nil
        stream["tlsSettings"] = tls
        var outbound = outbound
        outbound["streamSettings"] = stream
        return outbound
    }
}

public extension XrayBacked {
    /// 3.1.15: the prefix of a server's outbound tags in the runtime. It names the
    /// server's local port, unique in the app across subscriptions (the index was
    /// not), so Xray's log tells the servers apart.
    /// 3.3 beta 2: the instance and the server's place in it (there is no port).
    static func tagPrefix(instance: String, index: Int) -> String { "\(instance)n\(index)-" }

    /// 3.1.15: Xray-core's own reason for the last failed connection through the
    /// server on `port`, from a log written at the «info» level. Xray writes why an
    /// outbound failed only there (`failed to process outbound traffic > …`); the app
    /// saw only «connection reset by peer» from the local port.
    /// A connection is followed by its session number: `[Info] [123] app/dispatcher:
    /// taking detour [n30861-proxy] …`, then `[Info] [123] …: failed …`.
    static func failure(inLog text: String, prefix: String) -> String? {
        let marker = "taking detour [" + prefix
        var sessions = Set<Substring>()
        var reason: String?
        for line in text.split(separator: "\n") {
            guard let session = session(of: line) else { continue }
            if line.contains(marker) {
                sessions.insert(session)
            } else if sessions.contains(session), line.contains("failed") || line.contains("[Warning]") || line.contains("[Error]") {
                reason = cleaned(line, after: session)
            }
        }
        return reason
    }

    /// The session number in `2026/11/16 08:02:01.123 [Info] [123] …`.
    private static func session(of line: Substring) -> Substring? {
        guard let level = line.range(of: "] [") else { return nil }
        let rest = line[level.upperBound...]
        guard let end = rest.firstIndex(of: "]"), rest.startIndex < end,
              rest[..<end].allSatisfy(\.isNumber) else { return nil }
        return rest[..<end]
    }

    /// The message of a log line without the date, level, session and the words
    /// every outbound failure starts and ends with.
    private static func cleaned(_ line: Substring, after session: Substring) -> String {
        var text = line.range(of: "[\(session)] ").map { String(line[$0.upperBound...]) } ?? String(line)
        for noise in ["app/proxyman/outbound: ", "failed to process outbound traffic > "] {
            while text.hasPrefix(noise) { text.removeFirst(noise.count) }
        }
        text = text.replacingOccurrences(of: " > common/retry: all retry attempts failed", with: "")
        return text.count > 400 ? String(text.prefix(400)) + "…" : text
    }

    /// What the extension does to the runtime before starting it: every hop that
    /// dials the network itself is bound to the physical interface (as sing-box
    /// binds its own; otherwise Xray's connections could loop back into the
    /// tunnel), and Xray's warnings go to a file the app can show.
    /// `level`: «info» for the app's measurements, whose failures are read back
    /// (`failure(inLog:prefix:)`); the tunnel keeps «warning» (a line per connection
    /// would grow the file all day).
    ///
    /// `exit` (3.2.8): with the kill switch, the tunnel's loopback way out
    /// (`ProbeExit`): every hop that dials by itself dials through it, as
    /// sing-box's servers do. Until then Xray's tests went through the connected
    /// server and the tunnel's gVisor, and a dead server held a connection there
    /// for a minute.
    static func prepare(_ runtime: JSONValue, interface: String?, logPath: String?, level: String = "warning", exit: ProbeExit? = nil) -> JSONValue {
        var config = runtime
        if let logPath { config["log"] = ["loglevel": .string(level), "error": .string(logPath), "access": "none"] }
        if let exit { return throughProbeExit(config, exit) }
        guard let interface, !interface.isEmpty else { return config }
        config["outbounds"] = .array((config["outbounds"]?.arrayValue ?? []).map { outbound in
            let proto = outbound["protocol"]?.stringValue?.lowercased() ?? ""
            guard proxyProtocols.contains(proto) || proto == "freedom" else { return outbound }
            var outbound = outbound
            var stream = outbound["streamSettings"] ?? .object([:])
            var sockopt = stream["sockopt"] ?? .object([:])
            // A hop that dials through another one leaves the binding to that one.
            guard sockopt["dialerProxy"] == nil, outbound["proxySettings"] == nil else { return outbound }
            sockopt["interface"] = .string(interface)
            stream["sockopt"] = sockopt
            outbound["streamSettings"] = stream
            return outbound
        })
        return config
    }
}

extension XrayBacked {
    static func throughProbeExit(_ config: JSONValue, _ exit: ProbeExit) -> JSONValue {
        var config = config
        let socks: JSONValue = [
            "protocol": "socks",
            "tag": .string(ProbeExit.outboundTag),
            "settings": ["address": "127.0.0.1", "port": .int(Int64(exit.port)), "user": .string(exit.username), "pass": .string(exit.password)],
        ]
        config["outbounds"] = .array((config["outbounds"]?.arrayValue ?? []).map { outbound in
            let proto = outbound["protocol"]?.stringValue?.lowercased() ?? ""
            guard proxyProtocols.contains(proto) || proto == "freedom" else { return outbound }
            var outbound = outbound
            var stream = outbound["streamSettings"] ?? .object([:])
            var sockopt = stream["sockopt"] ?? .object([:])
            // A hop that dials through another one: the first hop goes out this way.
            guard sockopt["dialerProxy"] == nil, outbound["proxySettings"] == nil else { return outbound }
            sockopt["dialerProxy"] = .string(ProbeExit.outboundTag)
            stream["sockopt"] = sockopt
            outbound["streamSettings"] = stream
            return outbound
        } + [socks])
        return config
    }
}

// MARK: Editing (3.1.6)

public extension XrayBacked {
    /// The form for a server Xray-core runs: its main proxy read as the editor's
    /// fields. Nil when the editor has no form for it (mKCP, say).
    static func draft(_ outbound: JSONValue, name: String) -> ServerDraft? {
        guard outbound["type"]?.stringValue == type, let proxy = main(outbound),
              let converted = try? XrayImport.outbound(from: proxy) else { return nil }
        var draft = ServerDraft(outbound: converted, name: name)
        // 3.3 (PT-04): Xray-core has no «do not check» any more.
        draft?.insecure = false
        draft?.allowsInsecure = false
        return draft
    }

    /// The edited form written back into the Xray outbounds, so the server stays
    /// in Xray-core with everything the form does not show (its `freedom` helper,
    /// sockopt, mux…). A different protocol makes it an ordinary server.
    static func apply(_ draft: ServerDraft, to outbound: JSONValue) throws -> JSONValue {
        let made = try draft.outbound()
        guard var proxy = main(outbound) else { return made }
        let kind = proxy["protocol"]?.stringValue?.lowercased() ?? ""
        let same = kind == draft.proto.rawValue || (kind == "hysteria" && draft.proto == .hysteria2)
        guard same, [.vless, .vmess, .trojan, .shadowsocks, .hysteria2].contains(draft.proto) else { return made }
        let host = draft.host.trimmingCharacters(in: .whitespaces)
        let port = Int(draft.port.trimmingCharacters(in: .whitespaces)) ?? 0
        let secret = draft.secret.trimmingCharacters(in: .whitespaces)

        var settings = proxy["settings"] ?? .object([:])
        let list = ["vless", "vmess"].contains(kind) ? "vnext" : "servers"
        func patchServer(_ body: (inout JSONValue) -> Void) {
            if var servers = settings[list]?.arrayValue, !servers.isEmpty {
                body(&servers[0])
                settings[list] = .array(servers)
            } else {
                body(&settings)
            }
        }
        patchServer { server in
            server["address"] = .string(host)
            server["port"] = .int(Int64(port))
            switch draft.proto {
            case .vless, .vmess:
                func patchUser(_ user: inout JSONValue) {
                    user["id"] = .string(secret)
                    if draft.proto == .vless {
                        user["flow"] = draft.vision && draft.transport == .tcp ? "xtls-rprx-vision" : nil
                    }
                }
                if var users = server["users"]?.arrayValue, !users.isEmpty {
                    patchUser(&users[0])
                    server["users"] = .array(users)
                } else {
                    patchUser(&server)
                }
            case .trojan:
                server["password"] = .string(secret)
            case .shadowsocks:
                server["password"] = .string(secret)
                server["method"] = .string(draft.method)
            default:
                break
            }
        }
        proxy["settings"] = settings

        var stream = proxy["streamSettings"] ?? .object([:])
        if draft.proto == .hysteria2 {
            var hy = stream["hysteriaSettings"] ?? .object([:])
            hy["auth"] = .string(secret)
            stream["hysteriaSettings"] = hy
            var tls = stream["tlsSettings"] ?? .object([:])
            tls["serverName"] = draft.sni.isEmpty ? nil : .string(draft.sni)
            // 3.3 (PT-04): Xray-core v26.11.9 refuses `allowInsecure` (a removed
            // feature: the whole runtime would not start); a pin stays as it is.
            tls["allowInsecure"] = nil
            stream["tlsSettings"] = tls
        } else if draft.proto != .shadowsocks {
            let network = draft.transport.rawValue
            stream["network"] = .string(network == "tcp" ? (stream["network"]?.stringValue == "raw" ? "raw" : "tcp") : network)
            stream["security"] = .string(draft.security.rawValue)
            let alpn = draft.alpn.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            switch draft.security {
            case .tls:
                var tls = stream["tlsSettings"] ?? .object([:])
                tls["serverName"] = draft.sni.isEmpty ? nil : .string(draft.sni)
                tls["fingerprint"] = draft.fingerprint.isEmpty ? nil : .string(draft.fingerprint)
                tls["alpn"] = alpn.isEmpty ? nil : JSONValue(alpn)
                tls["allowInsecure"] = nil
                stream["tlsSettings"] = tls
            case .reality:
                var reality = stream["realitySettings"] ?? .object([:])
                reality["serverName"] = .string(draft.sni)
                reality["publicKey"] = .string(draft.publicKey)
                reality["shortId"] = .string(draft.shortID)
                reality["fingerprint"] = .string(draft.fingerprint.isEmpty ? "chrome" : draft.fingerprint)
                stream["realitySettings"] = reality
            case .none:
                break
            }
            func patch(_ key: String, _ fields: [String: String]) {
                var object = stream[key] ?? .object([:])
                for (field, value) in fields { object[field] = value.isEmpty ? nil : .string(value) }
                stream[key] = object
            }
            switch draft.transport {
            case .ws: patch("wsSettings", ["path": draft.path, "host": draft.hostHeader])
            case .httpupgrade: patch("httpupgradeSettings", ["path": draft.path, "host": draft.hostHeader])
            case .xhttp: patch(stream["splithttpSettings"] != nil ? "splithttpSettings" : "xhttpSettings", ["path": draft.path, "host": draft.hostHeader])
            case .grpc: patch("grpcSettings", ["serviceName": draft.serviceName])
            case .tcp: break
            }
        }
        proxy["streamSettings"] = stream

        // The check sing-box runs at import: the edited server must still convert.
        _ = try XrayImport.outbound(from: proxy)
        var result = outbound
        let mainTag = proxy["tag"]
        result["xray"] = ["outbounds": .array((outbound.at("xray", "outbounds")?.arrayValue ?? []).map { item in
            proxyProtocols.contains(item["protocol"]?.stringValue?.lowercased() ?? "") && item["tag"] == mainTag ? proxy : item
        })]
        result["server"] = .string(host)
        result["server_port"] = .int(Int64(port))
        return result
    }
}

public extension XrayBacked {
    /// 3.1.14: servers sing-box cannot hold up that Xray-core runs (as in Happ),
    /// whatever form they came in — a share link, Xray JSON, or a library written
    /// before: VLESS REALITY over gRPC. sing-box's gRPC to such panels ended in
    /// «io: read/write on closed pipe» or a timeout with both cores.
    static func belongsInXray(_ object: JSONValue) -> Bool {
        object["type"]?.stringValue?.lowercased() == "vless"
            && object.at("tls", "reality", "enabled")?.boolValue == true
            && object.at("transport", "type")?.stringValue?.lowercased() == "grpc"
    }

    /// The same server as an Xray-backed one, written from its own fields
    /// (the editor's mapping, `apply`). Nil when it does not belong in Xray or
    /// cannot be described.
    static func promoted(_ object: JSONValue, name: String) -> JSONValue? {
        guard belongsInXray(object), let draft = ServerDraft(outbound: object, name: name),
              let host = object["server"]?.stringValue, let port = object["server_port"]?.intValue else { return nil }
        let template: JSONValue = [
            "type": .string(type),
            "server": .string(host),
            "server_port": .int(Int64(port)),
            "xray": ["outbounds": [[
                "protocol": "vless",
                "tag": "proxy",
                "settings": ["vnext": [["address": .string(host), "port": .int(Int64(port)),
                                        "users": [["id": "", "encryption": "none"]]]]],
                "streamSettings": [:],
            ]]],
        ]
        guard var result = try? apply(draft, to: template), result["type"]?.stringValue == type else { return nil }
        if let tag = object["tag"] { result["tag"] = tag }
        return result
    }

    /// A library server moved into Xray when it belongs there (its members are kept).
    static func promoted(_ node: ServerNode) -> ServerNode {
        guard node.members.isEmpty, let outbound = promoted(node.outbound, name: node.name) else { return node }
        var node = node
        node.outbound = outbound
        return node
    }
}
