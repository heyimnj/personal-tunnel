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
    /// 3.5.17 (battery): QUIC (UDP/443) that would go through the server is refused
    /// at once, and apps (YouTube, TikTok, browsers) take HTTPS over TCP instead:
    /// QUIC through the tunnel goes through the core's own network stack and then
    /// inside the server's TCP connection — far more work per megabyte. QUIC that
    /// leaves outside the VPN (the Russian bypass, the local network) is untouched.
    public var blockQUIC = true
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

/// 3.2.7: the tunnel's way out for the app's own measuring core while the kill
/// switch is on. iOS then lets nothing go around the tunnel, so the app's tests
/// went through the connected server: a chain through someone else's server,
/// where Hysteria2 and other UDP servers could not answer at all (Vision refuses
/// UDP/443) and many providers refuse connections to their other servers (EOF,
/// «Reality», «certificate»). The extension listens on loopback with a login and
/// password only the app knows, and sends those connections straight out:
/// no rule opens the tunnel for anyone else's traffic (PT-06 stays closed).
public struct ProbeExit: Equatable, Codable, Sendable {
    public static let inboundTag = "probe-in"
    public static let outboundTag = "probe-exit"
    /// 3.2.8: the tunnel's own direct outbound for the app's tests: a dead server
    /// gives up its dial with the app's first try (the core's default held each
    /// one 5 s), and its UDP mapping is let go after 15 s instead of 5 minutes.
    public static let directTag = "probe-direct"
    public static let connectTimeout = "3s"
    public static let udpTimeout = "15s"
    public static let ports: ClosedRange<Int> = 20000 ... 59999

    public var port: Int
    public var username: String
    public var password: String

    public init(port: Int, username: String, password: String) {
        self.port = port
        self.username = username
        self.password = password
    }
}

/// Builds the sing-box configuration the packet tunnel runs: one subscription,
/// all of its servers behind the `proxy` selector, so the server can be changed
/// in the running tunnel without restarting it.
public enum ConfigBuilder {
    public static let selectorTag = "proxy"
    public static let autoTag = "auto"
    public static let probeURL = "https://www.gstatic.com/generate_204"
    /// 3.5.14 (battery): an automatic group tests its servers at most every ten
    /// minutes (sing-box's default, kept until now, is three: a group of sixteen
    /// servers opened over five TLS connections a minute, all day in the
    /// background while any traffic went through it). Providers' groups too.
    public static let groupInterval: TimeInterval = 600
    static let groupIdleTimeout: TimeInterval = 1800

    /// A sing-box duration («3m», «1m30s», «180s», «1h»), in seconds; nil if not one.
    static func seconds(_ duration: String) -> TimeInterval? {
        let units: [String: TimeInterval] = ["h": 3600, "m": 60, "s": 1, "ms": 0.001, "us": 0.000001, "µs": 0.000001, "ns": 0.000000001]
        var total: TimeInterval = 0
        var rest = Substring(duration.trimmingCharacters(in: .whitespaces))
        guard !rest.isEmpty else { return nil }
        while !rest.isEmpty {
            let number = rest.prefix { $0.isNumber || $0 == "." }
            rest = rest.dropFirst(number.count)
            let unit = rest.prefix { !($0.isNumber || $0 == ".") }
            rest = rest.dropFirst(unit.count)
            guard let value = Double(number), let scale = units[String(unit)] else { return nil }
            total += value * scale
        }
        return total
    }

    static func duration(_ seconds: TimeInterval) -> JSONValue {
        .string(seconds.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(seconds / 60))m" : "\(Int(seconds))s")
    }

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

    /// 3.2.3: the TUN's MTU without WireGuard servers — sing-box's own default in
    /// a Network Extension (4064 = 4096 less utun's headroom; above it utun slows
    /// down). Before, 1500: the same traffic came in 2.7 times as many packets,
    /// and with the kill switch every packet goes through gVisor (battery). The
    /// proxy's own connection to the server keeps the path's MTU: TCP ends in the
    /// core, so the TUN's packets never leave the device as they are.
    ///
    /// 3.2.9: back to 1500. With 4064 the extension's memory stayed at 40–42 MiB
    /// (36 MiB before), right under the core's own limit (42 MiB), where Go
    /// collects garbage all the time; the battery went from 5% for 9.5 h of VPN
    /// (Monday, 1500) to 29% for 7 h (Tuesday, 4064). gVisor keeps each packet
    /// it holds in a buffer of the MTU's size.
    public static let tunMTU = 1500

    /// 3.2.9: how long the tunnel keeps an idle UDP mapping.
    public static let udpTimeout = "1m"

    /// `xrayInstance`: the Xray-core instance (in the same process) the
    /// Xray-backed servers' `xray-local` outbounds hand connections to.
    public static func build(subscription: Subscription, selected: String?, options: TunnelOptions,
                             xrayInstance: String = XrayBacked.tunnelInstance, probeExit: ProbeExit? = nil) throws -> JSONValue {
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
                "interval": duration(groupInterval),
                "tolerance": 150,
                "idle_timeout": duration(groupIdleTimeout),
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
        if options.blockQUIC {
            // After every rule that sends traffic outside the VPN, so only QUIC for
            // the server is refused; a refusal (not a silent drop, `no_drop`) makes
            // the app fall back to TCP at once instead of waiting out its timeout.
            // 3.6.19 (the owner: calls through the VPN on mobile failed): only what the
            // core's sniffing recognised as QUIC. Calls also use UDP/443 (STUN, TURN
            // relays, media), and the rule refused them all.
            routeRules.append(["network": "udp", "port": 443, "protocol": "quic", "action": "reject", "no_drop": true])
        }

        if probeExit != nil {
            // First of all: the app's tests leave as they came, before sniffing
            // (a REALITY server's borrowed name), the bypasses and the panels.
            routeRules.insert(["inbound": [.string(ProbeExit.inboundTag)], "action": "route",
                               "outbound": .string(ProbeExit.directTag), "udp_timeout": .string(ProbeExit.udpTimeout)], at: 0)
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
                // 3.5.22 (the owner): «ordered» (core/patches/0006) — plain DNS over TCP
                // through the server first, DNS over HTTPS only when TCP gave no
                // answer; the failed way is passed over for two minutes. «parallel»
                // asked every name both ways at once.
                ["type": "group", "tag": "dns-remote", "servers": ["dns-remote-tcp", "dns-remote-https"], "mode": "ordered"],
                ["type": "https", "tag": "dns-remote-https", "server": .string(options.dnsServer), "detour": .string(selectorTag)],
                ["type": "tcp", "tag": "dns-remote-tcp", "server": .string(options.dnsServer), "detour": .string(selectorTag)],
            ] + directResolvers(options) + (options.bypassRussia ? DirectResolvers.russian : [])),
            "final": "dns-remote",
            "strategy": .string(options.dnsStrategy),
        ]
        if !dnsRules.isEmpty { dns["rules"] = .array(dnsRules) }
        // Which name each address was given for, so connections to a server's
        // address are known by the server's name (see `serverHosts`).
        if !probe.domains.isEmpty || !panels.domains.isEmpty { dns["reverse_mapping"] = true }

        let tun: JSONValue = [
            "type": "tun",
            "tag": "tun-in",
            "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
            "mtu": .int(Int64(mtus.min() ?? tunMTU)),
            "auto_route": true,
            "strict_route": true,
            // 3.1.6: the core's default — TCP through the system's own stack, UDP
            // through gVisor. gVisor for everything cost much more CPU (battery).
            "stack": "mixed",
            // 3.2.9: a UDP mapping with no packets goes after a minute, not the
            // core's 5: one-off exchanges (DNS, STUN, ended QUIC) no longer hold
            // memory in the extension; live QUIC and calls send far more often.
            "udp_timeout": .string(udpTimeout),
        ]
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
            "inbounds": .array([tun] + (probeExit.map { [probeInbound($0)] } ?? [])),
            "outbounds": .array(groups + outbounds + [["type": "direct", "tag": "direct"]]
                + (probeExit == nil ? [] : [["type": "direct", "tag": .string(ProbeExit.directTag), "connect_timeout": .string(ProbeExit.connectTimeout)]])),
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

    /// 3.2.2: a fingerprint of what the running tunnel is made of: the outbounds of
    /// the servers it runs (`tunnelSubscription`) and which one is chosen. Names,
    /// share links, the provider's source and the order of servers are left out:
    /// they change nothing in the connection. An updated subscription with the same
    /// fingerprint needs no restart of the core.
    public static func runningFingerprint(_ subscription: Subscription, selected: String?, options: TunnelOptions) -> String {
        let running = tunnelSubscription(subscription, selected: selected, options: options)
        let chosen = selected.flatMap { id in running.nodes.contains { $0.id == id } ? id : nil } ?? running.nodes.first?.id ?? ""
        var parts: [JSONValue] = [.string(options.autoSelect ? "auto" : "single"), .string(chosen)]
        for node in running.nodes.sorted(by: { $0.id < $1.id }) {
            parts.append(.array([.string(node.id), node.outbound] + node.members))
        }
        // FNV-1a, 64 bits: the fingerprint is kept in memory only, never written.
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in JSONValue.array(parts).serialized().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
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
    ///
    /// `exit` (3.2.7): with the kill switch, the tunnel's loopback way out
    /// (`ProbeExit`): every server and the resolvers of server addresses dial
    /// through it, so a test reaches the server itself and not through the
    /// connected one.
    public static func probe(subscription: Subscription, options: TunnelOptions, interface: String? = nil, exit: ProbeExit? = nil) throws -> JSONValue {
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
        if let exit { config = throughProbeExit(config, exit) }
        return config
    }

    /// Outbound types that dial nothing themselves: no detour for them.
    static let notDialing: Set<String> = ["direct", "block", "dns", "selector", "urltest", XrayBacked.localType]

    /// 3.2.7: the probe configuration with every dial through the tunnel's
    /// loopback way out. A server that already goes through another (a chain)
    /// keeps its detour: the first hop goes out this way.
    static func throughProbeExit(_ config: JSONValue, _ exit: ProbeExit) -> JSONValue {
        var config = config
        func detoured(_ item: JSONValue) -> JSONValue {
            guard var fields = item.objectValue else { return item }
            let type = fields["type"]?.stringValue?.lowercased() ?? ""
            guard !notDialing.contains(type), fields["detour"] == nil else { return item }
            fields["detour"] = .string(ProbeExit.outboundTag)
            return .object(fields)
        }
        let socks: JSONValue = [
            "type": "socks",
            "tag": .string(ProbeExit.outboundTag),
            "server": "127.0.0.1",
            "server_port": .int(Int64(exit.port)),
            "version": "5",
            "username": .string(exit.username),
            "password": .string(exit.password),
        ]
        config["outbounds"] = .array((config["outbounds"]?.arrayValue ?? []).map(detoured) + [socks])
        if let endpoints = config["endpoints"]?.arrayValue { config["endpoints"] = .array(endpoints.map(detoured)) }
        if var dns = config["dns"], let servers = dns["servers"]?.arrayValue {
            // Groups ask their members; the members dial.
            dns["servers"] = .array(servers.map { server in
                guard server["type"]?.stringValue != "group" else { return server }
                return detoured(server)
            })
            config["dns"] = dns
        }
        return config
    }

    /// 3.2.7: the extension keeps the app's way out only while iOS holds the kill
    /// switch on; without it the app's core is bound to the physical interface
    /// and needs nothing from the tunnel. `keep: false` also serves a start that failed
    /// on the listener (its port taken).
    public static func probeExit(in config: JSONValue, keep: Bool) -> JSONValue {
        guard !keep, let inbounds = config["inbounds"]?.arrayValue,
              inbounds.contains(where: { $0["tag"]?.stringValue == ProbeExit.inboundTag }) else { return config }
        var config = config
        config["inbounds"] = .array(inbounds.filter { $0["tag"]?.stringValue != ProbeExit.inboundTag })
        if var route = config["route"], let rules = route["rules"]?.arrayValue {
            route["rules"] = .array(rules.filter { $0["inbound"]?.stringList != [ProbeExit.inboundTag] })
            config["route"] = route
        }
        if let outbounds = config["outbounds"]?.arrayValue {
            config["outbounds"] = .array(outbounds.filter { $0["tag"]?.stringValue != ProbeExit.directTag })
        }
        return config
    }

    /// The tunnel's side of the way out: loopback only, with the app's login.
    static func probeInbound(_ exit: ProbeExit) -> JSONValue {
        [
            "type": "socks",
            "tag": .string(ProbeExit.inboundTag),
            "listen": "127.0.0.1",
            "listen_port": .int(Int64(exit.port)),
            "users": [["username": .string(exit.username), "password": .string(exit.password)]],
        ]
    }

    /// Whether a configuration carries the app's way out.
    public static func hasProbeExit(_ config: JSONValue) -> Bool {
        config["inbounds"]?.arrayValue?.contains { $0["tag"]?.stringValue == ProbeExit.inboundTag } ?? false
    }

    /// `dns-direct`: the resolver outside the tunnel, for server addresses. 3.0.6:
    /// a group asking several at once — with one resolver a lost answer left a
    /// server's address unknown and its ping read «lookup …: context deadline
    /// exceeded». 3.3 (PT-09): over DNS over HTTPS by address, without a detour
    /// (plain UDP showed the network which VPN servers the device used), and only
    /// the resolvers of the setting: Yandex no longer sees every server name.
    ///
    /// 3.3 beta 3: on a network that breaks DNS over HTTPS (on the device both
    /// 1.1.1.1 and 8.8.8.8 ended in «EOF», and no server given by name could be
    /// reached), the same resolvers are asked over plain UDP. `dns-direct` is an
    /// `ordered` group (core/patches/0006): HTTPS first; plain DNS only while
    /// HTTPS fails, then HTTPS again once its error has expired (2 minutes).
    static func directResolvers(_ options: TunnelOptions) -> [JSONValue] {
        var addresses: [String] = []
        for address in options.directResolvers where !address.isEmpty && !addresses.contains(address) { addresses.append(address) }
        if addresses.isEmpty { addresses = DirectResolvers.defaultAddresses }
        return DirectResolvers.ordered(tag: "dns-direct", addresses: addresses)
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
            if type == "urltest" {
                // 3.5.14 (battery): no oftener than every ten minutes; the idle timeout
                // must not be shorter (sing-box refuses the group).
                let interval = max(fields["interval"]?.stringValue.flatMap(ConfigBuilder.seconds) ?? 0, ConfigBuilder.groupInterval)
                fields["interval"] = ConfigBuilder.duration(interval)
                if let idle = fields["idle_timeout"]?.stringValue.flatMap(ConfigBuilder.seconds), idle < interval {
                    fields["idle_timeout"] = ConfigBuilder.duration(max(interval, ConfigBuilder.groupIdleTimeout))
                }
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

    /// 3.2.3: the TUN's stack and MTU as the core gets them, for the line the
    /// extension writes at every start («туннель: стек …»).
    public static func tunSummary(of config: JSONValue) -> (stack: String, mtu: Int)? {
        guard let tun = config["inbounds"]?.arrayValue?.first(where: { $0["type"]?.stringValue == "tun" }) else { return nil }
        return (tun["stack"]?.stringValue ?? "?", tun["mtu"]?.intValue ?? 0)
    }

    /// The Xray configuration beside sing-box, when the subscription has servers
    /// only Xray-core can run: the tunnel's, or the app's own for measuring.
    public static func xrayRuntime(subscription: Subscription, instance: String = XrayBacked.tunnelInstance) -> JSONValue? {
        XrayBacked.runtime(subscription.nodes.map(XrayBacked.promoted), instance: instance)
    }

    /// sing-box's configuration and the Xray one beside it.
    public static func tunnel(subscription: Subscription, selected: String?, options: TunnelOptions,
                              probeExit: ProbeExit? = nil) throws -> (config: JSONValue, xray: JSONValue?) {
        (try build(subscription: subscription, selected: selected, options: options, probeExit: probeExit), xrayRuntime(subscription: subscription))
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

    /// Russian names that leave the tunnel (the bypass): Yandex, over HTTPS
    /// (plain DNS while HTTPS fails).
    static let russianTag = "dns-ru"
    static var russian: [JSONValue] { ordered(tag: russianTag, addresses: ["77.88.8.8"]) }

    /// `tag`: an `ordered` group of two `parallel` groups — `tag-https` (every
    /// address over HTTPS) first, `tag-plain` (the same over UDP) as the fallback.
    /// Members are `tag-N` (HTTPS) and `tag-udp-N`.
    static func ordered(tag: String, addresses: [String]) -> [JSONValue] {
        let secure = addresses.enumerated().map { index, address in https(tag: "\(tag)-\(index + 1)", address: address) }
        let plain = addresses.enumerated().map { index, address -> JSONValue in
            ["type": "udp", "tag": .string("\(tag)-udp-\(index + 1)"), "server": .string(address)]
        }
        func group(_ name: String, _ members: [JSONValue], mode: String) -> JSONValue {
            ["type": "group", "tag": .string(name), "servers": .array(members.map { $0["tag"] ?? .null }), "mode": .string(mode)]
        }
        let secureGroup = group("\(tag)-https", secure, mode: "parallel")
        let plainGroup = group("\(tag)-plain", plain, mode: "parallel")
        return [group(tag, [secureGroup, plainGroup], mode: "ordered"), secureGroup, plainGroup] + secure + plain
    }
}
