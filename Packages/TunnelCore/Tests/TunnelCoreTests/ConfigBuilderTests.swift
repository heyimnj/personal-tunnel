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
        XCTAssertEqual(selector?["outbounds"], ["auto", "🇺🇸 США-2", "Самый быстрый | Авто", "XHTTP", "Hy2", "WG"])
        // Provider groups are servers, not members of the app's own auto group.
        XCTAssertEqual(outbounds.first { $0["tag"] == "auto" }?["outbounds"], ["🇺🇸 США-2", "XHTTP", "Hy2", "WG"])
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
        XCTAssertEqual(full.at("route", "rule_set")?.arrayValue?.count, 4)
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
        XCTAssertEqual(moved.at("route", "rule_set")?[3]?["path"], "/bundle/Rules/ru-ip.srs")
    }

    func testEmptySubscriptionAndDuplicateTagsAreRefused() {
        XCTAssertThrowsError(try ConfigBuilder.build(subscription: Subscription(id: 1, name: "x"), selected: nil, options: TunnelOptions()))
        let twin = ServerNode(id: "a", name: "a", outbound: ["type": "socks", "tag": "a", "server": "h", "server_port": 1])
        XCTAssertThrowsError(try ConfigBuilder.build(subscription: Subscription(id: 1, name: "x", nodes: [twin, twin]), selected: nil, options: TunnelOptions()))
    }
}
