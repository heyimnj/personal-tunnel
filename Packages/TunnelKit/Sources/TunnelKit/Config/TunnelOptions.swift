import Foundation

/// User-facing network settings that shape the sing-box configuration.
public struct TunnelOptions: Codable, Hashable, Sendable {
    public var adBlocking: Bool
    /// Russian sites go direct, past the proxy.
    public var bypassRussia: Bool
    public var dns: DNSPreset
    /// Used when `dns == .custom`: `https://…`, `tls://…`, `quic://…`, `udp://…` or an IP.
    public var customDNS: String
    public var ipv6: Bool
    /// Private and link-local addresses go direct.
    public var directLocalNetworks: Bool
    public var logLevel: LogLevel
    /// Extra domains that always go direct, one per entry (suffix match).
    public var directDomains: [String]
    /// Extra domains that always go through the proxy.
    public var proxyDomains: [String]

    public init() {
        adBlocking = true
        bypassRussia = true
        dns = .cloudflare
        customDNS = ""
        ipv6 = true
        directLocalNetworks = true
        logLevel = .warn
        directDomains = []
        proxyDomains = []
    }

    public init(from decoder: Decoder) throws {
        // Every field is optional so settings saved by older builds still load.
        let defaults = TunnelOptions()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        adBlocking = try container.decodeIfPresent(Bool.self, forKey: .adBlocking) ?? defaults.adBlocking
        bypassRussia = try container.decodeIfPresent(Bool.self, forKey: .bypassRussia) ?? defaults.bypassRussia
        dns = (try? container.decodeIfPresent(DNSPreset.self, forKey: .dns)) ?? defaults.dns
        customDNS = try container.decodeIfPresent(String.self, forKey: .customDNS) ?? defaults.customDNS
        ipv6 = try container.decodeIfPresent(Bool.self, forKey: .ipv6) ?? defaults.ipv6
        directLocalNetworks = try container.decodeIfPresent(Bool.self, forKey: .directLocalNetworks) ?? defaults.directLocalNetworks
        logLevel = (try? container.decodeIfPresent(LogLevel.self, forKey: .logLevel)) ?? defaults.logLevel
        directDomains = try container.decodeIfPresent([String].self, forKey: .directDomains) ?? []
        proxyDomains = try container.decodeIfPresent([String].self, forKey: .proxyDomains) ?? []
    }
}

public enum DNSPreset: String, Codable, CaseIterable, Sendable {
    case cloudflare
    case google
    case quad9
    case adguard
    case custom

    public var title: String {
        switch self {
        case .cloudflare: return "Cloudflare"
        case .google: return "Google"
        case .quad9: return "Quad9"
        case .adguard: return "AdGuard"
        case .custom: return "Свой"
        }
    }

    var address: String {
        switch self {
        case .cloudflare, .custom: return "1.1.1.1"
        case .google: return "8.8.8.8"
        case .quad9: return "9.9.9.9"
        case .adguard: return "94.140.14.14"
        }
    }
}

public enum LogLevel: String, Codable, CaseIterable, Sendable {
    case error
    case warn
    case info
    case debug
}
