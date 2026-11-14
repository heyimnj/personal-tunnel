import XCTest
@testable import TunnelCore

final class ImportTests: XCTestCase {
    static let realityKey = "SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc"

    static let xraySubscription = """
    [
      {
        "remarks": "🇺🇸 США-2",
        "outbounds": [
          {"tag": "proxy", "protocol": "vless",
           "settings": {"vnext": [{"address": "us.example.net", "port": 443, "users": [{"id": "11111111-2222-3333-4444-555555555555", "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
           "streamSettings": {"network": "raw", "security": "reality", "realitySettings": {"serverName": "www.apple.com", "publicKey": "\(realityKey)", "shortId": "abcd", "fingerprint": "chrome"}}},
          {"tag": "direct", "protocol": "freedom"},
          {"tag": "block", "protocol": "blackhole"}
        ]
      },
      {
        "remarks": "Самый быстрый | Авто",
        "outbounds": [
          {"tag": "a", "protocol": "vless", "settings": {"address": "a.example.net", "port": 443, "id": "aaaaaaaa-2222-3333-4444-555555555555", "encryption": "none"},
           "streamSettings": {"network": "ws", "security": "tls", "tlsSettings": {"serverName": "a.example.net", "alpn": ["h2", "http/1.1"]}, "wsSettings": {"path": "/ws", "headers": {"Host": "a.example.net"}}}},
          {"tag": "b", "protocol": "vless", "settings": {"address": "b.example.net", "port": 443, "id": "bbbbbbbb-2222-3333-4444-555555555555", "encryption": "none"},
           "streamSettings": {"network": "ws", "security": "tls", "tlsSettings": {"serverName": "b.example.net"}, "wsSettings": {"path": "/ws", "host": "b.example.net"}}},
          {"tag": "direct", "protocol": "freedom"}
        ],
        "routing": {"balancers": [{"tag": "auto", "selector": ["a", "b"]}]}
      },
      {
        "remarks": "XHTTP",
        "outbounds": [
          {"tag": "proxy", "protocol": "vless", "settings": {"vnext": [{"address": "x.example.net", "port": 443, "users": [{"id": "cccccccc-2222-3333-4444-555555555555", "encryption": "none"}]}]},
           "streamSettings": {"network": "xhttp", "security": "tls", "tlsSettings": {"serverName": "x.example.net"},
             "xhttpSettings": {"host": "x.example.net", "path": "/xh", "mode": "auto", "extra": {"xPaddingBytes": "100-1000", "noGRPCHeader": false}}}}
        ]
      },
      {
        "remarks": "Hy2",
        "outbounds": [
          {"tag": "proxy", "protocol": "hysteria", "settings": {"address": "hy.example.net", "port": 443, "version": 2},
           "streamSettings": {"network": "hysteria", "security": "tls", "tlsSettings": {"serverName": "hy.example.net", "alpn": ["h3"]},
             "hysteriaSettings": {"version": 2, "auth": "secret"},
             "finalmask": {"udp": [{"type": "salamander", "settings": {"password": "mask"}}], "quicParams": {"udpHop": {"ports": "20000-30000", "interval": 30}, "congestion": "brutal", "brutalUp": "50 mbps", "brutalDown": "200 mbps"}}}}
        ]
      },
      {
        "remarks": "Сломанный",
        "outbounds": [{"tag": "proxy", "protocol": "vless", "settings": {"vnext": [{"address": "k.example.net", "port": 443, "users": [{"id": "x"}]}]}, "streamSettings": {"network": "kcp"}}]
      }
    ]
    """

    func testXraySubscription() throws {
        let result = try ContentImporter.parse(Self.xraySubscription)
        XCTAssertEqual(result.format, .xray)
        // mKCP is not sing-box's: Xray-core runs that server (3.0.1).
        XCTAssertEqual(result.nodes.map(\.name), ["🇺🇸 США-2", "Самый быстрый | Авто", "XHTTP", "Hy2", "Сломанный"])
        XCTAssertEqual(result.nodes[4].outbound["type"], "xray")
        XCTAssertEqual(result.nodes[4].outbound["server"], "k.example.net")
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertNil(result.summary)

        let reality = result.nodes[0].outbound
        XCTAssertEqual(reality["server"], "us.example.net")
        XCTAssertEqual(reality["flow"], "xtls-rprx-vision")
        XCTAssertEqual(reality.at("tls", "reality", "short_id"), "abcd")
        XCTAssertNil(reality["transport"])

        let group = result.nodes[1]
        XCTAssertEqual(group.outbound["type"], "urltest")
        XCTAssertEqual(group.members.count, 2)
        XCTAssertEqual(group.members[1].at("transport", "headers", "Host"), "b.example.net")

        let xhttp = result.nodes[2].outbound
        XCTAssertEqual(xhttp.at("transport", "type"), "xhttp")
        XCTAssertEqual(xhttp.at("transport", "x_padding_bytes"), "100-1000")
        XCTAssertNil(xhttp.at("transport", "no_grpc_header"))

        let hysteria = result.nodes[3].outbound
        XCTAssertEqual(hysteria["type"], "hysteria2")
        XCTAssertEqual(hysteria["password"], "secret")
        XCTAssertEqual(hysteria.at("obfs", "type"), "salamander")
        XCTAssertEqual(hysteria["server_ports"], ["20000:30000"])
        XCTAssertEqual(hysteria["hop_interval"], "30s")
        XCTAssertEqual(hysteria["up_mbps"], 50)
        XCTAssertEqual(hysteria["down_mbps"], 200)
    }

    /// 3.0.5: Xray's certificate pins in `tlsSettings` reach sing-box.
    func testXrayCertificatePins() throws {
        let hash = String(repeating: "0f", count: 32)
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let vless = try XrayImport.outbound(from: try JSONValue.parse("""
        {"protocol": "vless", "settings": {"vnext": [{"address": "1.2.3.4", "port": 443, "users": [{"id": "u", "flow": "xtls-rprx-vision"}]}]},
         "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "a.internal", "pinnedPeerCertSha256": "\(hash.uppercased())"}}}
        """))
        XCTAssertEqual(vless.at("tls", "certificate_sha256"), [.string(hash)])
        XCTAssertNil(vless.at("tls", "certificate_public_key_sha256"))

        let byKey = try XrayImport.outbound(from: try JSONValue.parse("""
        {"protocol": "trojan", "settings": {"servers": [{"address": "1.2.3.4", "port": 443, "password": "p"}]},
         "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "a.internal", "pinnedPeerCertificatePublicKeySha256": ["\(key)"]}}}
        """))
        XCTAssertEqual(byKey.at("tls", "certificate_public_key_sha256"), [.string(key)])

        let hysteria = try XrayImport.outbound(from: try JSONValue.parse("""
        {"protocol": "hysteria", "settings": {"version": 2, "address": "1.2.3.4", "port": 443},
         "streamSettings": {"network": "hysteria", "security": "tls", "tlsSettings": {"serverName": "a.internal", "pinnedPeerCertSha256": ["\(hash)"]},
                            "hysteriaSettings": {"version": 2, "auth": "secret"}}}
        """))
        XCTAssertEqual(hysteria["type"], "hysteria2")
        XCTAssertEqual(hysteria.at("tls", "certificate_sha256"), [.string(hash)])
    }

    /// A throwaway certificate authority, made for these tests only.
    static let testCAPEM = [
                "-----BEGIN CERTIFICATE-----",
                "MIIBjDCCATGgAwIBAgIUfQdPLS3bgEmJAM4vqh7LZGiegEEwCgYIKoZIzj0EAwIw",
                "GzEZMBcGA1UEAwwQdGVzdC1jYS5pbnRlcm5hbDAeFw0yNjExMTQwNzMyMTRaFw0z",
                "NjExMTEwNzMyMTRaMBsxGTAXBgNVBAMMEHRlc3QtY2EuaW50ZXJuYWwwWTATBgcq",
                "hkjOPQIBBggqhkjOPQMBBwNCAATDuD8/NfPCJ6FA1L2JLNLILG5H4w+LMOqyntdR",
                "FO094RV8migkpqY2vU4d9MPskd4jr1o17RfZi3UjYWTcddKmo1MwUTAdBgNVHQ4E",
                "FgQUrYvAHd3R3unJouY3Qb8DJPip2NowHwYDVR0jBBgwFoAUrYvAHd3R3unJouY3",
                "Qb8DJPip2NowDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNJADBGAiEAvx4a",
                "b3em2AXxqXhsgCNdthZDYF/muipG1AfLy3PPLaECIQDMJmqv/wICAt38bmcq8QTT",
                "AeEDfgCZyanTN5lhFUVqBg==",
                "-----END CERTIFICATE-----",
    ]

    /// 3.1.2: a panel's own certificate authority, written into the Xray config,
    /// is trusted for that server (Xray-core adds it to its roots); a check by
    /// another name than the SNI goes to Xray-core.
    func testXrayTrustedCertificatesAndVerifyNames() throws {
        let lines = Self.testCAPEM.map { "\"" + $0 + "\"" }.joined(separator: ", ")
        let vless = try XrayImport.outbound(from: try JSONValue.parse("""
        {"protocol": "vless", "settings": {"vnext": [{"address": "a.example.com", "port": 443, "users": [{"id": "u", "flow": "xtls-rprx-vision"}]}]},
         "streamSettings": {"network": "tcp", "security": "tls",
                            "tlsSettings": {"serverName": "a.example.com", "fingerprint": "chrome", "certificates": [{"usage": "verify", "certificate": [\(lines)]}]}}}
        """))
        XCTAssertEqual(vless.at("tls", "certificate"), [.string(Self.testCAPEM.joined(separator: "\n"))])
        XCTAssertNil(vless.at("tls", "insecure"))
        XCTAssertEqual(ServerInspection.certificateCheck(ServerNode(id: "a", name: "a", outbound: vless)), "свой центр сертификации")
        let plain = try ShareLink.parse("trojan://pw@tr.example.com:443#T").outbound
        XCTAssertEqual(ServerInspection.certificateCheck(ServerNode(id: "t", name: "t", outbound: plain)), "по корням Mozilla")
        let insecure = try ShareLink.parse("trojan://pw@tr.example.com:443?allowInsecure=1#T").outbound
        XCTAssertEqual(ServerInspection.certificateCheck(ServerNode(id: "i", name: "i", outbound: insecure)), "не проверяется")

        // With a pin as well, the pin decides (the core takes only one of them).
        let pinned = try XrayImport.outbound(from: try JSONValue.parse("""
        {"protocol": "trojan", "settings": {"servers": [{"address": "1.2.3.4", "port": 443, "password": "p"}]},
         "streamSettings": {"network": "tcp", "security": "tls",
                            "tlsSettings": {"serverName": "a.internal", "pinnedPeerCertSha256": "\(String(repeating: "ab", count: 32))",
                                            "certificates": [{"certificate": [\(lines)]}]}}}
        """))
        XCTAssertNil(pinned.at("tls", "certificate"))
        XCTAssertNotNil(pinned.at("tls", "certificate_sha256"))

        // verifyPeerCertByName without a pin: not convertible, the import keeps it for Xray-core.
        let byName = """
        [{"remarks": "By name", "outbounds": [{"protocol": "vless", "tag": "proxy",
          "settings": {"vnext": [{"address": "1.2.3.4", "port": 443, "users": [{"id": "u", "flow": "xtls-rprx-vision"}]}]},
          "streamSettings": {"network": "tcp", "security": "tls",
                             "tlsSettings": {"serverName": "cdn.example.com", "verifyPeerCertByName": "real.example.com"}}}]}]
        """
        XCTAssertThrowsError(try XrayImport.node(from: try JSONValue.parse(byName).listValue[0], name: "By name"))
        let parsed = XrayImport.parse(try JSONValue.parse(byName))
        XCTAssertEqual(parsed.nodes.count, 1)
        XCTAssertEqual(parsed.nodes.first?.outbound["type"], .string(XrayBacked.type))
    }

    /// 3.1.2: Happ's configs send TLS through a `freedom` outbound that splits the
    /// ClientHello; that becomes the core's TLS fragmentation instead of being
    /// dropped. UDP noise goes to Xray-core.
    func testXrayFreedomFragmentAndNoises() throws {
        let fragment = """
        [{"remarks": "Frag", "outbounds": [
          {"protocol": "vless", "tag": "proxy",
           "settings": {"vnext": [{"address": "a.example.com", "port": 443, "users": [{"id": "u", "flow": "xtls-rprx-vision"}]}]},
           "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": "a.example.com", "fingerprint": "chrome"},
                              "sockopt": {"dialerProxy": "fragment"}}},
          {"protocol": "freedom", "tag": "fragment", "settings": {"fragment": {"packets": "tlshello", "length": "100-200", "interval": "10-20"}}},
          {"protocol": "freedom", "tag": "direct"}]}]
        """
        let node = try XrayImport.node(from: try JSONValue.parse(fragment).listValue[0], name: "Frag")
        XCTAssertEqual(node.outbound.at("tls", "fragment"), true)
        XCTAssertEqual(node.outbound.at("tls", "record_fragment"), true)
        XCTAssertNil(node.outbound["detour"])
        XCTAssertTrue(node.members.isEmpty)

        let noise = """
        [{"remarks": "Noise", "outbounds": [
          {"protocol": "hysteria", "tag": "proxy", "settings": {"version": 2, "address": "1.2.3.4", "port": 443},
           "streamSettings": {"network": "hysteria", "security": "tls", "tlsSettings": {"serverName": "h.example.com"},
                              "hysteriaSettings": {"version": 2, "auth": "secret"}, "sockopt": {"dialerProxy": "noise"}}},
          {"protocol": "freedom", "tag": "noise", "settings": {"noises": [{"type": "rand", "packet": "10-20", "delay": "10-16"}]}}]}]
        """
        // The provider's own outbounds stay with the server, shown without secrets or addresses.
        let parsed = XrayImport.parse(try JSONValue.parse(fragment)).nodes[0]
        let assembled = NodeAssembler.assemble([parsed])[0]
        let shown = try XCTUnwrap(ServerInspection.safeSource(assembled))
        XCTAssertTrue(shown.contains("tlshello"))
        XCTAssertFalse(shown.contains("a.example.com\","))
        XCTAssertFalse(shown.contains("\"u\""))
        XCTAssertFalse(shown.contains("\"direct\""))
        let link = NodeAssembler.assemble([try ShareLink.parse("vless://secret-uuid@s.example.com:443?security=tls&sni=s.example.com&sid=ab#L")])[0]
        let linkShown = try XCTUnwrap(ServerInspection.safeSource(link))
        XCTAssertFalse(linkShown.contains("secret-uuid"))
        XCTAssertTrue(linkShown.hasPrefix("vless://***@***:443?"))
        XCTAssertTrue(linkShown.contains("sid=***"))

        XCTAssertThrowsError(try XrayImport.node(from: try JSONValue.parse(noise).listValue[0], name: "Noise"))
        XCTAssertEqual(XrayImport.parse(try JSONValue.parse(noise)).nodes.first?.outbound["type"], .string(XrayBacked.type))
    }

    func testAssemblerMakesUniqueTagsAndRelinksGroups() throws {
        let result = try ContentImporter.parse(Self.xraySubscription)
        let nodes = NodeAssembler.assemble(result.nodes + [result.nodes[0]])
        XCTAssertEqual(nodes.map(\.id), ["🇺🇸 США-2", "Самый быстрый | Авто", "XHTTP", "Hy2", "Сломанный", "🇺🇸 США-2 (2)"])
        let group = nodes[1]
        XCTAssertTrue(group.isGroup)
        XCTAssertEqual(group.outbound["outbounds"], ["Самый быстрый | Авто · 1", "Самый быстрый | Авто · 2"])
        XCTAssertEqual(group.members.map { $0["tag"]?.stringValue }, ["Самый быстрый | Авто · 1", "Самый быстрый | Авто · 2"])
        XCTAssertEqual(group.address?.host, "a.example.net")
        XCTAssertEqual(group.facts.badges, ["VLESS", "TLS", "WebSocket"])
        XCTAssertFalse(group.isUDPBased)
        XCTAssertTrue(nodes[3].isUDPBased)
    }

    func testBase64LinkListWithBadLines() throws {
        let links = """
        vless://uuid@a.example.com:443?security=tls&type=ws&path=%2F#A
        ssr://something
        trojan://pw@b.example.com:443#B
        vless://broken
        """
        let result = try ContentImporter.parse(Data(links.utf8).base64EncodedString())
        XCTAssertEqual(result.format, .links)
        XCTAssertEqual(result.nodes.map(\.name), ["A", "B"])
        XCTAssertEqual(result.issues.count, 2)
    }

    func testSingleLinkSuggestsItsName() throws {
        let result = try ContentImporter.parse("  hysteria2://pw@h.example.com:443#Мой%20сервер \n")
        XCTAssertEqual(result.suggestedName, "Мой сервер")
    }

    func testRejectsPagesClashAndGarbage() {
        XCTAssertThrowsError(try ContentImporter.parse("<!DOCTYPE html><html><head></head></html>"))
        XCTAssertThrowsError(try ContentImporter.parse("proxies:\n  - name: a\n    type: ss\n"))
        XCTAssertThrowsError(try ContentImporter.parse("hello world"))
        XCTAssertThrowsError(try ContentImporter.parse(""))
        XCTAssertThrowsError(try ContentImporter.parse("{\"a\": 1}"))
    }

    func testProviderPlaceholderIsReportedAsMessage() {
        let links = "vless://00000000-0000-0000-0000-000000000000@0.0.0.0:1?type=tcp#Лимит устройств достигнут"
        XCTAssertThrowsError(try ContentImporter.parse(links)) { error in
            XCTAssertTrue((error as? ImportError)?.message.contains("Лимит устройств достигнут") ?? false)
        }
    }

    func testSingBoxDocumentInTheAppsOwnLayout() throws {
        let document = """
        {"outbounds": [
          {"type": "selector", "tag": "proxy", "outbounds": ["auto", "США-2", "Группа", "WG"], "default": "auto"},
          {"type": "urltest", "tag": "auto", "outbounds": ["США-2", "Группа"]},
          {"type": "vless", "tag": "США-2", "server": "us.example.net", "server_port": 443, "uuid": "u"},
          {"type": "urltest", "tag": "Группа", "outbounds": ["g1", "g2", "missing"]},
          {"type": "trojan", "tag": "g1", "server": "g1.example.net", "server_port": 443, "password": "p", "detour": "hop"},
          {"type": "trojan", "tag": "g2", "server": "g2.example.net", "server_port": 443, "password": "p"},
          {"type": "socks", "tag": "hop", "server": "hop.example.net", "server_port": 1080},
          {"type": "direct", "tag": "direct"}
        ],
        "endpoints": [{"type": "wireguard", "tag": "WG", "address": ["10.0.0.2/32"], "private_key": "k", "peers": [{"address": "wg.example.net", "port": 51820, "public_key": "p"}]}]}
        """
        let result = try ContentImporter.parse(document)
        XCTAssertEqual(result.format, .singBox)
        XCTAssertEqual(result.nodes.map(\.name), ["США-2", "Группа", "WG"])
        XCTAssertEqual(result.nodes[1].outbound["outbounds"], ["g1", "g2"])
        XCTAssertEqual(Set(result.nodes[1].members.compactMap { $0["tag"]?.stringValue }), ["g1", "g2", "hop"])
        let nodes = NodeAssembler.assemble(result.nodes)
        XCTAssertEqual(nodes[1].members.first { $0["type"] == "trojan" && $0["server"] == "g1.example.net" }?["detour"], "Группа · 3")
        XCTAssertTrue(nodes[2].isEndpoint)
    }

    func testXrayFinalmaskOnTCPTransports() throws {
        func server(_ mask: String) -> String {
            #"[{"remarks": "M", "outbounds": [{"tag": "proxy", "protocol": "vless", "settings": {"vnext": [{"address": "m.example.net", "port": 443, "users": [{"id": "11111111-2222-3333-4444-555555555555", "encryption": "none", "flow": "xtls-rprx-vision"}]}]}, "streamSettings": {"network": "raw", "security": "reality", "realitySettings": {"serverName": "www.apple.com", "publicKey": "SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc", "shortId": "ab", "fingerprint": "chrome"}, "finalmask": "# + mask + #"}}]}]"#
        }
        // Client-side masks: the server is kept, fragment becomes tls.fragment.
        let kept = try ContentImporter.parse(server(#"{"tcp": [{"type": "fragment", "settings": {"packets": "tlshello", "length": "10-20"}}, {"type": "noise"}], "udp": [{"type": "salamander"}], "quicParams": {"congestion": "bbr"}}"#)).nodes
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].outbound.at("tls", "fragment"), true)
        XCTAssertEqual(kept[0].outbound.at("tls", "reality", "enabled"), true)
        // A mask the server must undo: Xray-core runs that server, with its own outbounds.
        let backed = try ContentImporter.parse(server(#"{"tcp": [{"type": "header-custom"}]}"#)).nodes
        XCTAssertEqual(backed.count, 1)
        XCTAssertEqual(backed[0].outbound["type"], "xray")
        XCTAssertEqual(backed[0].outbound.at("xray", "outbounds")?[0]?.at("streamSettings", "finalmask", "tcp")?[0]?["type"], "header-custom")
        let node = NodeAssembler.assemble(backed)[0]
        XCTAssertEqual(node.facts.badges, ["VLESS", "Reality", "TCP", "Vision", "Xray"])
    }

    func testPlainSingBoxFileListsEveryLeaf() throws {
        let document = """
        {"outbounds": [
          {"type": "urltest", "tag": "best", "outbounds": ["a", "b"]},
          {"type": "shadowsocks", "tag": "a", "server": "a.example.net", "server_port": 8388, "method": "aes-256-gcm", "password": "p"},
          {"type": "shadowsocks", "tag": "b", "server": "b.example.net", "server_port": 8388, "method": "aes-256-gcm", "password": "p"},
          {"type": "block", "tag": "block"}
        ]}
        """
        XCTAssertEqual(try ContentImporter.parse(document).nodes.map(\.name), ["a", "b"])
    }
}
