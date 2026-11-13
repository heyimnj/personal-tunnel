import Foundation

/// Tunnel behaviour that is written into the sing-box configuration.
public struct TunnelOptions: Codable, Equatable, Sendable {
    /// Reject domains of the bundled ad list.
    public var adBlocking = true
    /// Which bundled ad list: `basic` (geosite ads, as before 3.0), `standard`
    /// (+ HaGeZi Light, the default) or `extended` (+ HaGeZi Normal).
    public var adBlockLevel = AdBlockLevel.standard
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

public enum AdBlockLevel: String, Codable, CaseIterable, Sendable {
    case basic, standard, extended

    /// The bundled rule sets this level blocks with.
    public var ruleSets: [String] {
        switch self {
        case .basic: return [ConfigBuilder.RuleSet.adBlock]
        case .standard: return [ConfigBuilder.RuleSet.adBlock, ConfigBuilder.RuleSet.adStandard]
        case .extended: return [ConfigBuilder.RuleSet.adBlock, ConfigBuilder.RuleSet.adExtended]
        }
    }
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
        public static let adStandard = "pt-ad-standard"
        public static let adExtended = "pt-ad-extended"
        public static let russia = ["pt-ru-domains", "pt-ru-inside", "pt-ru-ip"]
        public static let files: [String: String] = [
            "pt-ad-block": "ad-block.srs", "pt-ad-standard": "ad-standard.srs", "pt-ad-extended": "ad-extended.srs",
            "pt-ru-domains": "ru-domains.srs",
            "pt-ru-inside": "ru-inside.srs", "pt-ru-ip": "ru-ip.srs",
        ]
        /// Marks a path the extension must point at its own bundle.
        public static let pathPrefix = "@rules/"
    }

    public static func build(subscription: Subscription, selected: String?, options: TunnelOptions,
                             xrayPortBase: Int = XrayBacked.tunnelPortBase) throws -> JSONValue {
        let nodes = subscription.nodes
        // Xray-backed servers become SOCKS hops to the Xray instance beside sing-box.
        let xrayPorts = XrayBacked.runtime(nodes, portBase: xrayPortBase)?.ports ?? [:]
        guard !nodes.isEmpty else { throw ImportError(CoreText.f("В подписке «%@» нет серверов.", "\(subscription.name)")) }

        var outbounds: [JSONValue] = []
        var endpoints: [JSONValue] = []
        var added: [String: JSONValue] = [:]
        var selectable: [String] = []
        var leaves: [String] = []
        var mtus: [Int] = []

        func add(_ object: JSONValue) throws {
            guard let tag = object["tag"]?.stringValue, !tag.isEmpty, let type = object["type"]?.stringValue else {
                throw ImportError(CoreText.t("У сервера нет тега или типа: конфигурация повреждена."))
            }
            guard !TagAllocator.reserved.contains(tag) else { throw ImportError(CoreText.f("Имя сервера «%@» занято самой конфигурацией.", "\(tag)")) }
            if let existing = added[tag] {
                // 1.x kept every outbound once, so two servers may share a supporting one.
                if existing == object { return }
                throw ImportError(CoreText.f("Два сервера с одним именем «%@».", "\(tag)"))
            }
            added[tag] = object
            if ServerNode.endpointTypes.contains(type.lowercased()) {
                endpoints.append(object)
                if let mtu = object["mtu"]?.intValue, mtu > 0 { mtus.append(mtu) }
            } else {
                outbounds.append(object)
            }
        }

        // Every tag the servers bring, so references can be checked before anything is added.
        var known: Set<String> = ["direct"]
        for node in nodes {
            for object in [node.outbound] + node.members {
                if let tag = object["tag"]?.stringValue, !tag.isEmpty { known.insert(tag) }
            }
        }

        // 1.x wrapped every server in a location group of one. Such a group is
        // replaced by its server under the group's tag, so it counts as a server:
        // the `auto` group and automatic selection see it.
        var unwrapped: [String: (leaf: String, object: JSONValue)] = [:]
        var leafOwners: [String: Int] = [:]
        for node in nodes where node.isGroup {
            let members = Carried.adapt(node.outbound, known: known)["outbounds"]?.stringList ?? []
            guard members.count == 1, let leaf = node.members.first(where: { $0["tag"]?.stringValue == members[0] }),
                  !["selector", "urltest"].contains(leaf["type"]?.stringValue?.lowercased() ?? "") else { continue }
            unwrapped[node.id] = (members[0], leaf)
            leafOwners[members[0], default: 0] += 1
        }
        // A server two groups share stays where it is.
        unwrapped = unwrapped.filter { leafOwners[$0.value.leaf] == 1 && unwrapped[$0.value.leaf] == nil }
        let renamed = Dictionary(uniqueKeysWithValues: unwrapped.map { ($0.value.leaf, $0.key) })
        func relink(_ object: JSONValue) -> JSONValue {
            guard !renamed.isEmpty else { return object }
            var object = object
            if let members = object["outbounds"]?.stringList, !members.isEmpty {
                var seen = Set<String>()
                object["outbounds"] = JSONValue(members.map { renamed[$0] ?? $0 }.filter { seen.insert($0).inserted })
            }
            for key in ["detour", "default"] {
                if let target = object[key]?.stringValue, let next = renamed[target] { object[key] = .string(next) }
            }
            return object
        }

        for node in nodes {
            var main = Carried.adapt(node.outbound, known: known)
            var members = node.members
            if node.type == XrayBacked.type {
                guard let port = xrayPorts[node.id] else { continue }
                main = XrayBacked.socks(tag: node.id, port: port)
                members = []
            }
            if let unwrap = unwrapped[node.id] {
                main = Carried.adapt(unwrap.object, known: known)
                main["tag"] = .string(node.id)
                members.removeAll { $0["tag"]?.stringValue == unwrap.leaf }
            }
            // A provider group none of whose members survived cannot carry traffic.
            let group = ["selector", "urltest"].contains(main["type"]?.stringValue?.lowercased() ?? "")
            if group, (main["outbounds"]?.stringList ?? []).isEmpty { continue }
            try add(relink(main))
            for member in members {
                // Unwrapped groups and their servers are written once, by their own node.
                guard let tag = member["tag"]?.stringValue, unwrapped[tag] == nil, renamed[tag] == nil else { continue }
                try add(relink(Carried.adapt(member, known: known)))
            }
            guard !selectable.contains(node.id) else { continue }
            selectable.append(node.id)
            if !group { leaves.append(node.id) }
        }
        guard !selectable.isEmpty else { throw ImportError(CoreText.f("В подписке «%@» нет рабочих серверов.", "\(subscription.name)")) }

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
            // Ad rules come first after DNS: before any bypass, as in Anywhere's Purify.
            let sets = options.adBlockLevel.ruleSets
            ruleSets.append(contentsOf: sets.map(local))
            routeRules.append(["rule_set": JSONValue(sets), "action": "reject", "no_drop": true])
            // A blocked name resolves to 0.0.0.0 / :: (an answer, not a refusal: apps
            // that retry on a refusal give up at once), other record types to nothing.
            dnsRules.append(["rule_set": JSONValue(sets), "query_type": ["A"], "action": "predefined", "answer": ["*. 300 IN A 0.0.0.0"]])
            dnsRules.append(["rule_set": JSONValue(sets), "query_type": ["AAAA"], "action": "predefined", "answer": ["*. 300 IN AAAA ::"]])
            dnsRules.append(["rule_set": JSONValue(sets), "action": "predefined", "rcode": "NOERROR"])
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

    /// The configuration the app's own core measures servers with, without the VPN:
    /// the same servers as the tunnel's, built the same way, but no tunnel, no rules
    /// and no groups of the app's own (the `auto` group would test on its own timer).
    /// Server addresses resolve through `dns-direct`, as in the tunnel.
    public static func probe(subscription: Subscription, options: TunnelOptions, xrayPortBase: Int = XrayBacked.appPortBase) throws -> JSONValue {
        var config = try build(subscription: subscription, selected: nil, options: options, xrayPortBase: xrayPortBase)
        let own: Set<String> = [selectorTag, autoTag]
        config["outbounds"] = .array((config["outbounds"]?.arrayValue ?? []).filter { !own.contains($0["tag"]?.stringValue ?? "") })
        config["inbounds"] = nil
        config["log"] = ["level": "error"]
        config["dns"] = [
            "servers": [["type": "udp", "tag": "dns-direct", "server": .string(options.dnsServer)]],
            "final": "dns-direct",
            "strategy": .string(options.dnsStrategy),
        ]
        config["route"] = [
            "default_domain_resolver": ["server": "dns-direct", "strategy": .string(options.dnsStrategy)],
            "final": "direct",
        ]
        return config
    }

    /// Servers keep fields that point into the configuration they came from:
    /// 1.x wrote `domain_resolver: dns-local` into every server, provider files
    /// name their own DNS servers and detour outbounds. sing-box refuses to start
    /// on a reference it cannot find, so they are rewritten to this configuration.
    enum Carried {
        /// The resolver server addresses use: outside the tunnel, or it could not start.
        static let resolver = "dns-direct"

        static func adapt(_ object: JSONValue, known: Set<String>) -> JSONValue {
            guard var fields = object.objectValue else { return object }
            let tag = fields["tag"]?.stringValue

            // `domain_strategy` in dial fields is gone from sing-box 1.14: carry its strategy over.
            let legacyStrategy = fields.removeValue(forKey: "domain_strategy")?.stringValue
            switch fields["domain_resolver"] {
            case .string?:
                fields["domain_resolver"] = .string(resolver)
            case var .object(options)?:
                options["server"] = .string(resolver)
                if options["strategy"] == nil, let legacyStrategy, !legacyStrategy.isEmpty { options["strategy"] = .string(legacyStrategy) }
                fields["domain_resolver"] = .object(options)
            case nil:
                if let legacyStrategy, !legacyStrategy.isEmpty {
                    fields["domain_resolver"] = ["server": .string(resolver), "strategy": .string(legacyStrategy)]
                }
            default:
                fields["domain_resolver"] = nil
            }

            if let detour = fields["detour"] {
                let target = detour.stringValue ?? ""
                if target.isEmpty || target == tag || !known.contains(target) { fields["detour"] = nil }
            }

            let type = fields["type"]?.stringValue?.lowercased() ?? ""
            if type == "selector" || type == "urltest", let members = fields["outbounds"] {
                let kept = members.stringList.filter { $0 != tag && known.contains($0) }
                fields["outbounds"] = JSONValue(kept)
                if let preferred = fields["default"]?.stringValue, !kept.contains(preferred) { fields["default"] = nil }
            }
            return .object(fields)
        }
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

    /// The Xray configuration the tunnel runs beside sing-box, when the subscription
    /// has servers only Xray-core can run.
    public static func xrayRuntime(subscription: Subscription, portBase: Int = XrayBacked.tunnelPortBase) -> JSONValue? {
        XrayBacked.runtime(subscription.nodes, portBase: portBase)?.config
    }

    /// Tags the selector offers, in order (without the `auto` group).
    public static func selectableTags(of subscription: Subscription) -> [String] {
        subscription.nodes.map(\.id)
    }
}
