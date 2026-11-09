import Foundation

/// The rule sets shipped inside the packet tunnel extension.
public enum BundledRuleSet: String, CaseIterable, Sendable {
    case adBlock = "ad-block"
    case russianDomains = "ru-domains"
    case russianInsideOnly = "ru-inside"
    case russianIPs = "ru-ip"

    public var fileName: String { rawValue + ".srs" }
}

/// A sing-box configuration ready to run, with the outbound tag of every
/// server so the app can switch and test them while the tunnel runs.
public struct BuiltConfiguration: Sendable {
    public var json: String
    public var tags: [UUID: String]
    public var selectedTag: String
    public static let selectorTag = "proxy"
}

public enum ConfigBuildError: Error, CustomStringConvertible, Equatable {
    case noServers
    case selectedServerMissing

    public var description: String {
        switch self {
        case .noServers: return "Нет серверов для подключения. Добавьте подписку или сервер."
        case .selectedServerMissing: return "Выбранный сервер не найден."
        }
    }
}

public enum ConfigBuilder {
    /// The most servers one configuration carries. Each outbound costs memory
    /// in the Network Extension, which iOS limits to about 50 MiB.
    public static let maximumServers = 500

    static let reservedTags: Set<String> = [
        BuiltConfiguration.selectorTag, "direct", "block", "dns-remote", "dns-local", "tun-in",
    ]

    /// - Parameters:
    ///   - servers: the servers of the active subscription, in display order.
    ///   - selected: the server traffic goes through.
    ///   - ruleSetDirectory: directory holding the bundled `.srs` files.
    public static func build(
        servers: [Server],
        selected: UUID,
        options: TunnelOptions,
        ruleSetDirectory: String
    ) throws -> BuiltConfiguration {
        guard !servers.isEmpty else { throw ConfigBuildError.noServers }
        guard let selectedServer = servers.first(where: { $0.id == selected }) else { throw ConfigBuildError.selectedServerMissing }

        // The selected server and favourites first, then the rest up to the cap.
        var included: [Server] = [selectedServer]
        var seen: Set<UUID> = [selectedServer.id]
        for server in servers where server.isFavorite && !seen.contains(server.id) {
            included.append(server)
            seen.insert(server.id)
        }
        for server in servers where !seen.contains(server.id) {
            guard included.count < maximumServers else { break }
            included.append(server)
            seen.insert(server.id)
        }

        var tags: [UUID: String] = [:]
        var usedTags = reservedTags
        var outbounds: [JSON] = []
        var endpoints: [JSON] = []
        var proxyTags: [String] = []
        // Tags follow the display order so they stay stable between builds.
        for server in servers where seen.contains(server.id) {
            let tag = uniqueTag(for: server.name, used: &usedTags)
            tags[server.id] = tag
            var object = server.outbound
            object["tag"] = .string(tag)
            if server.isEndpoint {
                endpoints.append(object)
            } else {
                outbounds.append(object)
            }
            proxyTags.append(tag)
        }
        // Keep the user's order in the selector.
        let orderedTags = servers.compactMap { tags[$0.id] }
        let selectedTag = tags[selectedServer.id]!

        var allOutbounds: [JSON] = [[
            "type": "selector",
            "tag": .string(BuiltConfiguration.selectorTag),
            "outbounds": .strings(orderedTags.isEmpty ? proxyTags : orderedTags),
            "default": .string(selectedTag),
            "interrupt_exist_connections": true,
        ]]
        allOutbounds += outbounds
        allOutbounds.append(["type": "direct", "tag": "direct"])

        var root: [String: JSON] = [
            "log": ["level": .string(options.logLevel.rawValue), "timestamp": true],
            "dns": dns(options),
            "inbounds": [inbound(options)],
            "outbounds": .array(allOutbounds),
            "route": route(options, ruleSetDirectory: ruleSetDirectory),
            "experimental": ["cache_file": ["enabled": true]],
        ]
        if !endpoints.isEmpty { root["endpoints"] = .array(endpoints) }
        return BuiltConfiguration(json: JSON.object(root).serialized(), tags: tags, selectedTag: selectedTag)
    }

    static func uniqueTag(for name: String, used: inout Set<String>) -> String {
        var base = name.trimmed
        if base.isEmpty { base = "server" }
        var candidate = base
        var counter = 2
        while used.contains(candidate) {
            candidate = "\(base) #\(counter)"
            counter += 1
        }
        used.insert(candidate)
        return candidate
    }

    // MARK: Sections

    static func inbound(_ options: TunnelOptions) -> JSON {
        var addresses = ["172.19.0.1/30"]
        if options.ipv6 { addresses.append("fdfe:dcba:9876::1/126") }
        return [
            "type": "tun",
            "tag": "tun-in",
            "address": .strings(addresses),
            "mtu": 9000,
            "auto_route": true,
            "strict_route": true,
            "stack": "gvisor",
        ]
    }

    static func remoteDNSServer(_ options: TunnelOptions) -> JSON {
        var server: [String: JSON]
        if options.dns == .custom, let custom = customDNSServer(options.customDNS) {
            server = custom
        } else {
            server = ["type": "https", "server": .string(options.dns.address)]
        }
        server["tag"] = "dns-remote"
        server["detour"] = .string(BuiltConfiguration.selectorTag)
        return .object(server)
    }

    /// Parses the custom DNS field into a sing-box DNS server object.
    public static func customDNSServer(_ text: String) -> [String: JSON]? {
        let value = text.trimmed
        guard !value.isEmpty else { return nil }
        if let range = value.range(of: "://") {
            let scheme = value[value.startIndex ..< range.lowerBound].lowercased()
            let rest = String(value[range.upperBound...])
            let hostPart = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? rest
            let path = rest.contains("/") ? "/" + (rest.split(separator: "/", maxSplits: 1).last.map(String.init) ?? "") : nil
            guard let authority = Authority.parse(hostPart) else { return nil }
            var object: [String: JSON]
            switch scheme {
            case "https": object = ["type": "https"]
            case "h3": object = ["type": "h3"]
            case "tls": object = ["type": "tls"]
            case "quic": object = ["type": "quic"]
            case "tcp": object = ["type": "tcp"]
            case "udp": object = ["type": "udp"]
            default: return nil
            }
            object["server"] = .string(authority.host)
            if let port = authority.port { object["server_port"] = .int(port) }
            if let path, path != "/", scheme == "https" || scheme == "h3" { object["path"] = .string(path) }
            if !StreamSettings.isIPAddress(authority.host) {
                object["domain_resolver"] = "dns-local"
            }
            return object
        }
        guard let authority = Authority.parse(value) else { return nil }
        var object: [String: JSON] = ["type": "udp", "server": .string(authority.host)]
        if let port = authority.port { object["server_port"] = .int(port) }
        return object
    }

    static func dns(_ options: TunnelOptions) -> JSON {
        var rules: [JSON] = []
        if options.adBlocking {
            rules.append(["rule_set": .strings([BundledRuleSet.adBlock.rawValue]), "action": "reject"])
        }
        let direct = normalizedDomains(options.directDomains)
        if !direct.isEmpty {
            rules.append(["domain_suffix": .strings(direct), "server": "dns-local"])
        }
        let proxied = normalizedDomains(options.proxyDomains)
        if !proxied.isEmpty {
            rules.append(["domain_suffix": .strings(proxied), "server": "dns-remote"])
        }
        if options.bypassRussia {
            rules.append([
                "rule_set": .strings([BundledRuleSet.russianInsideOnly.rawValue, BundledRuleSet.russianDomains.rawValue]),
                "server": "dns-local",
            ])
        }
        var dns: [String: JSON] = [
            "servers": [remoteDNSServer(options), ["type": "local", "tag": "dns-local"]],
            "final": "dns-remote",
            "strategy": .string(options.ipv6 ? "prefer_ipv4" : "ipv4_only"),
        ]
        if !rules.isEmpty { dns["rules"] = .array(rules) }
        return .object(dns)
    }

    static func route(_ options: TunnelOptions, ruleSetDirectory: String) -> JSON {
        var rules: [JSON] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
        ]
        if options.directLocalNetworks {
            rules.append(["ip_is_private": true, "outbound": "direct"])
        }
        var ruleSets: [BundledRuleSet] = []
        if options.adBlocking {
            rules.append(["rule_set": .strings([BundledRuleSet.adBlock.rawValue]), "action": "reject"])
            ruleSets.append(.adBlock)
        }
        let proxied = normalizedDomains(options.proxyDomains)
        if !proxied.isEmpty {
            rules.append(["domain_suffix": .strings(proxied), "outbound": .string(BuiltConfiguration.selectorTag)])
        }
        let direct = normalizedDomains(options.directDomains)
        if !direct.isEmpty {
            rules.append(["domain_suffix": .strings(direct), "outbound": "direct"])
        }
        if options.bypassRussia {
            let russian: [BundledRuleSet] = [.russianInsideOnly, .russianDomains, .russianIPs]
            rules.append(["rule_set": .strings(russian.map(\.rawValue)), "outbound": "direct"])
            ruleSets += russian
        }
        var route: [String: JSON] = [
            "auto_detect_interface": true,
            "default_domain_resolver": ["server": "dns-local", "strategy": .string(options.ipv6 ? "prefer_ipv4" : "ipv4_only")],
            "rules": .array(rules),
            "final": .string(BuiltConfiguration.selectorTag),
        ]
        if !ruleSets.isEmpty {
            let directory = ruleSetDirectory.hasSuffix("/") ? String(ruleSetDirectory.dropLast()) : ruleSetDirectory
            route["rule_set"] = .array(ruleSets.map { set in
                ["tag": .string(set.rawValue), "type": "local", "format": "binary", "path": .string(directory + "/" + set.fileName)]
            })
        }
        return .object(route)
    }

    /// Lower-cased domains without schemes, wildcards or paths.
    public static func normalizedDomains(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            var domain = value.trimmed.lowercased()
            if let range = domain.range(of: "://") { domain = String(domain[range.upperBound...]) }
            domain = String(domain.prefix { $0 != "/" && $0 != ":" })
            while domain.hasPrefix("*.") || domain.hasPrefix(".") { domain = String(domain.drop { $0 == "*" || $0 == "." }) }
            guard !domain.isEmpty, domain.contains(".") || domain.count >= 2, !result.contains(domain) else { continue }
            result.append(domain)
        }
        return result
    }

    /// Points the bundled rule sets of a stored configuration at `directory`.
    /// The extension calls this at start: app updates move the bundle.
    public static func relocatingRuleSets(in json: String, to directory: String) throws -> String {
        var root = try JSON.parse(json)
        guard var route = root["route"], let sets = route["rule_set"]?.array else { return json }
        let names = Set(BundledRuleSet.allCases.map(\.rawValue))
        let base = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        route["rule_set"] = .array(sets.map { set in
            guard let tag = set["tag"]?.string, names.contains(tag), set["type"]?.string == "local" else { return set }
            var copy = set
            copy["path"] = .string(base + "/" + tag + ".srs")
            return copy
        })
        root["route"] = route
        return root.serialized()
    }
}
