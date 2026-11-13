import XCTest
@testable import TunnelCore

final class ConfigBuilderTests: XCTestCase {
    private func subscription() throws -> Subscription {
        let parsed = try ContentImporter.parse(ImportTests.xraySubscription).nodes
            + [try ShareLink.parse("wireguard://cHJpdmF0ZWtleXByaXZhdGVrZXlwcml2YXRla2V5MTI%3D@wg.example.com:51820?publickey=cHVibGlja2V5cHVibGlja2V5cHVibGlja2V5MTIzNDU%3D&address=10.7.0.2&mtu=1280#WG")]
        return Subscription(id: 7, name: "Тест", nodes: NodeAssembler.assemble(parsed))
    }

    func testSelectorHoldsEveryServerAndStartsOnTheChosenOne() throws {
        let subscription = try subscription()
        let config = try ConfigBuilder.build(subscription: subscription, selected: "Hy2", options: TunnelOptions())
        let outbounds = config["outbounds"]?.arrayValue ?? []
        let selector = outbounds.first { $0["tag"] == "proxy" }
        XCTAssertEqual(selector?["type"], "selector")
        XCTAssertEqual(selector?["default"], "Hy2")
        XCTAssertEqual(selector?["outbounds"], ["auto", "🇺🇸 США-2", "Самый быстрый | Авто", "XHTTP", "Hy2", "Сломанный", "WG"])
        // Provider groups are servers, not members of the app's own auto group.
        XCTAssertEqual(outbounds.first { $0["tag"] == "auto" }?["outbounds"], ["🇺🇸 США-2", "XHTTP", "Hy2", "Сломанный", "WG"])
        XCTAssertEqual(outbounds.last?["type"], "direct")
        XCTAssertEqual(config["endpoints"]?.arrayValue?.count, 1)
        XCTAssertEqual(config.at("inbounds")?[0]?["mtu"], 1280)
        XCTAssertEqual(config.at("route", "final"), "proxy")
        // Every tag is unique.
        let tags = (outbounds + (config["endpoints"]?.arrayValue ?? [])).compactMap { $0["tag"]?.stringValue }
        XCTAssertEqual(tags.count, Set(tags).count)
        // The document survives a round trip through text.
        XCTAssertEqual(try JSONValue.parse(config.serialized(pretty: true)), config)
    }

    func testAdBlockLevelsAndDNSAnswers() throws {
        let subscription = try subscription()
        var options = TunnelOptions()
        let standard = try ConfigBuilder.build(subscription: subscription, selected: nil, options: options)
        XCTAssertEqual(standard.at("route", "rules")?[2]?["rule_set"], ["pt-ad-block", "pt-ad-standard"])
        XCTAssertEqual(standard.at("route", "rules")?[2]?["action"], "reject")
        let dns = standard.at("dns", "rules")?.arrayValue ?? []
        XCTAssertEqual(dns[0]["answer"], ["*. 300 IN A 0.0.0.0"])
        XCTAssertEqual(dns[1]["answer"], ["*. 300 IN AAAA ::"])
        XCTAssertEqual(dns[2]["rcode"], "NOERROR")
        let paths = (standard.at("route", "rule_set")?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }
        XCTAssertTrue(paths.contains("@rules/ad-standard.srs"))
        options.adBlockLevel = .extended
        let extended = try ConfigBuilder.build(subscription: subscription, selected: nil, options: options)
        XCTAssertEqual(extended.at("route", "rules")?[2]?["rule_set"], ["pt-ad-block", "pt-ad-extended"])
        options.adBlockLevel = .basic
        let basic = try ConfigBuilder.build(subscription: subscription, selected: nil, options: options)
        XCTAssertEqual(basic.at("route", "rules")?[2]?["rule_set"], ["pt-ad-block"])
    }

    func testProbeConfigurationHasServersButNoTunnel() throws {
        let subscription = try subscription()
        let config = try ConfigBuilder.probe(subscription: subscription, options: TunnelOptions())
        XCTAssertNil(config["inbounds"])
        let outbounds = config["outbounds"]?.arrayValue ?? []
        let tags = outbounds.compactMap { $0["tag"]?.stringValue }
        XCTAssertFalse(tags.contains("proxy"))
        XCTAssertFalse(tags.contains("auto"))
        // Every server the selector offered can be measured by its tag.
        for tag in ConfigBuilder.selectableTags(of: subscription) {
            XCTAssertTrue(tags.contains(tag) || config["endpoints"]?.arrayValue?.contains { $0["tag"]?.stringValue == tag } == true, tag)
        }
        XCTAssertEqual(config.at("route", "final"), "direct")
        XCTAssertNil(config.at("route", "rule_set"))
        XCTAssertNil(config.at("route", "rules"))
        XCTAssertEqual(config.at("dns", "servers")?.arrayValue?.map { $0["tag"] }, ["dns-direct"])
        // Nothing points at what was removed.
        let text = config.serialized(pretty: false)
        XCTAssertFalse(text.contains("dns-remote"))
        XCTAssertFalse(text.contains("\"detour\":\"proxy\""))
    }

    func testUnknownSelectionFallsBackAndAutoModeUsesTheGroup() throws {
        let subscription = try subscription()
        var options = TunnelOptions()
        let fallback = try ConfigBuilder.build(subscription: subscription, selected: "нет такого", options: options)
        XCTAssertEqual(fallback["outbounds"]?.arrayValue?.first?["default"], "🇺🇸 США-2")
        options.autoSelect = true
        let auto = try ConfigBuilder.build(subscription: subscription, selected: "Hy2", options: options)
        XCTAssertEqual(auto["outbounds"]?.arrayValue?.first?["default"], "auto")
    }

    func testSingleServerHasNoAutoGroup() throws {
        let node = NodeAssembler.assemble([try ShareLink.parse("trojan://pw@b.example.com:443#B")])
        let config = try ConfigBuilder.build(subscription: Subscription(id: 1, name: "B", nodes: node), selected: nil, options: TunnelOptions())
        let outbounds = config["outbounds"]?.arrayValue ?? []
        XCTAssertEqual(outbounds.first?["outbounds"], ["B"])
        XCTAssertNil(outbounds.first { $0["tag"] == "auto" })
        XCTAssertNil(config["endpoints"])
        XCTAssertEqual(config.at("inbounds")?[0]?["mtu"], 1500)
    }

    func testRoutingOptions() throws {
        let subscription = try subscription()
        var options = TunnelOptions()
        let full = try ConfigBuilder.build(subscription: subscription, selected: nil, options: options)
        let rules = full.at("route", "rules")?.arrayValue ?? []
        XCTAssertEqual(rules[0]["action"], "sniff")
        XCTAssertEqual(rules[1]["action"], "hijack-dns")
        XCTAssertEqual(rules[2]["action"], "reject")
        XCTAssertEqual(rules[3]["ip_is_private"], true)
        XCTAssertEqual(rules[4]["outbound"], "direct")
        XCTAssertEqual(full.at("route", "rule_set")?.arrayValue?.count, 5)
        XCTAssertEqual(full.at("dns", "final"), "dns-remote")
        XCTAssertEqual(full.at("dns", "servers")?[0]?["detour"], "proxy")
        XCTAssertNil(full.at("dns", "servers")?[1]?["detour"])
        XCTAssertEqual(full.at("route", "default_domain_resolver", "server"), "dns-direct")

        options.adBlocking = false
        options.bypassRussia = false
        options.bypassPrivate = false
        let bare = try ConfigBuilder.build(subscription: subscription, selected: nil, options: options)
        XCTAssertEqual(bare.at("route", "rules")?.arrayValue?.count, 2)
        XCTAssertNil(bare.at("route", "rule_set"))
        XCTAssertNil(bare.at("dns", "rules"))
    }

    func testRuleSetsAreRelocated() throws {
        let config = try ConfigBuilder.build(subscription: try subscription(), selected: nil, options: TunnelOptions())
        XCTAssertEqual(config.at("route", "rule_set")?[0]?["path"], "@rules/ad-block.srs")
        let moved = ConfigBuilder.relocateRuleSets(in: config, directory: "/bundle/Rules")
        XCTAssertEqual(moved.at("route", "rule_set")?[0]?["path"], "/bundle/Rules/ad-block.srs")
        XCTAssertEqual(moved.at("route", "rule_set")?[4]?["path"], "/bundle/Rules/ru-ip.srs")
    }

    /// A configuration 1.x stored: locations are selectors over leaves, every leaf
    /// resolves through `dns-local`, some detour through outbounds that are gone.
    static let legacyConfig = """
    {"dns": {"servers": [{"type": "udp", "tag": "dns-remote", "server": "1.1.1.1"}, {"type": "local", "tag": "dns-local"}], "final": "dns-remote"},
     "outbounds": [
      {"type": "selector", "tag": "proxy", "outbounds": ["auto", "США", "Эстония", "Лучший"], "default": "auto"},
      {"type": "urltest", "tag": "auto", "outbounds": ["США", "Эстония", "Лучший"]},
      {"type": "vless", "tag": "leaf-1", "server": "us.example.net", "server_port": 443, "uuid": "11111111-2222-3333-4444-555555555555",
       "domain_resolver": {"server": "dns-local", "strategy": "prefer_ipv4"}, "detour": "fragment"},
      {"type": "trojan", "tag": "leaf-2", "server": "ee.example.net", "server_port": 443, "password": "p", "domain_strategy": "ipv4_only"},
      {"type": "shadowsocks", "tag": "leaf-3", "server": "x.example.net", "server_port": 8388, "method": "aes-256-gcm", "password": "p",
       "domain_resolver": "dns-local", "detour": "leaf-3"},
      {"type": "selector", "tag": "США", "outbounds": ["leaf-1"], "default": "leaf-1"},
      {"type": "selector", "tag": "Эстония", "outbounds": ["leaf-2", "leaf-gone"], "default": "leaf-gone"},
      {"type": "urltest", "tag": "Лучший", "outbounds": ["США", "Эстония", "leaf-3"]},
      {"type": "direct", "tag": "direct"}
     ],
     "route": {"default_domain_resolver": {"server": "dns-local"}, "final": "proxy"}}
    """

    func testServersCarriedOverFrom1xPointAtThisConfiguration() throws {
        let library = LegacyMigration.library(from: [LegacyProfile(id: 3, name: "Старая", order: 0, remoteURL: nil, lastUpdated: nil,
                                                                   config: Self.legacyConfig)], selectedProfileID: 3, preferredTag: "Эстония")
        let subscription = try XCTUnwrap(library.subscriptions.first)
        XCTAssertEqual(subscription.nodes.map(\.id), ["США", "Эстония", "Лучший"])
        // A group of groups is probed at its first server.
        XCTAssertEqual(subscription.nodes[2].address?.host, "us.example.net")
        XCTAssertEqual(subscription.nodes[1].address?.host, "ee.example.net")
        var options = TunnelOptions()
        options.autoSelect = false
        let config = try ConfigBuilder.build(subscription: subscription, selected: "Эстония", options: options)
        let text = config.serialized(pretty: false)
        XCTAssertFalse(text.contains("dns-local"))
        XCTAssertFalse(text.contains("domain_strategy"))
        XCTAssertFalse(text.contains("fragment"))

        let objects = (config["outbounds"]?.arrayValue ?? []) + (config["endpoints"]?.arrayValue ?? [])
        func object(_ tag: String) -> JSONValue? { objects.first { $0["tag"]?.stringValue == tag } }
        // Shared leaves are written once.
        let tags = objects.compactMap { $0["tag"]?.stringValue }
        XCTAssertEqual(tags.count, Set(tags).count)
        XCTAssertEqual(object("proxy")?["outbounds"], ["auto", "США", "Эстония", "Лучший"])
        XCTAssertEqual(object("proxy")?["default"], "Эстония")
        // Location groups of one server become that server, so «auto» has them.
        XCTAssertEqual(object("auto")?["outbounds"], ["США", "Эстония"])
        XCTAssertEqual(object("США")?["type"], "vless")
        XCTAssertNil(object("leaf-1"))
        XCTAssertNil(object("leaf-2"))
        XCTAssertEqual(object("США")?["domain_resolver"], ["server": "dns-direct", "strategy": "prefer_ipv4"])
        XCTAssertNil(object("США")?["detour"])
        XCTAssertEqual(object("Эстония")?["type"], "trojan")
        XCTAssertEqual(object("Эстония")?["domain_resolver"], ["server": "dns-direct", "strategy": "ipv4_only"])
        XCTAssertEqual(object("leaf-3")?["domain_resolver"], "dns-direct")
        XCTAssertNil(object("leaf-3")?["detour"])
        XCTAssertEqual(object("Лучший")?["outbounds"], ["США", "Эстония", "leaf-3"])
        // Every reference left in the document leads somewhere.
        let dnsTags = Set(config.at("dns", "servers")?.arrayValue?.compactMap { $0["tag"]?.stringValue } ?? [])
        for item in objects {
            for member in item["outbounds"]?.stringList ?? [] { XCTAssertTrue(tags.contains(member), member) }
            if let detour = item["detour"]?.stringValue { XCTAssertTrue(tags.contains(detour), detour) }
            let resolver = item["domain_resolver"]?.stringValue ?? item.at("domain_resolver", "server")?.stringValue
            if let resolver { XCTAssertTrue(dnsTags.contains(resolver), resolver) }
        }
    }

    func testGroupWithoutMembersIsLeftOut() throws {
        let empty = ServerNode(id: "Пусто", name: "Пусто", outbound: ["type": "urltest", "tag": "Пусто", "outbounds": ["нет"]])
        let real = NodeAssembler.assemble([try ShareLink.parse("trojan://pw@b.example.com:443#B")])
        let config = try ConfigBuilder.build(subscription: Subscription(id: 1, name: "x", nodes: [empty] + real), selected: "Пусто", options: TunnelOptions())
        XCTAssertEqual(config["outbounds"]?.arrayValue?.first?["outbounds"], ["B"])
        XCTAssertEqual(config["outbounds"]?.arrayValue?.first?["default"], "B")
        XCTAssertThrowsError(try ConfigBuilder.build(subscription: Subscription(id: 1, name: "x", nodes: [empty]), selected: nil, options: TunnelOptions()))
    }

    func testEmptySubscriptionAndDuplicateTagsAreRefused() throws {
        XCTAssertThrowsError(try ConfigBuilder.build(subscription: Subscription(id: 1, name: "x"), selected: nil, options: TunnelOptions()))
        let twin = ServerNode(id: "a", name: "a", outbound: ["type": "socks", "tag": "a", "server": "h", "server_port": 1])
        let other = ServerNode(id: "a", name: "a", outbound: ["type": "socks", "tag": "a", "server": "other", "server_port": 1])
        XCTAssertThrowsError(try ConfigBuilder.build(subscription: Subscription(id: 1, name: "x", nodes: [twin, other]), selected: nil, options: TunnelOptions()))
        let reserved = ServerNode(id: "proxy", name: "proxy", outbound: ["type": "socks", "tag": "proxy", "server": "h", "server_port": 1])
        XCTAssertThrowsError(try ConfigBuilder.build(subscription: Subscription(id: 1, name: "x", nodes: [reserved]), selected: nil, options: TunnelOptions()))
        // The very same object twice is one server.
        let once = try ConfigBuilder.build(subscription: Subscription(id: 1, name: "x", nodes: [twin, twin]), selected: nil, options: TunnelOptions())
        XCTAssertEqual(once["outbounds"]?.arrayValue?.first?["outbounds"], ["a"])
        XCTAssertEqual(once["outbounds"]?.arrayValue?.count, 3)
    }
}

final class XrayBackedTests: XCTestCase {
    static let subscriptionJSON = #"""
    [{"remarks": "Sudoku", "outbounds": [
       {"tag": "proxy", "protocol": "vless", "settings": {"vnext": [{"address": "s.example.net", "port": 443, "users": [{"id": "11111111-2222-3333-4444-555555555555", "encryption": "none"}]}]},
        "streamSettings": {"network": "raw", "security": "tls", "tlsSettings": {"serverName": "s.example.net"}, "finalmask": {"tcp": [{"type": "sudoku", "settings": {"password": "mask"}}]}}},
       {"tag": "direct", "protocol": "freedom"}]},
     {"remarks": "Plain", "outbounds": [
       {"tag": "proxy", "protocol": "trojan", "settings": {"servers": [{"address": "t.example.net", "port": 443, "password": "pw"}]}, "streamSettings": {"security": "tls"}}]},
     {"remarks": "Chain", "outbounds": [
       {"tag": "exit", "protocol": "vless", "settings": {"vnext": [{"address": "c.example.net", "port": 443, "users": [{"id": "11111111-2222-3333-4444-555555555555", "encryption": "none"}]}]},
        "streamSettings": {"network": "raw", "finalmask": {"tcp": [{"type": "header-custom"}]}, "sockopt": {"dialerProxy": "hop"}}},
       {"tag": "hop", "protocol": "trojan", "settings": {"servers": [{"address": "h.example.net", "port": 443, "password": "pw"}]}}]}]
    """#

    func testTunnelReachesXrayServersThroughLocalSocks() throws {
        let nodes = NodeAssembler.assemble(try ContentImporter.parse(Self.subscriptionJSON).nodes)
        XCTAssertEqual(nodes.map(\.type), ["xray", "trojan", "xray"])
        let subscription = Subscription(id: 3, name: "X", nodes: nodes)
        let config = try ConfigBuilder.build(subscription: subscription, selected: nil, options: TunnelOptions())
        let outbounds = config["outbounds"]?.arrayValue ?? []
        let sudoku = outbounds.first { $0["tag"]?.stringValue == nodes[0].id }
        XCTAssertEqual(sudoku?["type"], "socks")
        XCTAssertEqual(sudoku?["server"], "127.0.0.1")
        XCTAssertEqual(sudoku?["server_port"], .int(Int64(XrayBacked.tunnelPortBase)))
        XCTAssertNil(sudoku?["xray"])
        XCTAssertFalse(config.serialized().contains("\"xray\""))
        // The probe uses the app's own ports.
        let probe = try ConfigBuilder.probe(subscription: subscription, options: TunnelOptions())
        XCTAssertEqual(probe["outbounds"]?.arrayValue?.first { $0["tag"]?.stringValue == nodes[2].id }?["server_port"], .int(Int64(XrayBacked.appPortBase + 1)))

        let runtime = try XCTUnwrap(ConfigBuilder.xrayRuntime(subscription: subscription))
        XCTAssertEqual(runtime["inbounds"]?.arrayValue?.map { $0["port"] }, [.int(Int64(XrayBacked.tunnelPortBase)), .int(Int64(XrayBacked.tunnelPortBase + 1))])
        let rules = runtime.at("routing", "rules")?.arrayValue ?? []
        XCTAssertEqual(rules.map { $0["outboundTag"] }, ["n0-proxy", "n1-exit"])
        let exit = runtime["outbounds"]?.arrayValue?.first { $0["tag"] == "n1-exit" }
        XCTAssertEqual(exit?.at("streamSettings", "sockopt", "dialerProxy"), "n1-hop")
        XCTAssertNil(ConfigBuilder.xrayRuntime(subscription: Subscription(id: 4, name: "Y", nodes: [nodes[1]])))
    }
}

extension XrayBackedTests {
    func testPrepareBindsHopsToTheInterfaceAndLogsToAFile() throws {
        let nodes = NodeAssembler.assemble(try ContentImporter.parse(Self.subscriptionJSON).nodes)
        let runtime = try XCTUnwrap(ConfigBuilder.xrayRuntime(subscription: Subscription(id: 3, name: "X", nodes: nodes)))
        let ready = XrayBacked.prepare(runtime, interface: "en0", logPath: "/tmp/xray.log")
        XCTAssertEqual(ready.at("log", "error"), "/tmp/xray.log")
        let outbounds = ready["outbounds"]?.arrayValue ?? []
        func tagged(_ tag: String) -> JSONValue? { outbounds.first { $0["tag"]?.stringValue == tag } }
        XCTAssertEqual(tagged("n0-proxy")?.at("streamSettings", "sockopt", "interface"), "en0")
        XCTAssertEqual(tagged("n0-direct")?.at("streamSettings", "sockopt", "interface"), "en0")
        // The chain's exit dials through its hop; the hop is the one bound.
        XCTAssertNil(tagged("n1-exit")?.at("streamSettings", "sockopt", "interface"))
        XCTAssertEqual(tagged("n1-hop")?.at("streamSettings", "sockopt", "interface"), "en0")
        XCTAssertNil(tagged("pt-block")?["streamSettings"])
        XCTAssertEqual(XrayBacked.prepare(runtime, interface: nil, logPath: nil), runtime)
    }
}
