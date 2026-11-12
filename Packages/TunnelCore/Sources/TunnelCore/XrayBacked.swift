import Foundation

/// Servers only Xray-core can run (masks such as `finalmask` `header-custom` or
/// `sudoku`). Such a server keeps its own Xray outbounds; sing-box reaches it
/// through a local SOCKS port that an Xray instance beside it serves.
///
/// In the library it is an outbound of type `xray`: the Xray outbounds under
/// `xray`, the main hop's `server` / `server_port` for display and probes. It is
/// never written into a sing-box configuration as it is.
public enum XrayBacked {
    public static let type = "xray"
    /// Local ports: the tunnel's Xray, and the app's own for measuring.
    public static let tunnelPortBase = 20800
    public static let appPortBase = 30800

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

    /// The sing-box side: a SOCKS hop to the local port.
    static func socks(tag: String, port: Int) -> JSONValue {
        ["type": "socks", "tag": .string(tag), "server": "127.0.0.1", "server_port": .int(Int64(port)), "version": "5"]
    }

    /// One Xray configuration that serves every Xray-backed server of the list,
    /// each on its own local SOCKS port (`portBase` + its index). Nil when there are none.
    public static func runtime(_ nodes: [ServerNode], portBase: Int) -> (config: JSONValue, ports: [String: Int])? {
        let backed = nodes.filter { $0.type == type }
        guard !backed.isEmpty else { return nil }
        var inbounds: [JSONValue] = []
        var outbounds: [JSONValue] = [["protocol": "blackhole", "tag": "pt-block"]]
        var rules: [JSONValue] = []
        var ports: [String: Int] = [:]
        for (index, node) in backed.enumerated() {
            let port = portBase + index
            ports[node.id] = port
            let prefix = "n\(index)-"
            let own = node.outbound.at("xray", "outbounds")?.arrayValue ?? []
            var renamed: [String: String] = [:]
            for (offset, item) in own.enumerated() {
                renamed[item["tag"]?.stringValue ?? "#\(offset)"] = prefix + (item["tag"]?.stringValue ?? "out\(offset)")
            }
            var mainTag: String?
            for (offset, item) in own.enumerated() {
                var item = item
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
                "settings": ["auth": "noauth", "udp": true, "ip": "127.0.0.1"],
            ])
            rules.append(["type": "field", "inboundTag": [.string("in\(index)")], "outboundTag": .string(mainTag ?? "pt-block")])
        }
        let config: JSONValue = [
            "log": ["loglevel": "warning"],
            "inbounds": .array(inbounds),
            "outbounds": .array(outbounds),
            "routing": ["domainStrategy": "AsIs", "rules": .array(rules)],
        ]
        return (config, ports)
    }
}
