import XCTest
@testable import TunnelCore

final class ConfigBuilderTests: XCTestCase {
    private func subscription() throws -> Subscription {
        let parsed = try ContentImporter.parse(ImportTests.xraySubscription).nodes
            + [try ShareLink.parse("wireguard://cHJpdmF0ZWtleXByaXZhdGVrZXlwcml2YXRla2V5MTI%3D@wg.example.com:51820?publickey=cHVibGlja2V5cHVibGlja2V5cHVibGlja2V5MTIzNDU%3D&address=10.7.0.2&mtu=1280#WG")]
        return Subscription(id: 7, name: "Тест", nodes: NodeAssembler.assemble(parsed))
    }

    /// 3.1.6: without automatic selection the tunnel runs the chosen server alone,
    /// with no `auto` group testing the rest in the background.
    func testTunnelRunsOnlyTheChosenServer() throws {
        let subscription = try subscription()
        let options = TunnelOptions()
        let running = ConfigBuilder.tunnelSubscription(subscription, selected: "Hy2", options: options)
        XCTAssertEqual(running.nodes.map(\.id), ["Hy2"])
        let config = try ConfigBuilder.build(subscription: running, selected: "Hy2", options: options)
        let outbounds = config["outbounds"]?.arrayValue ?? []
        XCTAssertEqual(outbounds.first { $0["tag"] == "proxy" }?["outbounds"], ["Hy2"])
        XCTAssertNil(outbounds.first { $0["tag"] == "auto" })
        XCTAssertEqual(config["inbounds"]?.arrayValue?.first?["stack"], "mixed")
        // A provider group keeps the servers it is made of.
        let group = ConfigBuilder.tunnelSubscription(subscription, selected: "Самый быстрый | Авто", options: options)
        XCTAssertEqual(group.nodes.map(\.id), ["Самый быстрый | Авто"])
        XCTAssertNoThrow(try ConfigBuilder.build(subscription: group, selected: "Самый быстрый | Авто", options: options))
        var auto = options
        auto.autoSelect = true
        XCTAssertEqual(ConfigBuilder.tunnelSubscription(subscription, selected: "Hy2", options: auto).nodes.count, subscription.nodes.count)
    }

    /// 3.1.6: a subscription's panel goes through the VPN, ahead of every bypass.
    func testSubscriptionPanelsGoThroughTheVPN() throws {
        var options = TunnelOptions()
        options.subscriptionHosts = ["panel.example.su", "203.0.113.9"]
        let config = try ConfigBuilder.build(subscription: try subscription(), selected: "Hy2", options: options)
        let first = config.at("route", "rules")?.arrayValue?.first
        XCTAssertEqual(first?["outbound"], "proxy")
        XCTAssertEqual(first?["domain"], ["panel.example.su"])
        XCTAssertEqual(first?["ip_cidr"], ["203.0.113.9/32"])
        XCTAssertEqual(config.at("dns", "rules")?.arrayValue?.first?["server"], "dns-remote")
        XCTAssertEqual(config.at("dns", "reverse_mapping"), true)
    }

    func testSelectorHoldsEveryServerAndStartsOnTheChosenOne() throws {
        let subscription = try subscription()
        var auto = TunnelOptions()
        auto.autoSelect = true
        let config = try ConfigBuilder.build(subscription: subscription, selected: "Hy2", options: auto)
        let outbounds = config["outbounds"]?.arrayValue ?? []
        let selector = outbounds.first { $0["tag"] == "proxy" }
        XCTAssertEqual(selector?["type"], "selector")
        XCTAssertEqual(selector?["default"], "auto")
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

    /// 3.0.5: a server saved before pins were read gets the pin of its link
    /// back when the configuration is built.
    func testPinOfTheLinkReachesSavedServers() throws {
        let hash = String(repeating: "ab", count: 32)
        let link = "vless://uuid@1.2.3.4:443?security=tls&sni=a.internal&type=tcp&pcs=\(hash)#Old"
        var parsed = try ShareLink.parse(link)
        // As 3.0.4 stored it: the link, but no pin in the server.
        if var tls = parsed.outbound["tls"]?.objectValue {
            tls["certificate_sha256"] = nil
            parsed.outbound["tls"] = .object(tls)
        }
        XCTAssertNil(parsed.outbound.at("tls", "certificate_sha256"))
        let subscription = Subscription(id: 3, name: "Старая", nodes: NodeAssembler.assemble([parsed]))
        let config = try ConfigBuilder.build(subscription: subscription, selected: nil, options: TunnelOptions())
        let server = config["outbounds"]?.arrayValue?.first { $0["tag"] == "Old" }
        XCTAssertEqual(server?.at("tls", "certificate_sha256"), [.string(hash)])
        // The probe configuration is built the same way.
        let probe = try ConfigBuilder.probe(subscription: subscription, options: TunnelOptions())
        XCTAssertEqual(probe["outbounds"]?.arrayValue?.first { $0["tag"] == "Old" }?.at("tls", "certificate_sha256"), [.string(hash)])
    }

    func testAdBlockLevelsAndDNSAnswers() throws {
        let subscription = try subscription()
        var options = TunnelOptions()
        let standard = try ConfigBuilder.build(subscription: subscription, selected: nil, options: options)
        let rules = standard.at("route", "rules")?.arrayValue ?? []
        XCTAssertEqual(rules[2]["rule_set"], ["pt-ad-block", "pt-ad-ru", "pt-ad-standard"])
        XCTAssertEqual(rules[2]["action"], "reject")
        // 3.0.5: apps' own encrypted DNS is refused by name, port and address, ahead of the bypass rules.
        XCTAssertEqual(rules[3]["rule_set"], ["pt-doh"])
        XCTAssertEqual(rules[3]["action"], "reject")
        XCTAssertEqual(rules[4]["port"], 853)
        XCTAssertEqual(rules[4]["action"], "reject")
        XCTAssertEqual(rules[5]["port"], [443, 853])
        XCTAssertEqual(rules[5]["ip_cidr"]?.arrayValue?.contains("1.1.1.1/32"), true)
        XCTAssertEqual(rules[5]["action"], "reject")
        XCTAssertEqual(rules[6]["ip_is_private"], true)
        let dns = standard.at("dns", "rules")?.arrayValue ?? []
        XCTAssertEqual(dns[0]["answer"], ["*. 300 IN A 0.0.0.0"])
        XCTAssertEqual(dns[1]["answer"], ["*. 300 IN AAAA ::"])
        XCTAssertEqual(dns[2]["rcode"], "NOERROR")
        XCTAssertEqual(dns[3]["rule_set"], ["pt-doh"])
        XCTAssertEqual(dns[3]["answer"], ["*. 300 IN A 0.0.0.0"])
        XCTAssertEqual(dns[5]["rcode"], "NOERROR")
        let paths = (standard.at("route", "rule_set")?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }
        XCTAssertEqual(paths.filter { !$0.contains("/ru-") }, ["@rules/ad-block.srs", "@rules/ad-ru.srs", "@rules/ad-standard.srs", "@rules/doh.srs"])
        options.adBlockLevel = .extended
        let extended = try ConfigBuilder.build(subscription: subscription, selected: nil, options: options)
        XCTAssertEqual(extended.at("route", "rules")?[2]?["rule_set"], ["pt-ad-block", "pt-ad-ru", "pt-ad-extended"])
        options.adBlockLevel = .basic
        let basic = try ConfigBuilder.build(subscription: subscription, selected: nil, options: options)
        XCTAssertEqual(basic.at("route", "rules")?[2]?["rule_set"], ["pt-ad-block", "pt-ad-ru", "pt-ad-basic"])
        XCTAssertTrue((basic.at("route", "rule_set")?.arrayValue ?? []).contains { $0["path"] == "@rules/ad-light.srs" })
        // Without the encrypted DNS guard only the ad rules remain.
        options.blockEncryptedDNS = false
        let open = try ConfigBuilder.build(subscription: subscription, selected: nil, options: options)
        XCTAssertEqual(open.at("route", "rules")?[3]?["ip_is_private"], true)
        XCTAssertEqual(open.at("dns", "rules")?.arrayValue?.count, 4)
        XCTAssertFalse(open.serialized(pretty: false).contains("pt-doh"))
        // Every bundled file the levels name exists in the extension's Rules folder.
        let rulesFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../PacketTunnel/Rules").standardized
        for file in ConfigBuilder.RuleSet.files.values {
            XCTAssertTrue(FileManager.default.fileExists(atPath: rulesFolder.appendingPathComponent(file).path), file)
        }
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
        XCTAssertEqual(config.at("certificate", "store"), "mozilla")
        XCTAssertNil(config.at("route", "rule_set"))
        XCTAssertNil(config.at("route", "rules"))
        XCTAssertEqual(config.at("dns", "servers")?.arrayValue?.map { $0["tag"] }, ["dns-direct", "dns-direct-1", "dns-direct-2", "dns-direct-3"])
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

    /// 3.1.10: REALITY servers go out with Chrome's fingerprint (the pinned core's
    /// Firefox lacks the hybrid key share new Xray servers require); plain TLS keeps its own.
    func testRealityTakesChromeFingerprint() throws {
        let key = "frA_WzVIkA2NPG1EUvGDN8WoFAneqhPgaBGe9FvsaKc"
        let links = [
            "vless://11111111-2222-3333-4444-555555555555@r.example.com:443?security=reality&pbk=\(key)&sid=ab&sni=www.example.com&fp=ios&type=tcp#R",
            "vless://11111111-2222-3333-4444-555555555555@f.example.com:443?security=reality&pbk=\(key)&sid=ab&sni=www.example.com&fp=firefox&type=tcp#F",
            "vless://11111111-2222-3333-4444-555555555555@t.example.com:443?security=tls&sni=t.example.com&fp=firefox&type=ws&path=%2F#T",
        ]
        let nodes = NodeAssembler.assemble(try links.map { try ShareLink.parse($0) })
        let subscription = Subscription(id: 1, name: "R", nodes: nodes)
        let config = try ConfigBuilder.build(subscription: subscription, selected: nil, options: TunnelOptions())
        let outbounds = config["outbounds"]?.arrayValue ?? []
        let reality = try XCTUnwrap(outbounds.first { $0["tag"] == "R" })
        XCTAssertEqual(reality.at("tls", "utls", "fingerprint"), "chrome")
        XCTAssertEqual(reality.at("tls", "reality", "enabled"), true)
        // Beta core: Firefox 148 carries the hybrid share and keeps its fingerprint.
        XCTAssertEqual(outbounds.first { $0["tag"] == "F" }?.at("tls", "utls", "fingerprint"), "firefox")
        let tls = try XCTUnwrap(outbounds.first { $0["tag"] == "T" })
        XCTAssertEqual(tls.at("tls", "utls", "fingerprint"), "firefox")
        let probe = try ConfigBuilder.probe(subscription: subscription, options: TunnelOptions())
        XCTAssertEqual(probe["outbounds"]?.arrayValue?.first { $0["tag"] == "R" }?.at("tls", "utls", "fingerprint"), "chrome")
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

    /// 3.1.2: with the VPN on, the app's tests of every server leave the tunnel:
    /// their names resolve outside it and their connections go direct, matched
    /// before sniffing (by the name the tunnel's DNS gave the address for).
    func testServerAddressesGoOutsideTheTunnel() throws {
        let subscription = try subscription()
        let hosts = ConfigBuilder.serverHosts(of: [subscription])
        XCTAssertFalse(hosts.isEmpty)
        XCTAssertEqual(Set(hosts).count, hosts.count)
        var options = TunnelOptions()
        options.serverHosts = ["a.example.com", "1.2.3.4", "2001:db8::1", "A.example.com"]
        let config = try ConfigBuilder.build(subscription: subscription, selected: nil, options: options)
        let rules = config.at("route", "rules")?.arrayValue ?? []
        XCTAssertEqual(rules[0]["outbound"], "direct")
        XCTAssertEqual(rules[0]["domain"], ["a.example.com", "a.example.com"])
        XCTAssertEqual(rules[1]["ip_cidr"], ["1.2.3.4/32", "2001:db8::1/128"])
        XCTAssertEqual(rules[2]["action"], "sniff")
        XCTAssertEqual(config.at("dns", "rules")?[0]?["server"], "dns-direct")
        XCTAssertEqual(config.at("dns", "reverse_mapping"), true)
        // Without addresses nothing changes.
        let plain = try ConfigBuilder.build(subscription: subscription, selected: nil, options: TunnelOptions())
        XCTAssertNil(plain.at("dns", "reverse_mapping"))
        XCTAssertEqual(plain.at("route", "rules")?[0]?["action"], "sniff")
    }

    func testRoutingOptions() throws {
        let subscription = try subscription()
        var options = TunnelOptions()
        let full = try ConfigBuilder.build(subscription: subscription, selected: nil, options: options)
        let rules = full.at("route", "rules")?.arrayValue ?? []
        XCTAssertEqual(rules[0]["action"], "sniff")
        XCTAssertEqual(rules[1]["action"], "hijack-dns")
        XCTAssertEqual(rules[2]["action"], "reject")
        XCTAssertEqual(rules[6]["ip_is_private"], true)
        XCTAssertEqual(rules[7]["outbound"], "direct")
        XCTAssertEqual(full.at("route", "rule_set")?.arrayValue?.count, 7)
        XCTAssertEqual(full.at("dns", "final"), "dns-remote")
        // 3.1.0: certificates checked against Mozilla's roots, as Xray-core does.
        XCTAssertEqual(full.at("certificate", "store"), "mozilla")
        // 3.0.5: the resolver through the VPN is a group: HTTPS, and plain TCP
        // through the same server when HTTPS fails.
        XCTAssertEqual(full.at("dns", "servers")?[0]?["type"], "group")
        XCTAssertEqual(full.at("dns", "servers")?[0]?["tag"], "dns-remote")
        XCTAssertEqual(full.at("dns", "servers")?[0]?["servers"], ["dns-remote-https", "dns-remote-tcp"])
        XCTAssertEqual(full.at("dns", "servers")?[0]?["mode"], "parallel")
        XCTAssertEqual(full.at("dns", "servers")?[1]?["type"], "https")
        XCTAssertEqual(full.at("dns", "servers")?[1]?["detour"], "proxy")
        XCTAssertEqual(full.at("dns", "servers")?[2]?["type"], "tcp")
        XCTAssertEqual(full.at("dns", "servers")?[2]?["detour"], "proxy")
        // 3.0.6: outside the tunnel, the chosen resolver and two fallbacks at once.
        XCTAssertEqual(full.at("dns", "servers")?[3]?["tag"], "dns-direct")
        XCTAssertEqual(full.at("dns", "servers")?[3]?["type"], "group")
        XCTAssertEqual(full.at("dns", "servers")?[3]?["servers"], ["dns-direct-1", "dns-direct-2", "dns-direct-3"])
        XCTAssertEqual(full.at("dns", "servers")?[4]?["server"], "1.1.1.1")
        XCTAssertEqual(full.at("dns", "servers")?[5]?["server"], "77.88.8.8")
        XCTAssertNil(full.at("dns", "servers")?[4]?["detour"])
        XCTAssertEqual(full.at("route", "default_domain_resolver", "server"), "dns-direct")

        options.adBlocking = false
        options.bypassRussia = false
        options.bypassPrivate = false
        options.dnsServer = "8.8.8.8"
        let bare = try ConfigBuilder.build(subscription: subscription, selected: nil, options: options)
        // A fallback that is already the chosen resolver is not asked twice.
        XCTAssertEqual(bare.at("dns", "servers")?[3]?["servers"], ["dns-direct-1", "dns-direct-2"])
        XCTAssertEqual(bare.at("route", "rules")?.arrayValue?.count, 2)
        XCTAssertNil(bare.at("route", "rule_set"))
        XCTAssertNil(bare.at("dns", "rules"))
    }

    func testRuleSetsAreRelocated() throws {
        let config = try ConfigBuilder.build(subscription: try subscription(), selected: nil, options: TunnelOptions())
        XCTAssertEqual(config.at("route", "rule_set")?[0]?["path"], "@rules/ad-block.srs")
        let moved = ConfigBuilder.relocateRuleSets(in: config, directory: "/bundle/Rules")
        XCTAssertEqual(moved.at("route", "rule_set")?[0]?["path"], "/bundle/Rules/ad-block.srs")
        XCTAssertEqual(moved.at("route", "rule_set")?[6]?["path"], "/bundle/Rules/ru-ip.srs")
    }

    /// 3.1.7: with the kill switch (include all networks) sing-tun accepts only
    /// gVisor; without it the built stack stays.
    func testKillSwitchTakesGVisorStack() throws {
        let config = try ConfigBuilder.build(subscription: try subscription(), selected: nil, options: TunnelOptions())
        XCTAssertEqual(config["inbounds"]?[0]?["stack"], "mixed")
        let same = ConfigBuilder.stackForIncludeAllNetworks(in: config, includeAllNetworks: false)
        XCTAssertEqual(same["inbounds"]?[0]?["stack"], "mixed")
        let locked = ConfigBuilder.stackForIncludeAllNetworks(in: config, includeAllNetworks: true)
        XCTAssertEqual(locked["inbounds"]?[0]?["stack"], "gvisor")
        XCTAssertEqual(locked["inbounds"]?[0]?["type"], "tun")
        XCTAssertEqual(locked["outbounds"], config["outbounds"])
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
        options.autoSelect = true
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
        XCTAssertEqual(object("proxy")?["default"], "auto")
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

/// Beta: the app group is found in the signing profile when the declared one is not granted.
final class AppGroupProfileTests: XCTestCase {
    func testGroupsComeFromTheProfilePlist() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Entitlements</key><dict>
        <key>com.apple.security.application-groups</key><array><string>group.example.one</string><string>group.example.two</string></array>
        </dict></dict></plist>
        """
        var data = Data([0x30, 0x82, 0x01, 0x00, 0xFF])
        data.append(Data(plist.utf8))
        data.append(Data([0x00, 0xA0, 0x82]))
        XCTAssertEqual(AppGroup.groups(inProfile: data), ["group.example.one", "group.example.two"])
        XCTAssertEqual(AppGroup.groups(inProfile: Data([1, 2, 3])), [])
    }
}

/// 3.1.14: VLESS REALITY over gRPC runs in Xray-core whatever form it came in.
final class RealityGRPCInXrayTests: XCTestCase {
    static let link = "vless://11111111-2222-3333-4444-555555555555@g.example.com:443?security=reality&pbk=frA_WzVIkA2NPG1EUvGDN8WoFAneqhPgaBGe9FvsaKc&sid=ab&sni=www.example.com&fp=firefox&type=grpc&serviceName=svc#G"

    func testLinkImportsAsXrayBacked() throws {
        let nodes = NodeAssembler.assemble([try ShareLink.parse(Self.link)])
        XCTAssertEqual(nodes[0].type, XrayBacked.type)
        XCTAssertEqual(nodes[0].outbound["server"], "g.example.com")
        XCTAssertEqual(nodes[0].facts.badges.last, "Xray")
        let proxy = try XCTUnwrap(nodes[0].outbound.at("xray", "outbounds")?.arrayValue?.first)
        XCTAssertEqual(proxy.at("streamSettings", "network"), "grpc")
        XCTAssertEqual(proxy.at("streamSettings", "security"), "reality")
        XCTAssertEqual(proxy.at("streamSettings", "grpcSettings", "serviceName"), "svc")
        XCTAssertEqual(proxy.at("streamSettings", "realitySettings", "serverName"), "www.example.com")
        XCTAssertEqual(proxy.at("streamSettings", "realitySettings", "shortId"), "ab")
        XCTAssertEqual(proxy.at("streamSettings", "realitySettings", "fingerprint"), "firefox")
    }

    func testSavedSingBoxServerRunsInXray() throws {
        var outbound = try ShareLink.parse(Self.link).outbound
        outbound["tag"] = "G"
        let saved = ServerNode(id: "G", name: "G", outbound: outbound)
        XCTAssertEqual(saved.type, "vless")
        XCTAssertEqual(saved.facts.badges.last, "Xray")
        let subscription = Subscription(id: 1, name: "S", nodes: [saved])
        let config = try ConfigBuilder.build(subscription: subscription, selected: nil, options: TunnelOptions())
        let hop = try XCTUnwrap(config["outbounds"]?.arrayValue?.first { $0["tag"] == "G" })
        XCTAssertEqual(hop["type"], "socks")
        let runtime = try XCTUnwrap(ConfigBuilder.xrayRuntime(subscription: subscription))
        XCTAssertTrue(runtime["outbounds"]?.arrayValue?.contains { $0.at("streamSettings", "grpcSettings", "serviceName") == "svc" } ?? false)
    }
}
