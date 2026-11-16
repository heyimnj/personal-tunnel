import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Servers only Xray-core can run (masks such as `finalmask` `header-custom` or
/// `sudoku`). Such a server keeps its own Xray outbounds; sing-box reaches it
/// through a local SOCKS port that an Xray instance beside it serves.
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

    /// The sing-box side: a SOCKS hop to the local port, with the link's login.
    static func socks(tag: String, link: LocalLink) -> JSONValue {
        ["type": "socks", "tag": .string(tag), "server": "127.0.0.1", "server_port": .int(Int64(link.port)), "version": "5",
         "username": .string(link.username), "password": .string(link.password)]
    }

    /// 3.3 (PT-01, PT-02): a fresh local link — random free port, login and
    /// password — for each Xray-backed server of the list.
    public static func links(for nodes: [ServerNode]) -> LocalLinks {
        let backed = nodes.filter { $0.type == type }.map(\.id)
        var links: LocalLinks = [:]
        for (id, port) in zip(backed, LocalSecrets.freePorts(backed.count)) {
            links[id] = LocalLink(port: port, username: LocalSecrets.token(), password: LocalSecrets.token())
        }
        return links
    }

    /// One Xray configuration that serves every Xray-backed server of the list,
    /// each on its own local SOCKS port behind a login (3.3: random ports and
    /// credentials, `links`; there were fixed ports without a password before).
    /// A server without a link is left out. Nil when there are none.
    public static func runtime(_ nodes: [ServerNode], links: LocalLinks) -> JSONValue? {
        let backed = nodes.filter { $0.type == type && links[$0.id] != nil }
        guard !backed.isEmpty else { return nil }
        var inbounds: [JSONValue] = []
        var outbounds: [JSONValue] = [["protocol": "blackhole", "tag": "pt-block"]]
        var rules: [JSONValue] = []
        for (index, node) in backed.enumerated() {
            guard let link = links[node.id] else { continue }
            let port = link.port
            let prefix = tagPrefix(port: port)
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
            inbounds.append([
                "tag": .string("in\(index)"), "listen": "127.0.0.1", "port": .int(Int64(port)), "protocol": "socks",
                "settings": ["auth": "password", "accounts": [["user": .string(link.username), "pass": .string(link.password)]],
                             "udp": true, "ip": "127.0.0.1"],
            ])
            rules.append(["type": "field", "inboundTag": [.string("in\(index)")], "outboundTag": .string(mainTag ?? "pt-block")])
        }
        let config: JSONValue = [
            "log": ["loglevel": "warning"],
            // Small per-connection buffers: the extension has about 50 MiB in all.
            "policy": ["levels": ["0": ["bufferSize": 4]]],
            "inbounds": .array(inbounds),
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

    /// 3.3 (PT-01): the tunnel's two configurations with new local links. The
    /// extension calls it at every start and reload, so the stored files never
    /// hold the links the running tunnel uses. The sing-box SOCKS hop of each Xray
    /// inbound is found by its old port. Nil when the two do not match.
    public static func rekey(config: JSONValue, xray: JSONValue) -> (config: JSONValue, xray: JSONValue)? {
        guard let inbounds = xray["inbounds"]?.arrayValue, !inbounds.isEmpty,
              var outbounds = config["outbounds"]?.arrayValue else { return nil }
        let fresh = LocalSecrets.freePorts(inbounds.count)
        guard fresh.count == inbounds.count else { return nil }
        var newInbounds: [JSONValue] = []
        var newOutbounds: [JSONValue] = []
        var renamed: [String: String] = [:]
        for (index, inbound) in inbounds.enumerated() {
            guard let old = inbound["port"]?.intValue,
                  let hop = outbounds.firstIndex(where: { $0["type"] == "socks" && $0["server"] == "127.0.0.1" && $0["server_port"]?.intValue == old })
            else { return nil }
            let link = LocalLink(port: fresh[index], username: LocalSecrets.token(), password: LocalSecrets.token())
            var item = inbound
            item["port"] = .int(Int64(link.port))
            var settings = item["settings"] ?? .object([:])
            settings["auth"] = "password"
            settings["accounts"] = [["user": .string(link.username), "pass": .string(link.password)]]
            item["settings"] = settings
            newInbounds.append(item)
            let tag = outbounds[hop]["tag"]?.stringValue ?? ""
            outbounds[hop] = socks(tag: tag, link: link)
            renamed[tagPrefix(port: old)] = tagPrefix(port: link.port)
        }
        // Xray's outbound tags carry the port (`n<port>-`): they follow it.
        func rename(_ value: JSONValue?) -> JSONValue? {
            guard let text = value?.stringValue else { return value }
            for (old, new) in renamed where text.hasPrefix(old) { return .string(new + text.dropFirst(old.count)) }
            return value
        }
        for outbound in xray["outbounds"]?.arrayValue ?? [] {
            var outbound = outbound
            outbound["tag"] = rename(outbound["tag"])
            if var stream = outbound["streamSettings"], var sockopt = stream["sockopt"], let dialer = sockopt["dialerProxy"] {
                sockopt["dialerProxy"] = rename(dialer)
                stream["sockopt"] = sockopt
                outbound["streamSettings"] = stream
            }
            if let proxy = outbound.at("proxySettings", "tag") { outbound["proxySettings"] = ["tag": rename(proxy) ?? proxy] }
            newOutbounds.append(outbound)
        }
        var runtime = xray
        runtime["inbounds"] = .array(newInbounds)
        runtime["outbounds"] = .array(newOutbounds)
        if let rules = xray.at("routing", "rules")?.arrayValue {
            var routing = xray["routing"] ?? .object([:])
            routing["rules"] = .array(rules.map { rule in
                var rule = rule
                rule["outboundTag"] = rename(rule["outboundTag"])
                return rule
            })
            runtime["routing"] = routing
        }
        var result = config
        result["outbounds"] = .array(outbounds)
        return (result, runtime)
    }
}

/// 3.3 (PT-01): how sing-box reaches one Xray-backed server inside the device.
public struct LocalLink: Equatable, Sendable {
    public var port: Int
    public var username: String
    public var password: String

    public init(port: Int, username: String, password: String) {
        self.port = port
        self.username = username
        self.password = password
    }
}

/// Server id → its local link.
public typealias LocalLinks = [String: LocalLink]

/// Randomness and free ports for the local links (3.3, PT-01).
public enum LocalSecrets {
    /// Cryptographically secure bytes. The default is the system generator
    /// (arc4random on Apple systems, getrandom on Linux); the app and the
    /// extension set SecRandomCopyBytes at start.
    nonisolated(unsafe) public static var randomBytes: (Int) -> [UInt8] = { count in
        var generator = SystemRandomNumberGenerator()
        return (0 ..< count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    /// 128 bits as 32 hex characters.
    public static func token() -> String {
        randomBytes(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Ports that are tried: well above the system's own services, below the
    /// range the system hands out for outgoing connections.
    public static let portRange = 20000 ... 48999

    /// `count` distinct random ports nothing listens on right now (127.0.0.1).
    public static func freePorts(_ count: Int) -> [Int] {
        var result: [Int] = []
        var attempts = 0
        while result.count < count, attempts < count * 50 + 50 {
            attempts += 1
            let bytes = randomBytes(4)
            let value = bytes.reduce(0) { ($0 << 8) | Int($1) }
            let port = portRange.lowerBound + value % portRange.count
            guard !result.contains(port), isFree(port) else { continue }
            result.append(port)
        }
        return result
    }

    /// Whether a TCP port can be bound on 127.0.0.1 now.
    nonisolated(unsafe) public static var isFree: (Int) -> Bool = LoopbackPort.isFree
}

enum LoopbackPort {
    static func isFree(_ port: Int) -> Bool {
        #if canImport(Darwin)
        let stream = SOCK_STREAM
        #else
        let stream = Int32(SOCK_STREAM.rawValue)
        #endif
        let descriptor = socket(AF_INET, stream, 0)
        guard descriptor >= 0 else { return true }
        defer { close(descriptor) }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }
}

public extension XrayBacked {
    /// 3.1.15: the prefix of a server's outbound tags in the runtime. It names the
    /// server's local port, unique in the app across subscriptions (the index was
    /// not), so Xray's log tells the servers apart.
    static func tagPrefix(port: Int) -> String { "n\(port)-" }

    /// 3.1.15: Xray-core's own reason for the last failed connection through the
    /// server on `port`, from a log written at the «info» level. Xray writes why an
    /// outbound failed only there (`failed to process outbound traffic > …`); the app
    /// saw only «connection reset by peer» from the local port.
    /// A connection is followed by its session number: `[Info] [123] app/dispatcher:
    /// taking detour [n30861-proxy] …`, then `[Info] [123] …: failed …`.
    static func failure(inLog text: String, port: Int) -> String? {
        let marker = "taking detour [" + tagPrefix(port: port)
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
    /// (`failure(inLog:port:)`); the tunnel keeps «warning» (a line per connection
    /// would grow the file all day).
    static func prepare(_ runtime: JSONValue, interface: String?, logPath: String?, level: String = "warning") -> JSONValue {
        var config = runtime
        if let logPath { config["log"] = ["loglevel": .string(level), "error": .string(logPath), "access": "none"] }
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
