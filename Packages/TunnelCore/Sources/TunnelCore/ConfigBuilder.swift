import Foundation

/// Tunnel behaviour that is written into the sing-box configuration.
public struct TunnelOptions: Codable, Equatable, Sendable {
    /// Reject domains of the bundled ad list.
    public var adBlocking = true
    /// Russian domains and addresses go outside the VPN.
    public var bypassRussia = true
    /// Private (LAN) addresses go outside the VPN.
    public var bypassPrivate = true
    /// Resolver for everything that goes through the VPN.
    public var dnsServer = "1.1.1.1"
    public var dnsStrategy = "prefer_ipv4"
    public var logLevel = "info"
    /// Start on the `auto` group (lowest delay) instead of the chosen server.
    public var autoSelect = false

    public init() {}
}

/// Builds the sing-box configuration the packet tunnel runs: one subscription,
/// all of its servers behind the `proxy` selector, so the server can be changed
/// in the running tunnel without restarting it.
public enum ConfigBuilder {
    public static let selectorTag = "proxy"
    public static let autoTag = "auto"
    public static let probeURL = "https://www.gstatic.com/generate_204"

    /// Bundled rule sets: tag → file name inside the extension's `Rules` folder.
    public enum RuleSet {
        public static let adBlock = "pt-ad-block"
        public static let russia = ["pt-ru-domains", "pt-ru-inside", "pt-ru-ip"]
        public static let files: [String: String] = [
            "pt-ad-block": "ad-block.srs", "pt-ru-domains": "ru-domains.srs",
            "pt-ru-inside": "ru-inside.srs", "pt-ru-ip": "ru-ip.srs",
        ]
        /// Marks a path the extension must point at its own bundle.
        public static let pathPrefix = "@rules/"
    }

    public static func build(subscription: Subscription, selected: String?, options: TunnelOptions) throws -> JSONValue {
        let nodes = subscription.nodes
        guard !nodes.isEmpty else { throw ImportError("В подписке «\(subscription.name)» нет серверов.") }

        var outbounds: [JSONValue] = []
        var endpoints: [JSONValue] = []
        var seen = Set<String>(TagAllocator.reserved)
        var selectable: [String] = []
        var leaves: [String] = []
        var mtus: [Int] = []

        func add(_ object: JSONValue) throws {
            guard let tag = object["tag"]?.stringValue, !tag.isEmpty, let type = object["type"]?.stringValue else {
                throw ImportError("У сервера нет тега или типа: конфигурация повреждена.")
            }
            guard seen.insert(tag).inserted else { throw ImportError("Два сервера с одним именем «\(tag)».") }
            if ServerNode.endpointTypes.contains(type.lowercased()) {
                endpoints.append(object)
                if let mtu = object["mtu"]?.intValue, mtu > 0 { mtus.append(mtu) }
            } else {
                outbounds.append(object)
            }
        }

        for node in nodes {
            try add(node.outbound)
            for member in node.members { try add(member) }
            selectable.append(node.id)
            if !node.isGroup { leaves.append(node.id) }
        }

        let chosen = selected.flatMap { id in selectable.contains(id) ? id : nil } ?? selectable[0]
        let hasAuto = leaves.count > 1
        var groups: [JSONValue] = [[
            "type": "selector",
            "tag": .string(selectorTag),
            "outbounds": JSONValue((hasAuto ? [autoTag] : []) + selectable),
            "default": .string(options.autoSelect && hasAuto ? autoTag : chosen),
            "interrupt_exist_connections": true,
        ]]
        if hasAuto {
            groups.append([
                "type": "urltest",
                "tag": .string(autoTag),
                "outbounds": JSONValue(leaves),
                "url": .string(probeURL),
                "interval": "3m",
                "tolerance": 150,
                "idle_timeout": "30m",
                "interrupt_exist_connections": false,
            ])
        }

        var ruleSets: [JSONValue] = []
        var routeRules: [JSONValue] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
        ]
        var dnsRules: [JSONValue] = []
        func local(_ tag: String) -> JSONValue {
            ["tag": .string(tag), "type": "local", "format": "binary", "path": .string(RuleSet.pathPrefix + (RuleSet.files[tag] ?? tag))]
        }
        if options.adBlocking {
            ruleSets.append(local(RuleSet.adBlock))
            let reject: JSONValue = ["rule_set": [.string(RuleSet.adBlock)], "action": "reject", "no_drop": true]
            routeRules.append(reject)
            dnsRules.append(["rule_set": [.string(RuleSet.adBlock)], "action": "reject"])
        }
        if options.bypassPrivate {
            routeRules.append(["ip_is_private": true, "outbound": "direct"])
        }
        if options.bypassRussia {
            ruleSets.append(contentsOf: RuleSet.russia.map(local))
            routeRules.append(["rule_set": JSONValue(RuleSet.russia), "outbound": "direct"])
            // Names that leave the tunnel are resolved outside it as well.
            dnsRules.append(["rule_set": ["pt-ru-domains", "pt-ru-inside"], "server": "dns-direct"])
        }

        var route: [String: JSONValue] = [
            "auto_detect_interface": true,
            // Server addresses are resolved outside the tunnel, or it could not start.
            "default_domain_resolver": ["server": "dns-direct", "strategy": .string(options.dnsStrategy)],
            "rules": .array(routeRules),
            "final": .string(selectorTag),
        ]
        if !ruleSets.isEmpty { route["rule_set"] = .array(ruleSets) }

        var dns: [String: JSONValue] = [
            "servers": [
                // Everything apps ask is resolved through the VPN: nothing leaks to the local network.
                ["type": "https", "tag": "dns-remote", "server": .string(options.dnsServer), "detour": .string(selectorTag)],
                ["type": "udp", "tag": "dns-direct", "server": .string(options.dnsServer)],
            ],
            "final": "dns-remote",
            "strategy": .string(options.dnsStrategy),
        ]
        if !dnsRules.isEmpty { dns["rules"] = .array(dnsRules) }

        var config: [String: JSONValue] = [
            "log": ["level": .string(options.logLevel), "timestamp": true],
            "dns": .object(dns),
            "inbounds": [[
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                "mtu": .int(Int64(mtus.min() ?? 1500)),
                "auto_route": true,
                "strict_route": true,
                "stack": "gvisor",
            ]],
            "outbounds": .array(groups + outbounds + [["type": "direct", "tag": "direct"]]),
            "route": .object(route),
        ]
        if !endpoints.isEmpty { config["endpoints"] = .array(endpoints) }
        return .object(config)
    }

    /// Points bundled rule sets at the folder that holds them on this device.
    public static func relocateRuleSets(in config: JSONValue, directory: String) -> JSONValue {
        guard var route = config["route"], let sets = route["rule_set"]?.arrayValue else { return config }
        let base = directory.hasSuffix("/") ? directory : directory + "/"
        route["rule_set"] = .array(sets.map { set in
            guard let path = set["path"]?.stringValue, path.hasPrefix(RuleSet.pathPrefix) else { return set }
            var set = set
            set["path"] = .string(base + path.dropFirst(RuleSet.pathPrefix.count))
            return set
        })
        var config = config
        config["route"] = route
        return config
    }

    /// Tags the selector offers, in order (without the `auto` group).
    public static func selectableTags(of subscription: Subscription) -> [String] {
        subscription.nodes.map(\.id)
    }
}
