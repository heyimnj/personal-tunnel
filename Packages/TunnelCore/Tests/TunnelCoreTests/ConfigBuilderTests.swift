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

    /// 3.2.2: an updated subscription restarts the core only when what the tunnel
    /// runs changed: not for new names, another order or other servers.
    func testRunningFingerprintFollowsOnlyTheRunningServers() throws {
        let subscription = try subscription()
        let options = TunnelOptions()
        let original = ConfigBuilder.runningFingerprint(subscription, selected: "Hy2", options: options)
        XCTAssertEqual(original, ConfigBuilder.runningFingerprint(subscription, selected: "Hy2", options: options))

        var renamed = subscription
        renamed.nodes = renamed.nodes.reversed().map { node in
            var node = node
            node.name += " (новое имя)"
            node.link = nil
            return node
        }
        XCTAssertEqual(ConfigBuilder.runningFingerprint(renamed, selected: "Hy2", options: options), original)

        let other = try XCTUnwrap(subscription.nodes.first { $0.id != "Hy2" && !ConfigBuilder.tunnelSubscription(subscription, selected: "Hy2", options: options).nodes.contains($0) })
        var otherChanged = subscription
        otherChanged.nodes = otherChanged.nodes.map { node in
            var node = node
            if node.id == other.id { node.outbound["server_port"] = .int(1) }
            return node
        }
        XCTAssertEqual(ConfigBuilder.runningFingerprint(otherChanged, selected: "Hy2", options: options), original)

        var activeChanged = subscription
        activeChanged.nodes = activeChanged.nodes.map { node in
            var node = node
            if node.id == "Hy2" { node.outbound["server_port"] = .int(1) }
            return node
        }
        XCTAssertNotEqual(ConfigBuilder.runningFingerprint(activeChanged, selected: "Hy2", options: options), original)

        var removed = subscription
        removed.nodes.removeAll { $0.id == "Hy2" }
        XCTAssertNotEqual(ConfigBuilder.runningFingerprint(removed, selected: "Hy2", options: options), original)

        // With automatic selection the tunnel runs every server: any of them counts.
        var auto = options
        auto.autoSelect = true
        XCTAssertNotEqual(ConfigBuilder.runningFingerprint(otherChanged, selected: "Hy2", options: auto),
                          ConfigBuilder.runningFingerprint(subscription, selected: "Hy2", options: auto))
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
        XCTAssertEqual(config.at("dns", "servers")?.arrayValue?.map { $0["tag"] },
                       ["dns-direct", "dns-direct-https", "dns-direct-plain", "dns-direct-1", "dns-direct-2", "dns-direct-udp-1", "dns-direct-udp-2"])
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
        // 3.2.9: 1500 again (4064 kept the extension at its memory limit).
        XCTAssertEqual(config.at("inbounds")?[0]?["mtu"], 1500)
        XCTAssertEqual(config.at("inbounds")?[0]?["udp_timeout"], "1m")
    }

    /// 3.2.3: the kill switch changes the stack to gVisor and keeps the MTU; the
    /// start line reads both from the configuration the core gets.
    func testTunSummaryWithAndWithoutKillSwitch() throws {
        let node = NodeAssembler.assemble([try ShareLink.parse("trojan://pw@b.example.com:443#B")])
        let config = try ConfigBuilder.build(subscription: Subscription(id: 1, name: "B", nodes: node), selected: nil, options: TunnelOptions())
        XCTAssertEqual(ConfigBuilder.tunSummary(of: config)?.stack, "mixed")
        XCTAssertEqual(ConfigBuilder.tunSummary(of: config)?.mtu, ConfigBuilder.tunMTU)
        let killSwitch = ConfigBuilder.stackForIncludeAllNetworks(in: config, includeAllNetworks: true)
        XCTAssertEqual(ConfigBuilder.tunSummary(of: killSwitch)?.stack, "gvisor")
        XCTAssertEqual(ConfigBuilder.tunSummary(of: killSwitch)?.mtu, 1500)
        XCTAssertNil(ConfigBuilder.tunSummary(of: ["inbounds": []]))
    }

    /// 3.2.7: with the kill switch the app's tests leave the tunnel by a loopback
    /// way out with a login: the tunnel listens only on 127.0.0.1, routes only that
    /// inbound direct (first, before sniffing) and opens nothing for other traffic;
    /// the probe configuration dials every server and resolver through it.
    func testProbeExitOpensNothingButTheAppsWayOut() throws {
        let subscription = try subscription()
        let exit = ProbeExit(port: 34567, username: "u", password: "p")
        let config = try ConfigBuilder.build(subscription: subscription, selected: nil, options: TunnelOptions(), probeExit: exit)
        XCTAssertTrue(ConfigBuilder.hasProbeExit(config))
        let socks = try XCTUnwrap(config["inbounds"]?.arrayValue?.first { $0["type"]?.stringValue == "socks" })
        XCTAssertEqual(socks["listen"]?.stringValue, "127.0.0.1")
        XCTAssertEqual(socks["listen_port"]?.intValue, 34567)
        XCTAssertEqual(socks["users"]?.arrayValue?.first?["password"]?.stringValue, "p")
        let rules = try XCTUnwrap(config["route"]?["rules"]?.arrayValue)
        XCTAssertEqual(rules.first?["inbound"]?.stringList, [ProbeExit.inboundTag])
        XCTAssertEqual(rules.first?["outbound"]?.stringValue, ProbeExit.directTag)
        XCTAssertEqual(rules.first?["udp_timeout"]?.stringValue, ProbeExit.udpTimeout)
        let direct = try XCTUnwrap(config["outbounds"]?.arrayValue?.first { $0["tag"]?.stringValue == ProbeExit.directTag })
        XCTAssertEqual(direct["type"]?.stringValue, "direct")
        XCTAssertEqual(direct["connect_timeout"]?.stringValue, ProbeExit.connectTimeout)
        // Nothing else goes direct but the bypasses, as without the way out (PT-06).
        let without = try ConfigBuilder.build(subscription: subscription, selected: nil, options: TunnelOptions())
        XCTAssertEqual(Array(rules.dropFirst()), without["route"]?["rules"]?.arrayValue)
        XCTAssertEqual(config["outbounds"]?.arrayValue?.filter { $0["tag"]?.stringValue != ProbeExit.directTag }, without["outbounds"]?.arrayValue)
        XCTAssertFalse(ConfigBuilder.hasProbeExit(without))

        // Without the kill switch the extension drops it; the rest stays.
        let stripped = ConfigBuilder.probeExit(in: config, keep: false)
        XCTAssertEqual(stripped, without)
        XCTAssertEqual(ConfigBuilder.probeExit(in: config, keep: true), config)

        let probe = try ConfigBuilder.probe(subscription: subscription, options: TunnelOptions(), exit: exit)
        let outbounds = try XCTUnwrap(probe["outbounds"]?.arrayValue)
        let out = try XCTUnwrap(outbounds.first { $0["tag"]?.stringValue == ProbeExit.outboundTag })
        XCTAssertEqual(out["server"]?.stringValue, "127.0.0.1")
        XCTAssertEqual(out["server_port"]?.intValue, 34567)
        XCTAssertEqual(out["username"]?.stringValue, "u")
        for outbound in outbounds {
            let type = outbound["type"]?.stringValue ?? ""
            if ConfigBuilder.notDialing.contains(type) || outbound["tag"]?.stringValue == ProbeExit.outboundTag {
                XCTAssertNil(outbound["detour"], type)
            } else {
                XCTAssertNotNil(outbound["detour"], type)
            }
        }
        for server in probe["dns"]?["servers"]?.arrayValue ?? [] where server["type"]?.stringValue != "group" {
            XCTAssertEqual(server["detour"]?.stringValue, ProbeExit.outboundTag)
        }
        // Without a way out the probe is as before.
        XCTAssertNil(try ConfigBuilder.probe(subscription: subscription, options: TunnelOptions())["outbounds"]?.arrayValue?
            .first { $0["tag"]?.stringValue == ProbeExit.outboundTag })
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

    /// 3.3 (PT-09): the presets of the resolver setting.
    func testResolverPresets() {
        XCTAssertEqual(DirectResolvers.addresses("quad9"), ["9.9.9.9", "149.112.112.112"])
        XCTAssertEqual(DirectResolvers.addresses("unknown"), DirectResolvers.defaultAddresses)
        XCTAssertEqual(DirectResolvers.presets.first?.id, DirectResolvers.defaultPreset)
        XCTAssertEqual(DirectResolvers.https(tag: "x", address: "77.88.8.1").at("tls", "server_name"), "common.dot.dns.yandex.net")
        XCTAssertNil(DirectResolvers.https(tag: "x", address: "1.1.1.1")["tls"])
    }

    /// 3.3 (PT-11): the TUN always has an IPv6 address, so IPv6 goes into the
    /// tunnel too (without one the extension sets no IPv6 route and it would leak).
    func testTunAlwaysHasAnIPv6Address() throws {
        var options = TunnelOptions()
        for (bypass, ads, auto) in [(true, true, false), (false, false, true)] {
            options.bypassRussia = bypass
            options.adBlocking = ads
            options.autoSelect = auto
            let config = try ConfigBuilder.build(subscription: try subscription(), selected: nil, options: options)
            for (name, document) in [("tunnel", config), ("kill switch", ConfigBuilder.stackForIncludeAllNetworks(in: config, includeAllNetworks: true))] {
                let tun = try XCTUnwrap(document["inbounds"]?.arrayValue?.first { $0["type"] == "tun" }, name)
                let addresses = tun["address"]?.stringList ?? []
                XCTAssertTrue(addresses.contains { $0.contains(":") && $0.contains("/") }, "\(name): no IPv6 address in \(addresses)")
                XCTAssertTrue(addresses.contains { !$0.contains(":") }, name)
                XCTAssertEqual(tun["auto_route"], true)
            }
        }
    }

    /// 3.3 (PT-06): the tunnel the app writes sends no server's address around
    /// the VPN — no rule outside the bypasses goes `direct` — and the app's own
    /// core is bound to the physical interface instead.
    func testServersStayInsideTheTunnelAndTheProbeIsBound() throws {
        let subscription = try subscription()
        var options = TunnelOptions()
        options.bypassRussia = false
        options.bypassPrivate = false
        options.subscriptionHosts = ["panel.example.org"]
        let config = try ConfigBuilder.build(subscription: subscription, selected: nil, options: options)
        let rules = config.at("route", "rules")?.arrayValue ?? []
        XCTAssertFalse(rules.contains { $0["outbound"] == "direct" })
        let hosts = Set(ConfigBuilder.serverHosts(of: [subscription]))
        for rule in rules {
            let matched = Set((rule["domain"]?.stringList ?? []) + (rule["ip_cidr"]?.stringList ?? []).map { String($0.split(separator: "/")[0]) })
            XCTAssertTrue(matched.isDisjoint(with: hosts), "a rule names a server: \(rule)")
        }
        XCTAssertNil(config.at("dns", "rules")?.arrayValue?.first { $0["server"] == "dns-direct" && $0["domain"] != nil })
        // With the bypasses on, only they (private and Russian addresses) go direct.
        let bypass = try ConfigBuilder.build(subscription: subscription, selected: nil, options: TunnelOptions())
        let direct = (bypass.at("route", "rules")?.arrayValue ?? []).filter { $0["outbound"] == "direct" }
        XCTAssertEqual(direct.count, 2)
        XCTAssertTrue(direct.allSatisfy { $0["ip_is_private"] == true || $0["rule_set"] != nil })

        let bound = try ConfigBuilder.probe(subscription: subscription, options: TunnelOptions(), interface: "en0")
        XCTAssertEqual(bound.at("route", "default_interface"), "en0")
        XCTAssertNil(try ConfigBuilder.probe(subscription: subscription, options: TunnelOptions()).at("route", "default_interface"))
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
        XCTAssertEqual(full.at("dns", "servers")?[0]?["servers"], ["dns-remote-tcp", "dns-remote-https"])
        XCTAssertEqual(full.at("dns", "servers")?[0]?["mode"], "ordered")
        XCTAssertEqual(full.at("dns", "servers")?[1]?["type"], "https")
        XCTAssertEqual(full.at("dns", "servers")?[1]?["detour"], "proxy")
        XCTAssertEqual(full.at("dns", "servers")?[2]?["type"], "tcp")
        XCTAssertEqual(full.at("dns", "servers")?[2]?["detour"], "proxy")
        // 3.3 (PT-09): outside the tunnel, the setting's resolvers at once, over HTTPS by
        // address; beta 3: the same over UDP only while HTTPS fails (an `ordered` group).
        func server(_ document: JSONValue, _ tag: String) -> JSONValue? { document.at("dns", "servers")?.arrayValue?.first { $0["tag"]?.stringValue == tag } }
        XCTAssertEqual(full.at("dns", "servers")?[3]?["tag"], "dns-direct")
        XCTAssertEqual(server(full, "dns-direct")?["type"], "group")
        XCTAssertEqual(server(full, "dns-direct")?["mode"], "ordered")
        XCTAssertEqual(server(full, "dns-direct")?["servers"], ["dns-direct-https", "dns-direct-plain"])
        XCTAssertEqual(server(full, "dns-direct-https")?["mode"], "parallel")
        XCTAssertEqual(server(full, "dns-direct-https")?["servers"], ["dns-direct-1", "dns-direct-2"])
        XCTAssertEqual(server(full, "dns-direct-plain")?["servers"], ["dns-direct-udp-1", "dns-direct-udp-2"])
        XCTAssertEqual(server(full, "dns-direct-1")?["server"], "1.1.1.1")
        XCTAssertEqual(server(full, "dns-direct-1")?["type"], "https")
        XCTAssertEqual(server(full, "dns-direct-2")?["server"], "8.8.8.8")
        XCTAssertEqual(server(full, "dns-direct-udp-1")?["type"], "udp")
        XCTAssertEqual(server(full, "dns-direct-udp-2")?["server"], "8.8.8.8")
        XCTAssertNil(server(full, "dns-direct-1")?["detour"])
        XCTAssertEqual(full.at("route", "default_domain_resolver", "server"), "dns-direct")
        // Yandex only for the Russian names of the bypass, over HTTPS with its certificate's name first.
        let russian = try XCTUnwrap(server(full, "dns-ru"))
        XCTAssertEqual(russian["mode"], "ordered")
        XCTAssertEqual(russian["servers"], ["dns-ru-https", "dns-ru-plain"])
        XCTAssertEqual(server(full, "dns-ru-1")?["type"], "https")
        XCTAssertEqual(server(full, "dns-ru-1")?["server"], "77.88.8.8")
        XCTAssertEqual(server(full, "dns-ru-1")?.at("tls", "server_name"), "common.dot.dns.yandex.net")
        XCTAssertEqual(server(full, "dns-ru-udp-1")?["server"], "77.88.8.8")
        XCTAssertTrue(full.at("dns", "rules")?.arrayValue?.contains { $0["server"] == "dns-ru" && $0["rule_set"] == ["pt-ru-domains", "pt-ru-inside"] } ?? false)
        let direct = (full.at("dns", "servers")?.arrayValue ?? []).filter { $0["tag"]?.stringValue?.hasPrefix("dns-direct-") ?? false }
        XCTAssertFalse(direct.contains { $0["server"] == "77.88.8.8" })
        // 3.5.17: QUIC is refused only after every rule that leaves the VPN.
        let fullRules = full.at("route", "rules")?.arrayValue ?? []
        let quicRule: JSONValue = ["network": "udp", "port": 443, "action": "reject", "no_drop": true]
        XCTAssertEqual(fullRules.last, quicRule)
        let bypass = fullRules.firstIndex { (rule: JSONValue) -> Bool in rule["outbound"] == "direct" && rule["rule_set"] != nil }
        XCTAssertNotNil(bypass)

        options.adBlocking = false
        options.bypassRussia = false
        options.bypassPrivate = false
        options.directResolvers = ["9.9.9.9", "9.9.9.9", "149.112.112.112"]
        let bare = try ConfigBuilder.build(subscription: subscription, selected: nil, options: options)
        // The setting's resolvers, each once; no Yandex without the bypass.
        XCTAssertEqual(server(bare, "dns-direct-https")?["servers"], ["dns-direct-1", "dns-direct-2"])
        XCTAssertEqual(server(bare, "dns-direct-1")?["server"], "9.9.9.9")
        XCTAssertNil(server(bare, "dns-ru"))
        // 3.5.17: sniff, DNS and the QUIC refusal (on by default).
        XCTAssertEqual(bare.at("route", "rules")?.arrayValue?.count, 3)
        XCTAssertEqual(bare.at("route", "rules")?.arrayValue?.last, ["network": "udp", "port": 443, "action": "reject", "no_drop": true])
        options.blockQUIC = false
        let quic = try ConfigBuilder.build(subscription: subscription, selected: nil, options: options)
        XCTAssertEqual(quic.at("route", "rules")?.arrayValue?.count, 2)
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

    /// 3.3 beta 2 (PT-01, PT-02): sing-box hands an Xray-backed server's
    /// connections to the Xray instance in the same process: an `xray-local`
    /// outbound naming the instance and an inbound tag that Xray's routing sends to
    /// the server's outbounds. No inbound, port or login anywhere.
    func testTunnelReachesXrayServersInTheSameProcess() throws {
        let nodes = NodeAssembler.assemble(try ContentImporter.parse(Self.subscriptionJSON).nodes)
        XCTAssertEqual(nodes.map(\.type), ["xray", "trojan", "xray"])
        let subscription = Subscription(id: 3, name: "X", nodes: nodes)
        let made = try ConfigBuilder.tunnel(subscription: subscription, selected: nil, options: TunnelOptions())
        let outbounds = made.config["outbounds"]?.arrayValue ?? []
        let sudoku = try XCTUnwrap(outbounds.first { $0["tag"]?.stringValue == nodes[0].id })
        XCTAssertEqual(sudoku, ["type": "xray-local", "tag": .string(nodes[0].id), "instance": "tunnel", "inbound": "in0"])
        XCTAssertEqual(outbounds.first { $0["tag"]?.stringValue == nodes[2].id }?["inbound"], "in1")
        XCTAssertNil(sudoku["xray"])
        let text = made.config.serialized()
        XCTAssertFalse(text.contains("\"xray\""))
        XCTAssertFalse(text.contains("127.0.0.1"))

        let runtime = try XCTUnwrap(made.xray)
        XCTAssertNil(runtime["inbounds"])
        XCTAssertFalse(runtime.serialized().contains("\"port\":2"))
        let rules = runtime.at("routing", "rules")?.arrayValue ?? []
        XCTAssertEqual(rules.map { $0["inboundTag"] }, [["in0"], ["in1"]])
        XCTAssertEqual(rules.map { $0["outboundTag"] }, ["tunneln0-proxy", "tunneln1-exit"])
        let exit = runtime["outbounds"]?.arrayValue?.first { $0["tag"] == "tunneln1-exit" }
        XCTAssertEqual(exit?.at("streamSettings", "sockopt", "dialerProxy"), "tunneln1-hop")
        XCTAssertEqual(XrayBacked.prefixes(for: nodes, instance: "tunnel"), [nodes[0].id: "tunneln0-", nodes[2].id: "tunneln1-"])
        XCTAssertNil(ConfigBuilder.xrayRuntime(subscription: Subscription(id: 4, name: "Y", nodes: [nodes[1]])))

        // The app's measuring core: an instance of its own per subscription.
        let probe = try ConfigBuilder.probe(subscription: subscription, options: TunnelOptions())
        XCTAssertEqual(probe["outbounds"]?.arrayValue?.first { $0["tag"]?.stringValue == nodes[2].id }?["instance"], "s3")
        let appRuntime = try XCTUnwrap(ConfigBuilder.xrayRuntime(subscription: subscription, instance: XrayBacked.appInstance(3)))
        XCTAssertEqual(appRuntime.at("routing", "rules")?[0]?["outboundTag"], "s3n0-proxy")
    }
}

extension XrayBackedTests {
    func testPrepareBindsHopsToTheInterfaceAndLogsToAFile() throws {
        let nodes = NodeAssembler.assemble(try ContentImporter.parse(Self.subscriptionJSON).nodes)
        let runtime = try XCTUnwrap(ConfigBuilder.xrayRuntime(subscription: Subscription(id: 3, name: "X", nodes: nodes)))
        let first = "tunneln0", second = "tunneln1"
        let ready = XrayBacked.prepare(runtime, interface: "en0", logPath: "/tmp/xray.log")
        XCTAssertEqual(ready.at("log", "error"), "/tmp/xray.log")
        let outbounds = ready["outbounds"]?.arrayValue ?? []
        func tagged(_ tag: String) -> JSONValue? { outbounds.first { $0["tag"]?.stringValue == tag } }
        XCTAssertEqual(tagged("\(first)-proxy")?.at("streamSettings", "sockopt", "interface"), "en0")
        XCTAssertEqual(tagged("\(first)-direct")?.at("streamSettings", "sockopt", "interface"), "en0")
        // The chain's exit dials through its hop; the hop is the one bound.
        XCTAssertNil(tagged("\(second)-exit")?.at("streamSettings", "sockopt", "interface"))
        XCTAssertEqual(tagged("\(second)-hop")?.at("streamSettings", "sockopt", "interface"), "en0")
        XCTAssertNil(tagged("pt-block")?["streamSettings"])
        XCTAssertEqual(XrayBacked.prepare(runtime, interface: nil, logPath: nil), runtime)
        XCTAssertEqual(XrayBacked.prepare(runtime, interface: nil, logPath: "/tmp/p.log", level: "info").at("log", "loglevel"), "info")
    }

    /// 3.2.8: with the kill switch Xray's hops dial through the tunnel's way out
    /// (a socks outbound with the app's login), not through the connected server.
    func testPrepareDialsHopsThroughTheProbeExit() throws {
        let nodes = NodeAssembler.assemble(try ContentImporter.parse(Self.subscriptionJSON).nodes)
        let runtime = try XCTUnwrap(ConfigBuilder.xrayRuntime(subscription: Subscription(id: 3, name: "X", nodes: nodes)))
        let exit = ProbeExit(port: 34567, username: "u", password: "p")
        let ready = XrayBacked.prepare(runtime, interface: "en0", logPath: nil, exit: exit)
        let outbounds = ready["outbounds"]?.arrayValue ?? []
        func tagged(_ tag: String) -> JSONValue? { outbounds.first { $0["tag"]?.stringValue == tag } }
        let socks = try XCTUnwrap(tagged(ProbeExit.outboundTag))
        XCTAssertEqual(socks["protocol"], "socks")
        XCTAssertEqual(socks.at("settings", "address"), "127.0.0.1")
        XCTAssertEqual(socks.at("settings", "port")?.intValue, 34567)
        XCTAssertEqual(socks.at("settings", "user"), "u")
        XCTAssertEqual(socks.at("settings", "pass"), "p")
        XCTAssertEqual(tagged("tunneln0-proxy")?.at("streamSettings", "sockopt", "dialerProxy")?.stringValue, ProbeExit.outboundTag)
        XCTAssertNil(tagged("tunneln0-proxy")?.at("streamSettings", "sockopt", "interface"))
        // A chain: its exit keeps dialling through its hop; the hop goes out this way.
        XCTAssertEqual(tagged("tunneln1-exit")?.at("streamSettings", "sockopt", "dialerProxy")?.stringValue, "tunneln1-hop")
        XCTAssertEqual(tagged("tunneln1-hop")?.at("streamSettings", "sockopt", "dialerProxy")?.stringValue, ProbeExit.outboundTag)
        XCTAssertNil(tagged("pt-block")?["streamSettings"])
    }

    /// 3.1.15: Xray-core's reason for a failed test, read from its «info» log by the
    /// server's tag prefix (lines as Xray v26.11.9 writes them).
    func testFailureIsReadFromTheLogByPrefix() {
        let log = """
        2026/11/16 08:12:17.714340 [Warning] core: Xray 26.11.9 started
        2026/11/16 08:12:26.904990 [Info] [1936113593] proxy/socks: TCP Connect request to tcp:www.gstatic.com:443
        2026/11/16 08:12:26.905060 [Info] [1936113593] app/dispatcher: taking detour [s1n1-proxy] for [tcp:www.gstatic.com:443]
        2026/11/16 08:12:26.905061 [Info] [77] app/dispatcher: taking detour [s1n2-proxy] for [tcp:www.gstatic.com:443]
        2026/11/16 08:12:26.911571 [Info] [1936113593] transport/internet/grpc: creating connection to tcp:fi.example.com:443
        2026/11/16 08:12:27.000000 [Info] [77] app/proxyman/outbound: app/proxyman/outbound: failed to process outbound traffic > other server
        2026/11/16 08:12:28.915099 [Info] [1936113593] app/proxyman/outbound: app/proxyman/outbound: failed to process outbound traffic > proxy/vless/outbound: failed to find an available destination > common/retry: [transport/internet/grpc: failed to dial gRPC > rpc error: code = Unavailable desc = "transport: Error while dialing: EOF"] > common/retry: all retry attempts failed
        """
        XCTAssertEqual(XrayBacked.failure(inLog: log, prefix: "s1n1-"),
                       "proxy/vless/outbound: failed to find an available destination > common/retry: [transport/internet/grpc: failed to dial gRPC > rpc error: code = Unavailable desc = \"transport: Error while dialing: EOF\"]")
        XCTAssertEqual(XrayBacked.failure(inLog: log, prefix: "s1n2-"), "other server")
        XCTAssertNil(XrayBacked.failure(inLog: log, prefix: "s1n3-"))
        // s1n is not s1n1: the prefix ends with «-».
        XCTAssertNil(XrayBacked.failure(inLog: log, prefix: "s1n-"))
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
        let made = try ConfigBuilder.tunnel(subscription: subscription, selected: nil, options: TunnelOptions())
        let hop = try XCTUnwrap(made.config["outbounds"]?.arrayValue?.first { $0["tag"] == "G" })
        XCTAssertEqual(hop["type"], "xray-local")
        let runtime = try XCTUnwrap(made.xray)
        XCTAssertTrue(runtime["outbounds"]?.arrayValue?.contains { $0.at("streamSettings", "grpcSettings", "serviceName") == "svc" } ?? false)
    }
}

/// 3.3 (PT-04): servers whose certificate is not checked are marked; Xray-core
/// gets no `allowInsecure` (v26.11.9 refuses it and the runtime would not start).
final class CertificateCheckTests: XCTestCase {
    func testUncheckedServersAreMarkedAndCounted() throws {
        let unchecked = try ShareLink.parse("trojan://pw@t.example.net:443?security=tls&sni=t.example.net&allowInsecure=1#Unchecked")
        let pinned = try ShareLink.parse("trojan://pw@p.example.net:443?security=tls&sni=p.example.net&allowInsecure=1&pcs=" + String(repeating: "ab", count: 32) + "#Pinned")
        let checked = try ShareLink.parse("trojan://pw@c.example.net:443?security=tls&sni=c.example.net#Checked")
        let reality = try ShareLink.parse("vless://11111111-2222-3333-4444-555555555555@r.example.net:443?security=reality&sni=www.apple.com&pbk=frA_WzVIkA2NPG1EUvGDN8WoFAneqhPgaBGe9FvsaKc&sid=ab12&fp=chrome&allowInsecure=1#Reality")
        let nodes = NodeAssembler.assemble([unchecked, pinned, checked, reality])
        XCTAssertEqual(nodes.map(\.facts.certificateUnchecked), [true, false, false, false])
        XCTAssertTrue(nodes[0].facts.badges.contains(ProtocolFacts.uncheckedBadge))
        XCTAssertTrue(nodes[0].facts.summary.hasSuffix(ProtocolFacts.uncheckedBadge))
        XCTAssertFalse(nodes[2].facts.badges.contains(ProtocolFacts.uncheckedBadge))
        XCTAssertEqual(CertificateCheck.unchecked(nodes), 1)
        XCTAssertNotNil(CertificateCheck.summary(nodes))
        XCTAssertNil(CertificateCheck.summary(Array(nodes.dropFirst())))
    }

    func testXrayRuntimeCarriesNoAllowInsecure() throws {
        let json = #"""
        [{"remarks": "Masked", "outbounds": [
           {"tag": "proxy", "protocol": "vless", "settings": {"vnext": [{"address": "s.example.net", "port": 443, "users": [{"id": "11111111-2222-3333-4444-555555555555", "encryption": "none"}]}]},
            "streamSettings": {"network": "raw", "security": "tls", "tlsSettings": {"serverName": "s.example.net", "allowInsecure": true},
              "finalmask": {"tcp": [{"type": "sudoku", "settings": {"password": "mask"}}]}}}]}]
        """#
        let nodes = NodeAssembler.assemble(try ContentImporter.parse(json).nodes)
        XCTAssertEqual(nodes.first?.type, XrayBacked.type)
        let made = try ConfigBuilder.tunnel(subscription: Subscription(id: 1, name: "X", nodes: nodes), selected: nil, options: TunnelOptions())
        XCTAssertFalse(try XCTUnwrap(made.xray).serialized().contains("allowInsecure"))
        // The editor offers no «do not check» for an Xray server, and writing it back adds none.
        let plain: JSONValue = ["type": "xray", "server": "w.example.net", "server_port": 443, "xray": ["outbounds": [[
            "tag": "proxy", "protocol": "vless",
            "settings": ["vnext": [["address": "w.example.net", "port": 443, "users": [["id": "11111111-2222-3333-4444-555555555555", "encryption": "none"]]]]],
            "streamSettings": ["network": "ws", "security": "tls", "tlsSettings": ["serverName": "w.example.net", "allowInsecure": true], "wsSettings": ["path": "/w"]],
        ]]]]
        var draft = try XCTUnwrap(XrayBacked.draft(plain, name: "Plain"))
        XCTAssertFalse(draft.allowsInsecure)
        XCTAssertFalse(draft.insecure)
        draft.insecure = true
        let edited = try XrayBacked.apply(draft, to: plain)
        XCTAssertFalse(edited.serialized().contains("allowInsecure"))
        XCTAssertEqual(edited.at("xray", "outbounds")?[0]?.at("streamSettings", "tlsSettings", "serverName"), "w.example.net")
    }
}
