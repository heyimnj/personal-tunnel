import Foundation

/// Tunnel behaviour that is written into the sing-box configuration.
public struct TunnelOptions: Codable, Equatable, Sendable {
    /// Reject domains of the bundled ad list.
    public var adBlocking = true
    /// Which bundled ad list (3.0.5): `basic` (HaGeZi Light), `standard` (HaGeZi
    /// Pro, the default) or `extended` (HaGeZi Pro++); each with geosite ads and
    /// the Russian and mobile ad servers of AdGuard's filters.
    public var adBlockLevel = AdBlockLevel.standard
    /// With ad blocking: apps' own encrypted DNS (DoH, DoT, DoQ) and iCloud
    /// Private Relay are refused, so their names go through the tunnel's DNS and
    /// its blocking instead of around it (3.0.5).
    public var blockEncryptedDNS = true
    /// Russian domains and addresses go outside the VPN.
    public var bypassRussia = true
    /// Private (LAN) addresses go outside the VPN.
    public var bypassPrivate = true
    /// Resolver for everything that goes through the VPN.
    public var dnsServer = "1.1.1.1"
    /// 3.3 (PT-09): resolvers outside the tunnel (server addresses), asked over
    /// DNS over HTTPS by address: a setting (`DirectResolvers.presets`).
    public var directResolvers = DirectResolvers.defaultAddresses
    public var dnsStrategy = "prefer_ipv4"
    /// 3.3 (PT-16): «warn» by default — at «info» the core writes every
    /// connection with its destination. «info» only for a diagnostic half hour
    /// (`expireDiagnosticLog`), «trace» for «Подробный журнал».
    public var logLevel = "warn"
    /// Start on the `auto` group (lowest delay) instead of the chosen server.
    public var autoSelect = false
    /// Addresses of servers whose traffic leaves the tunnel (3.1.2). 3.3 (PT-06):
    /// the app no longer fills it — every app's traffic to those addresses went
    /// around the VPN (a CDN address took whole sites with it). The app's own
    /// core is bound to the physical interface instead (`probe(…interface:)`).
    /// Kept as the fallback for a device where that binding does not work.
    public var serverHosts: [String] = []
    /// Hosts of the subscriptions' addresses (3.1.6): fetched through the VPN even
    /// when the Russian bypass would send them outside it. A panel blocked from
    /// the local network (lvi.su, say) timed out there, so a subscription could
    /// not be updated with the VPN on.
    public var subscriptionHosts: [String] = []

    public init() {}
}

public enum AdBlockLevel: String, Codable, CaseIterable, Sendable {
    case basic, standard, extended

    /// The bundled rule sets this level blocks with. Each HaGeZi list contains
    /// the smaller ones, so a level loads only its own.
    public var ruleSets: [String] {
        let common = [ConfigBuilder.RuleSet.adBlock, ConfigBuilder.RuleSet.adRegional]
        switch self {
        case .basic: return common + [ConfigBuilder.RuleSet.adBasic]
        case .standard: return common + [ConfigBuilder.RuleSet.adStandard]
        case .extended: return common + [ConfigBuilder.RuleSet.adExtended]
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
        /// geosite category-ads-all.
        public static let adBlock = "pt-ad-block"
        /// Russian and mobile ad servers from AdGuard's filters (3.0.5).
        public static let adRegional = "pt-ad-ru"
        /// HaGeZi Light, Pro and Pro++ (3.0.5; standard was Light, extended Normal).
        public static let adBasic = "pt-ad-basic"
        public static let adStandard = "pt-ad-standard"
        public static let adExtended = "pt-ad-extended"
        /// HaGeZi Encrypted DNS Bypass: DoH/DoT servers and iCloud Private Relay.
        public static let encryptedDNS = "pt-doh"
        public static let russia = ["pt-ru-domains", "pt-ru-inside", "pt-ru-ip"]
        public static let files: [String: String] = [
            "pt-ad-block": "ad-block.srs", "pt-ad-ru": "ad-ru.srs", "pt-ad-basic": "ad-light.srs",
            "pt-ad-standard": "ad-standard.srs", "pt-ad-extended": "ad-extended.srs", "pt-doh": "doh.srs",
            "pt-ru-domains": "ru-domains.srs",
            "pt-ru-inside": "ru-inside.srs", "pt-ru-ip": "ru-ip.srs",
        ]
        /// Public resolvers apps reach by address for DNS over HTTPS/TLS/QUIC.
        public static let encryptedDNSAddresses = [
            "1.1.1.1/32", "1.0.0.1/32", "2606:4700:4700::1111/128", "2606:4700:4700::1001/128",
            "8.8.8.8/32", "8.8.4.4/32", "2001:4860:4860::8888/128", "2001:4860:4860::8844/128",
            "9.9.9.9/32", "149.112.112.112/32", "2620:fe::fe/128", "2620:fe::9/128",
            "94.140.14.14/32", "94.140.15.15/32", "2a10:50c0::ad1:ff/128", "2a10:50c0::ad2:ff/128",
            "208.67.222.222/32", "208.67.220.220/32", "77.88.8.8/32", "77.88.8.1/32",
        ]
        /// Marks a path the extension must point at its own bundle.
        public static let pathPrefix = "@rules/"
    }

    /// `xrayInstance`: the Xray-core instance (in the same process) the
    /// Xray-backed servers' `xray-local` outbounds hand connections to.
    public static func build(subscription: Subscription, selected: String?, options: TunnelOptions,
                             xrayInstance: String = XrayBacked.tunnelInstance) throws -> JSONValue {
        // 3.1.14: servers saved before they were moved into Xray-core go there too.
        let nodes = subscription.nodes.map(XrayBacked.promoted)
        // Xray-backed servers become `xray-local` outbounds into the Xray instance beside sing-box.
        let xrayInbounds = XrayBacked.inbounds(for: nodes)
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
            var main = CertificatePins.carry(link: node.link, into: Carried.adapt(node.outbound, known: known))
            var members = node.members
            if node.type == XrayBacked.type {
                guard let inbound = xrayInbounds[node.id] else { continue }
                main = XrayBacked.local(tag: node.id, instance: xrayInstance, inbound: inbound)
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
        // 3.1.6: the `auto` group only with automatic selection: otherwise it tested
        // every server in the background for nothing.
        let hasAuto = options.autoSelect && leaves.count > 1
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
        let probe = Self.splitHosts(options.serverHosts)
        if !probe.domains.isEmpty {
            // Before sniffing: the name is the one the app asked for (the tunnel's
            // DNS remembers which address it gave), not the SNI a REALITY server
            // borrows.
            routeRules.insert(["domain": JSONValue(probe.domains), "outbound": "direct"], at: 0)
            dnsRules.append(["domain": JSONValue(probe.domains), "server": "dns-direct"])
        }
        if !probe.addresses.isEmpty {
            routeRules.insert(["ip_cidr": JSONValue(probe.addresses), "outbound": "direct"], at: probe.domains.isEmpty ? 0 : 1)
        }
        let panels = Self.splitHosts(options.subscriptionHosts)
        if !panels.domains.isEmpty || !panels.addresses.isEmpty {
            var rule: [String: JSONValue] = ["outbound": .string(selectorTag)]
            if !panels.domains.isEmpty { rule["domain"] = JSONValue(panels.domains) }
            if !panels.addresses.isEmpty { rule["ip_cidr"] = JSONValue(panels.addresses) }
            // First of all: before the servers' own direct rules and any bypass.
            routeRules.insert(.object(rule), at: 0)
            if !panels.domains.isEmpty { dnsRules.insert(["domain": JSONValue(panels.domains), "server": "dns-remote"], at: 0) }
        }
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
            if options.blockEncryptedDNS {
                // An app or browser with its own encrypted DNS (and Safari through iCloud
                // Private Relay) resolves around the blocking. Its resolver is refused by
                // name, by port (DoT/DoQ) and by the public resolvers' addresses, so it
                // falls back to the system's DNS, which is the tunnel's. The tunnel's own
                // resolver is not affected: it is dialled through the server, not routed.
                ruleSets.append(local(RuleSet.encryptedDNS))
                routeRules.append(["rule_set": [.string(RuleSet.encryptedDNS)], "action": "reject", "no_drop": true])
                routeRules.append(["port": 853, "action": "reject", "no_drop": true])
                routeRules.append(["ip_cidr": JSONValue(RuleSet.encryptedDNSAddresses), "port": [443, 853], "action": "reject", "no_drop": true])
                dnsRules.append(["rule_set": [.string(RuleSet.encryptedDNS)], "query_type": ["A"], "action": "predefined", "answer": ["*. 300 IN A 0.0.0.0"]])
                dnsRules.append(["rule_set": [.string(RuleSet.encryptedDNS)], "query_type": ["AAAA"], "action": "predefined", "answer": ["*. 300 IN AAAA ::"]])
                dnsRules.append(["rule_set": [.string(RuleSet.encryptedDNS)], "action": "predefined", "rcode": "NOERROR"])
            }
        }
        if options.bypassPrivate {
            routeRules.append(["ip_is_private": true, "outbound": "direct"])
        }
        if options.bypassRussia {
            ruleSets.append(contentsOf: RuleSet.russia.map(local))
            routeRules.append(["rule_set": JSONValue(RuleSet.russia), "outbound": "direct"])
            // Names that leave the tunnel are resolved outside it as well: 3.3 (PT-09)
            // by Yandex over DNS over HTTPS, only for these names.
            dnsRules.append(["rule_set": ["pt-ru-domains", "pt-ru-inside"], "server": .string(DirectResolvers.russianTag)])
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
            "servers": .array([
                // Everything apps ask is resolved through the VPN: nothing leaks to the local network.
                // 3.0.5: a group of two ways through the server (the core's `group`).
                // Some servers break DNS over HTTPS to the resolver (they answer it
                // with their own certificate, which the system refuses), and with
                // HTTPS alone no name resolved at all. 3.0.6: mode «parallel» — every
                // name is asked both ways at once and the first answer counts; with
                // «stable» a start that picked the broken way waited 5–10 s for it
                // to fail before the other was asked.
                ["type": "group", "tag": "dns-remote", "servers": ["dns-remote-https", "dns-remote-tcp"], "mode": "parallel"],
                ["type": "https", "tag": "dns-remote-https", "server": .string(options.dnsServer), "detour": .string(selectorTag)],
                ["type": "tcp", "tag": "dns-remote-tcp", "server": .string(options.dnsServer), "detour": .string(selectorTag)],
            ] + directResolvers(options) + (options.bypassRussia ? [DirectResolvers.russian] : [])),
            "final": "dns-remote",
            "strategy": .string(options.dnsStrategy),
        ]
        if !dnsRules.isEmpty { dns["rules"] = .array(dnsRules) }
        // Which name each address was given for, so connections to a server's
        // address are known by the server's name (see `serverHosts`).
        if !probe.domains.isEmpty || !panels.domains.isEmpty { dns["reverse_mapping"] = true }

        var config: [String: JSONValue] = [
            "log": ["level": .string(options.logLevel), "timestamp": true],
            // 3.1.0: certificates are checked as Xray-core checks them (Happ and
            // the other clients): against Mozilla's roots, by Go. Without a store
            // the core hands the check to iOS, whose stricter rules turned down
            // servers the other clients reach («certificate is not standards
            // compliant»: a validity period, a missing Certificate Transparency
            // proof). The probe configuration below keeps it.
            "certificate": ["store": "mozilla"],
            "dns": .object(dns),
            "inbounds": [[
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                "mtu": .int(Int64(mtus.min() ?? 1500)),
                "auto_route": true,
                "strict_route": true,
                // 3.1.6: the core's default — TCP through the system's own stack, UDP
                // through gVisor. gVisor for everything cost much more CPU (battery).
                "stack": "mixed",
            ]],
            "outbounds": .array(groups + outbounds + [["type": "direct", "tag": "direct"]]),
            "route": .object(route),
        ]
        if !endpoints.isEmpty { config["endpoints"] = .array(endpoints) }
        return .object(config)
    }

    /// What the tunnel runs (3.1.6): the chosen server alone (with any servers it
    /// is made of), unless automatic selection is on. A server is changed by
    /// reconnecting anyway; keeping every server of a 200-server subscription in
    /// the tunnel cost memory (each outbound, and Xray-core's) and battery (the
    /// `auto` group tested them all in the background). The app tests servers
    /// with its own core.
    public static func tunnelSubscription(_ subscription: Subscription, selected: String?, options: TunnelOptions) -> Subscription {
        guard !options.autoSelect, subscription.nodes.count > 1 else { return subscription }
        let chosen = selected.flatMap { id in subscription.nodes.contains { $0.id == id } ? id : nil } ?? subscription.nodes[0].id
        let byID = Dictionary(subscription.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // A 1.x group refers to other servers by their tags: those come along.
        var keep: [String] = []
        var queue = [chosen]
        while let id = queue.popLast() {
            guard !keep.contains(id), let node = byID[id] else { continue }
            keep.append(id)
            for object in [node.outbound] + node.members {
                let refs = (object["outbounds"]?.stringList ?? []) + [object["detour"]?.stringValue, object["default"]?.stringValue].compactMap { $0 }
                queue.append(contentsOf: refs.filter { byID[$0] != nil })
            }
        }
        var trimmed = subscription
        trimmed.nodes = subscription.nodes.filter { keep.contains($0.id) }
        return trimmed
    }

    /// Every server address of the subscriptions, without repeats (3.1.2).
    public static func serverHosts(of subscriptions: [Subscription]) -> [String] {
        var seen = Set<String>()
        var hosts: [String] = []
        for subscription in subscriptions {
            for node in subscription.nodes {
                guard let host = node.address?.host.lowercased(), !host.isEmpty, !seen.contains(host) else { continue }
                seen.insert(host)
                hosts.append(host)
            }
        }
        return Array(hosts.prefix(4000))
    }

    /// Names apart from addresses (as /32 and /128).
    static func splitHosts(_ hosts: [String]) -> (domains: [String], addresses: [String]) {
        var domains: [String] = []
        var addresses: [String] = []
        for raw in hosts {
            let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
            guard !host.isEmpty else { continue }
            if TextCoding.isIPAddress(host) {
                addresses.append(host.contains(":") ? host + "/128" : host + "/32")
            } else if host.contains(".") {
                domains.append(host)
            }
        }
        return (domains, addresses)
    }

    /// The configuration the app's own core measures servers with, without the VPN:
    /// the same servers as the tunnel's, built the same way, but no tunnel, no rules
    /// and no groups of the app's own (the `auto` group would test on its own timer).
    /// Server addresses resolve through `dns-direct`, as in the tunnel.
    /// `interface`: with the VPN on, the physical interface (Wi-Fi, cellular) every
    /// connection of the app's core is bound to, so it measures the server itself
    /// and not through the tunnel (3.3, PT-06). Nil: the system's routes.
    public static func probe(subscription: Subscription, options: TunnelOptions, interface: String? = nil) throws -> JSONValue {
        var config = try build(subscription: subscription, selected: nil, options: options, xrayInstance: XrayBacked.appInstance(subscription.id))
        let own: Set<String> = [selectorTag, autoTag]
        config["outbounds"] = .array((config["outbounds"]?.arrayValue ?? []).filter { !own.contains($0["tag"]?.stringValue ?? "") })
        config["inbounds"] = nil
        config["log"] = ["level": "error"]
        config["dns"] = [
            "servers": .array(directResolvers(options)),
            "final": "dns-direct",
            "strategy": .string(options.dnsStrategy),
        ]
        var route: JSONValue = [
            "default_domain_resolver": ["server": "dns-direct", "strategy": .string(options.dnsStrategy)],
            "final": "direct",
        ]
        if let interface, !interface.isEmpty { route["default_interface"] = .string(interface) }
        config["route"] = route
        return config
    }

    /// `dns-direct`: the resolver outside the tunnel, for server addresses. 3.0.6:
    /// a group asking several at once — with one resolver a lost answer left a
    /// server's address unknown and its ping read «lookup …: context deadline
    /// exceeded». 3.3 (PT-09): over DNS over HTTPS by address, without a detour
    /// (plain UDP showed the network which VPN servers the device used), and only
    /// the resolvers of the setting: Yandex no longer sees every server name.
    static func directResolvers(_ options: TunnelOptions) -> [JSONValue] {
        var addresses: [String] = []
        for address in options.directResolvers where !address.isEmpty && !addresses.contains(address) { addresses.append(address) }
        if addresses.isEmpty { addresses = DirectResolvers.defaultAddresses }
        let members = addresses.enumerated().map { index, address -> JSONValue in
            DirectResolvers.https(tag: "dns-direct-\(index + 1)", address: address)
        }
        let group: JSONValue = ["type": "group", "tag": "dns-direct", "servers": .array(members.map { $0["tag"] ?? .null }), "mode": "parallel"]
        return [group] + members
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

            if let tls = fields["tls"] { fields["tls"] = realityFingerprint(tls) }

            let type = fields["type"]?.stringValue?.lowercased() ?? ""
            if type == "selector" || type == "urltest", let members = fields["outbounds"] {
                let kept = members.stringList.filter { $0 != tag && known.contains($0) }
                fields["outbounds"] = JSONValue(kept)
                if let preferred = fields["default"]?.stringValue, !kept.contains(preferred) { fields["default"] = nil }
            }
            return .object(fields)
        }

        /// uTLS fingerprints that carry the hybrid key share `X25519MLKEM768` in
        /// the pinned core. Beta (sing-box-lx 1.14.4-lx.35, utls-lx, SPEC 086):
        /// Chrome's and Firefox 148; the others still go out as Chrome.
        static let hybridFingerprints: Set<String> = ["chrome", "firefox"]

        /// 3.1.10: a REALITY server takes Chrome's fingerprint. Xray-core v26.9.8 and
        /// later (XTLS/REALITY@8cdf7bf) silently hand a ClientHello without the
        /// hybrid key share to the cover site; in the pinned core `firefox` is
        /// Firefox 120 without it (sing-box-lx SPEC 086 fixes it in a later core).
        /// The client then got the cover site's certificate: «x509: … certificate
        /// is not standards compliant» or «reality verification failed», while
        /// Happ (Xray-core, its Firefox has the share) connected. The fingerprint
        /// only shapes the ClientHello: the server accepts any browser's.
        static func realityFingerprint(_ tls: JSONValue) -> JSONValue {
            guard tls["reality"]?["enabled"]?.boolValue == true else { return tls }
            let current = tls["utls"]?["fingerprint"]?.stringValue?.lowercased() ?? ""
            guard !hybridFingerprints.contains(current) else { return tls }
            var tls = tls
            var utls = tls["utls"]?.objectValue ?? [:]
            utls["enabled"] = true
            utls["fingerprint"] = "chrome"
            tls["utls"] = .object(utls)
            return tls
        }
    }

    /// 3.3 (PT-16): how long «Подробный журнал для диагностики» lasts.
    public static let diagnosticLogDuration: TimeInterval = 30 * 60

    /// The diagnostic «info» level ends by itself: a configuration at «info» whose
    /// half hour is over (or was never started) runs at «warn». The extension
    /// applies it at every start and reload, so it holds even when the app is
    /// not running. Other levels are left as they are.
    public static func expireDiagnosticLog(in config: JSONValue, until: Date?, now: Date = Date()) -> JSONValue {
        guard config.at("log", "level")?.stringValue == "info" else { return config }
        if let until, until > now { return config }
        var config = config
        var log = config["log"] ?? .object([:])
        log["level"] = "warn"
        config["log"] = log
        return config
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

    /// The TUN stack for the system's «include all networks» (3.1.7). The kill
    /// switch turns it on, and sing-tun refuses the `system` and `mixed` stacks
    /// then (sing-tun issue 25): 3.1.6 asked for `mixed` and the tunnel stopped
    /// right after «connecting» on every server. gVisor works either way; without
    /// the kill switch the configuration keeps its own stack.
    public static func stackForIncludeAllNetworks(in config: JSONValue, includeAllNetworks: Bool) -> JSONValue {
        guard includeAllNetworks, let inbounds = config["inbounds"]?.arrayValue else { return config }
        var config = config
        config["inbounds"] = .array(inbounds.map { inbound in
            guard inbound["type"]?.stringValue == "tun" else { return inbound }
            var inbound = inbound
            inbound["stack"] = "gvisor"
            return inbound
        })
        return config
    }

    /// The Xray configuration beside sing-box, when the subscription has servers
    /// only Xray-core can run: the tunnel's, or the app's own for measuring.
    public static func xrayRuntime(subscription: Subscription, instance: String = XrayBacked.tunnelInstance) -> JSONValue? {
        XrayBacked.runtime(subscription.nodes.map(XrayBacked.promoted), instance: instance)
    }

    /// sing-box's configuration and the Xray one beside it.
    public static func tunnel(subscription: Subscription, selected: String?, options: TunnelOptions) throws -> (config: JSONValue, xray: JSONValue?) {
        (try build(subscription: subscription, selected: selected, options: options), xrayRuntime(subscription: subscription))
    }

    /// Tags the selector offers, in order (without the `auto` group).
    public static func selectableTags(of subscription: Subscription) -> [String] {
        subscription.nodes.map(\.id)
    }
}

/// 3.3 (PT-09): the resolvers outside the tunnel, as a setting.
public enum DirectResolvers {
    public static let defaultPreset = "cloudflare-google"
    public static let defaultAddresses = ["1.1.1.1", "8.8.8.8"]
    /// Preset id → addresses, in the order the setting lists them.
    public static let presets: [(id: String, addresses: [String])] = [
        ("cloudflare-google", defaultAddresses),
        ("cloudflare", ["1.1.1.1", "1.0.0.1"]),
        ("google", ["8.8.8.8", "8.8.4.4"]),
        ("quad9", ["9.9.9.9", "149.112.112.112"]),
        ("yandex", ["77.88.8.8", "77.88.8.1"]),
    ]

    public static func addresses(_ preset: String) -> [String] {
        presets.first { $0.id == preset }?.addresses ?? defaultAddresses
    }

    /// Resolvers whose certificate names a host, not the address.
    static let certificateNames = ["77.88.8.8": "common.dot.dns.yandex.net", "77.88.8.1": "common.dot.dns.yandex.net"]

    static func https(tag: String, address: String) -> JSONValue {
        var server: [String: JSONValue] = ["type": "https", "tag": .string(tag), "server": .string(address)]
        if let name = certificateNames[address] { server["tls"] = ["enabled": true, "server_name": .string(name)] }
        return .object(server)
    }

    /// Russian names that leave the tunnel (the bypass): Yandex, over HTTPS.
    static let russianTag = "dns-ru"
    static var russian: JSONValue { https(tag: russianTag, address: "77.88.8.8") }
}
