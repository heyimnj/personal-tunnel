@testable import TunnelKit
import XCTest

final class ConfigTests: XCTestCase {
    private func sampleServers() throws -> [Server] {
        let links = [
            "vless://id@a.example.com:443?security=tls#Same",
            "trojan://pw@b.example.com:443#Same",
            "wireguard://key@w.example.com:51820?publickey=pk&address=10.0.0.2#proxy",
        ]
        return try links.map { Server(imported: try ShareLinkParser.parse($0)) }
    }

    func testBuildsSelectorAndUniqueTags() throws {
        let servers = try sampleServers()
        let config = try ConfigBuilder.build(servers: servers, selected: servers[1].id, options: TunnelOptions(), ruleSetDirectory: "/rules/")
        let json = try JSON.parse(config.json)

        XCTAssertEqual(config.tags[servers[0].id], "Same")
        XCTAssertEqual(config.tags[servers[1].id], "Same #2")
        // "proxy" is reserved for the selector.
        XCTAssertEqual(config.tags[servers[2].id], "proxy #2")
        XCTAssertEqual(config.selectedTag, "Same #2")

        let outbounds = try XCTUnwrap(json["outbounds"]?.array)
        let selector = try XCTUnwrap(outbounds.first)
        XCTAssertEqual(selector["type"], "selector")
        XCTAssertEqual(selector["default"], "Same #2")
        XCTAssertEqual(selector["outbounds"], ["Same", "Same #2", "proxy #2"])
        XCTAssertEqual(outbounds.last?["type"], "direct")
        // WireGuard goes to endpoints.
        XCTAssertEqual(json["endpoints"]?[0]?["tag"], "proxy #2")
        XCTAssertFalse(outbounds.contains { $0["type"] == "wireguard" })

        let route = try XCTUnwrap(json["route"])
        XCTAssertEqual(route["final"], "proxy")
        XCTAssertEqual(route["default_domain_resolver"]?["server"], "dns-local")
        let ruleSets = try XCTUnwrap(route["rule_set"]?.array)
        XCTAssertEqual(ruleSets.compactMap { $0["tag"]?.string }, ["ad-block", "ru-inside", "ru-domains", "ru-ip"])
        XCTAssertEqual(ruleSets[0]["path"], "/rules/ad-block.srs")

        let dns = try XCTUnwrap(json["dns"])
        XCTAssertEqual(dns["final"], "dns-remote")
        XCTAssertEqual(dns["servers"]?[0]?["detour"], "proxy")
        XCTAssertEqual(dns["rules"]?[0]?["action"], "reject")
        XCTAssertEqual(json["inbounds"]?[0]?["address"], ["172.19.0.1/30", "fdfe:dcba:9876::1/126"])
    }

    func testOptionsDisableManagedRules() throws {
        let servers = try sampleServers()
        var options = TunnelOptions()
        options.adBlocking = false
        options.bypassRussia = false
        options.ipv6 = false
        options.directDomains = ["https://*.Bank.example/login", "bank.example"]
        let config = try ConfigBuilder.build(servers: servers, selected: servers[0].id, options: options, ruleSetDirectory: "/r")
        let json = try JSON.parse(config.json)
        XCTAssertNil(json["route"]?["rule_set"])
        XCTAssertEqual(json["dns"]?["strategy"], "ipv4_only")
        XCTAssertEqual(json["inbounds"]?[0]?["address"], ["172.19.0.1/30"])
        let rules = try XCTUnwrap(json["route"]?["rules"]?.array)
        XCTAssertTrue(rules.contains { $0["domain_suffix"] == ["bank.example"] && $0["outbound"] == "direct" })
    }

    func testCustomDNS() {
        XCTAssertEqual(ConfigBuilder.customDNSServer("https://dns.example.com/q")?["path"], "/q")
        XCTAssertEqual(ConfigBuilder.customDNSServer("https://dns.example.com/q")?["domain_resolver"], "dns-local")
        XCTAssertEqual(ConfigBuilder.customDNSServer("tls://1.1.1.1")?["type"], "tls")
        XCTAssertEqual(ConfigBuilder.customDNSServer("8.8.4.4")?["type"], "udp")
        XCTAssertNil(ConfigBuilder.customDNSServer("ftp://x"))
    }

    func testRelocatingRuleSets() throws {
        let servers = try sampleServers()
        let config = try ConfigBuilder.build(servers: servers, selected: servers[0].id, options: TunnelOptions(), ruleSetDirectory: "/old/place")
        let moved = try ConfigBuilder.relocatingRuleSets(in: config.json, to: "/new/place/")
        let json = try JSON.parse(moved)
        XCTAssertEqual(json["route"]?["rule_set"]?[3]?["path"], "/new/place/ru-ip.srs")
    }

    func testRefreshKeepsIdentities() throws {
        var subscription = Subscription(name: "S", url: "https://x")
        subscription.replaceServers(with: [
            try ShareLinkParser.parse("trojan://a@h1:443#One"),
            try ShareLinkParser.parse("trojan://b@h2:443#Two"),
        ])
        subscription.servers[0].isFavorite = true
        let firstID = subscription.servers[0].id
        let secondID = subscription.servers[1].id
        subscription.replaceServers(with: [
            try ShareLinkParser.parse("trojan://a@h1:443#One renamed"),
            try ShareLinkParser.parse("trojan://changed@h2:443#Two"),
            try ShareLinkParser.parse("trojan://c@h3:443#Three"),
        ])
        XCTAssertEqual(subscription.servers[0].id, firstID)
        XCTAssertTrue(subscription.servers[0].isFavorite)
        XCTAssertEqual(subscription.servers[1].id, secondID)
        XCTAssertEqual(subscription.servers.count, 3)
    }

    func testLibrarySelectionRepair() throws {
        var library = ServerLibrary(subscriptions: [Subscription(name: "A", servers: try sampleServers())])
        XCTAssertEqual(library.effectiveSelection?.id, library.subscriptions[0].servers[0].id)
        library.selectedServerID = library.subscriptions[0].servers[1].id
        library.removeServer(id: library.subscriptions[0].servers[1].id)
        XCTAssertEqual(library.selectedServerID, library.subscriptions[0].servers[0].id)
    }

    func testBackupRoundTripAndLegacy() throws {
        var library = ServerLibrary(subscriptions: [Subscription(name: "A", url: "https://example.com/s", servers: try sampleServers())])
        library.repairSelection()
        let archive = BackupArchive(appVersion: "2.0.0", library: library, tunnelOptions: TunnelOptions(), preferences: ["personal.appearance": "modern"], fonts: ["f.ttf": Data([1, 2])])
        let restored = try BackupArchive.read(archive.encoded())
        XCTAssertEqual(restored.library, library)
        XCTAssertEqual(restored.preferences["personal.appearance"], "modern")
        XCTAssertEqual(restored.fonts["f.ttf"], Data([1, 2]))

        let legacyConfig = #"{"outbounds":[{"type":"vless","tag":"🇩🇪 DE","server":"de.example.com","server_port":443,"uuid":"id"},{"type":"direct","tag":"direct"}]}"#
        let plist = try PropertyListSerialization.data(fromPropertyList: ["personal.appearance": "material", "personal.amoled": true], format: .binary, options: 0)
        let legacy: [String: Any] = [
            "version": 1,
            "profiles": [["name": "Work", "config": legacyConfig, "remoteURL": "https://panel/sub", "autoUpdate": true, "interval": 720, "disabled": false]],
            "uiSettings": plist.base64EncodedString(),
            "networkSettings": ["ad_blocking_enabled": Data([0]).base64EncodedString()],
            "fonts": [String: String](),
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let converted = try BackupArchive.read(data)
        XCTAssertEqual(converted.library.subscriptions.first?.name, "Work")
        XCTAssertEqual(converted.library.subscriptions.first?.updateIntervalHours, 12)
        XCTAssertEqual(converted.library.subscriptions.first?.servers.first?.name, "🇩🇪 DE")
        XCTAssertEqual(converted.preferences["personal.appearance"], "material")
        XCTAssertEqual(converted.preferences["personal.amoled"], true)
        XCTAssertFalse(converted.tunnelOptions.adBlocking)
        XCTAssertNotNil(converted.library.selectedServerID)
    }
}
