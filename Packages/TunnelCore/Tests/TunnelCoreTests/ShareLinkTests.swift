import XCTest
@testable import TunnelCore

final class ShareLinkTests: XCTestCase {
    private let realityKey = "SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc"

    func testVLESSRealityVision() throws {
        let link = "vless://11111111-2222-3333-4444-555555555555@example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=\(realityKey)&sid=6ba85179e30d4fc2&type=tcp&headerType=none#%F0%9F%87%BA%F0%9F%87%B8%20%D0%A1%D0%A8%D0%90-2"
        let node = try ShareLink.parse(link)
        XCTAssertEqual(node.name, "🇺🇸 США-2")
        XCTAssertEqual(node.outbound["type"], "vless")
        XCTAssertEqual(node.outbound["server"], "example.com")
        XCTAssertEqual(node.outbound["server_port"], 443)
        XCTAssertEqual(node.outbound["flow"], "xtls-rprx-vision")
        XCTAssertEqual(node.outbound["packet_encoding"], "xudp")
        XCTAssertNil(node.outbound["transport"])
        XCTAssertNil(node.outbound["encryption"])
        XCTAssertEqual(node.outbound.at("tls", "server_name"), "www.microsoft.com")
        XCTAssertEqual(node.outbound.at("tls", "reality", "public_key"), .string(realityKey))
        XCTAssertEqual(node.outbound.at("tls", "reality", "short_id"), "6ba85179e30d4fc2")
        XCTAssertEqual(node.outbound.at("tls", "utls", "fingerprint"), "chrome")
        XCTAssertEqual(node.link, link)
        XCTAssertEqual(ProtocolFacts(object: node.outbound).summary, "VLESS · REALITY · TCP/RAW · Vision")
        XCTAssertEqual(ProtocolFacts(object: node.outbound).badges, ["VLESS", "Reality", "TCP", "Vision"])
    }

    func testVLESSRealityNeedsItsKey() {
        XCTAssertThrowsError(try ShareLink.parse("vless://u@h.example:443?security=reality&sni=a.b&type=tcp#x"))
        XCTAssertThrowsError(try ShareLink.parse("vless://u@h.example:443?security=reality&pbk=short&type=tcp#x"))
    }

    func testVLESSWebSocketTLSWithEarlyData() throws {
        let node = try ShareLink.parse("vless://uuid@1.2.3.4:8443?security=tls&sni=cdn.example.org&type=ws&host=cdn.example.org&path=%2Fws%3Fed%3D2048&alpn=h2%2Chttp%2F1.1&allowInsecure=1#Germany")
        XCTAssertEqual(node.outbound.at("transport", "type"), "ws")
        XCTAssertEqual(node.outbound.at("transport", "path"), "/ws")
        XCTAssertEqual(node.outbound.at("transport", "max_early_data"), 2048)
        XCTAssertEqual(node.outbound.at("transport", "early_data_header_name"), "Sec-WebSocket-Protocol")
        XCTAssertEqual(node.outbound.at("transport", "headers", "Host"), "cdn.example.org")
        XCTAssertEqual(node.outbound.at("tls", "insecure"), true)
        XCTAssertEqual(node.outbound.at("tls", "alpn"), ["h2", "http/1.1"])
        XCTAssertEqual(ProtocolFacts(object: node.outbound).badges, ["VLESS", "TLS", "WebSocket"])
    }

    func testVLESSGRPCAndXHTTP() throws {
        let grpc = try ShareLink.parse("vless://uuid@h.example:443?security=reality&pbk=\(realityKey)&sid=&sni=h.example&type=grpc&serviceName=grpc-svc#Finland%201")
        XCTAssertEqual(grpc.outbound.at("transport", "type"), "grpc")
        XCTAssertEqual(grpc.outbound.at("transport", "service_name"), "grpc-svc")
        XCTAssertEqual(ProtocolFacts(object: grpc.outbound).badges, ["VLESS", "Reality", "gRPC"])

        let extra = TextCoding.percentEncode(#"{"xPaddingBytes":"100-1000","noGRPCHeader":true,"scMaxEachPostBytes":{"from":500000,"to":1000000},"xmux":{"maxConcurrency":"16-32","hKeepAlivePeriod":30},"headers":{"X-Test":"1"}}"#)
        let xhttp = try ShareLink.parse("vless://uuid@h.example:443?security=tls&sni=h.example&type=xhttp&host=h.example&path=%2Fxh&mode=packet-up&extra=\(extra)#X")
        XCTAssertEqual(xhttp.outbound.at("transport", "type"), "xhttp")
        XCTAssertEqual(xhttp.outbound.at("transport", "mode"), "packet-up")
        XCTAssertEqual(xhttp.outbound.at("transport", "host"), "h.example")
        XCTAssertEqual(xhttp.outbound.at("transport", "x_padding_bytes"), "100-1000")
        XCTAssertEqual(xhttp.outbound.at("transport", "no_grpc_header"), true)
        XCTAssertEqual(xhttp.outbound.at("transport", "sc_max_each_post_bytes"), "500000-1000000")
        XCTAssertEqual(xhttp.outbound.at("transport", "xmux", "max_concurrency"), "16-32")
        XCTAssertEqual(xhttp.outbound.at("transport", "xmux", "h_keep_alive_period"), 30)
        XCTAssertEqual(xhttp.outbound.at("transport", "headers", "X-Test"), "1")
    }

    func testKCPIsRejectedWithAReason() {
        XCTAssertThrowsError(try ShareLink.parse("vless://uuid@h.example:443?type=kcp#x")) { error in
            XCTAssertTrue((error as? ImportError)?.message.contains("mKCP") ?? false)
        }
    }

    func testVMessBase64JSON() throws {
        let json = #"{"v":"2","ps":"Тест VMess","add":"vm.example.com","port":"443","id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","aid":"0","scy":"auto","net":"ws","type":"none","host":"vm.example.com","path":"/vm","tls":"tls","sni":"vm.example.com"}"#
        let node = try ShareLink.parse("vmess://" + Data(json.utf8).base64EncodedString())
        XCTAssertEqual(node.name, "Тест VMess")
        XCTAssertEqual(node.outbound["type"], "vmess")
        XCTAssertEqual(node.outbound["server_port"], 443)
        XCTAssertEqual(node.outbound["security"], "auto")
        XCTAssertNil(node.outbound["alter_id"])
        XCTAssertEqual(node.outbound.at("transport", "path"), "/vm")
        XCTAssertEqual(node.outbound.at("tls", "enabled"), true)
    }

    func testTrojanDefaultsToTLS() throws {
        let node = try ShareLink.parse("trojan://p%40ss@tr.example.com:443?type=grpc&serviceName=svc#Trojan")
        XCTAssertEqual(node.outbound["password"], "p@ss")
        XCTAssertEqual(node.outbound.at("tls", "server_name"), "tr.example.com")
        XCTAssertEqual(node.outbound.at("transport", "service_name"), "svc")
    }

    func testShadowsocksForms() throws {
        let userInfo = Data("aes-256-gcm:secret/pass".utf8).base64EncodedString()
        let modern = try ShareLink.parse("ss://\(userInfo)@ss.example.com:8388#SS%201")
        XCTAssertEqual(modern.outbound["method"], "aes-256-gcm")
        XCTAssertEqual(modern.outbound["password"], "secret/pass")
        XCTAssertEqual(modern.outbound["server_port"], 8388)
        XCTAssertEqual(modern.name, "SS 1")

        let whole = Data("chacha20-ietf-poly1305:pw@10.0.0.1:443".utf8).base64EncodedString()
        let legacy = try ShareLink.parse("ss://\(whole)#Old")
        XCTAssertEqual(legacy.outbound["method"], "chacha20-ietf-poly1305")
        XCTAssertEqual(legacy.outbound["server"], "10.0.0.1")

        let plain = try ShareLink.parse("ss://2022-blake3-aes-128-gcm:a2V5a2V5a2V5a2V5a2V5QQ%3D%3D@[2001:db8::1]:8443?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dx.com#v6")
        XCTAssertEqual(plain.outbound["server"], "2001:db8::1")
        XCTAssertEqual(plain.outbound["password"], "a2V5a2V5a2V5a2V5a2V5QQ==")
        XCTAssertEqual(plain.outbound["plugin"], "obfs-local")
        XCTAssertEqual(plain.outbound["plugin_opts"], "obfs=http;obfs-host=x.com")
    }

    func testHysteria2WithObfsAndPortHopping() throws {
        let node = try ShareLink.parse("hysteria2://pass@hy.example.com:443,20000-30000?sni=hy.example.com&insecure=1&obfs=salamander&obfs-password=obfs#Hy2")
        XCTAssertEqual(node.outbound["type"], "hysteria2")
        XCTAssertEqual(node.outbound["server_port"], 443)
        XCTAssertEqual(node.outbound["server_ports"], ["443:443", "20000:30000"])
        XCTAssertEqual(node.outbound.at("obfs", "type"), "salamander")
        XCTAssertEqual(node.outbound.at("tls", "insecure"), true)
        XCTAssertEqual(ProtocolFacts(object: node.outbound).summary, "HYSTERIA2 · TLS · QUIC")
        let short = try ShareLink.parse("hy2://pass@1.1.1.1:8443#x")
        XCTAssertNil(short.outbound.at("tls", "server_name"))
        XCTAssertNil(short.outbound["server_ports"])
    }

    /// 3.0.5: self-signed servers come with their certificate's SHA-256 instead
    /// of `insecure`; the pin reaches the core, broken values are left out.
    func testCertificatePins() throws {
        let hash = String(repeating: "ab", count: 32)
        // 3.1.0: lists written with other separators.
        let other = String(repeating: "cd", count: 32)
        XCTAssertEqual(CertificatePins.hex(["\(hash)~\(other)"]), [hash, other])
        XCTAssertEqual(CertificatePins.hex(["\(hash)|\(other.uppercased())"]), [hash, other])
        let colons = stride(from: 0, to: 64, by: 2).map { i -> String in
            let start = hash.index(hash.startIndex, offsetBy: i)
            return String(hash[start ..< hash.index(start, offsetBy: 2)]).uppercased()
        }.joined(separator: ":")

        let hy2 = try ShareLink.parse("hysteria2://pass@1.2.3.4:443?sni=a.internal&pinSHA256=\(colons)#H")
        XCTAssertEqual(hy2.outbound.at("tls", "certificate_sha256"), [.string(hash)])
        XCTAssertNil(hy2.outbound.at("tls", "insecure"))

        let vless = try ShareLink.parse("vless://uuid@1.2.3.4:443?security=tls&sni=a.internal&type=tcp&flow=xtls-rprx-vision&fp=chrome&pcs=\(hash)%2C\(String(repeating: "cd", count: 32))#V")
        XCTAssertEqual(vless.outbound.at("tls", "certificate_sha256"), [.string(hash), .string(String(repeating: "cd", count: 32))])
        XCTAssertEqual(vless.outbound.at("tls", "utls", "fingerprint"), "chrome")

        let trojan = try ShareLink.parse("trojan://pw@1.2.3.4:443?sni=a.internal&pcs=\(hash)#T")
        XCTAssertEqual(trojan.outbound.at("tls", "certificate_sha256"), [.string(hash)])

        let tuic = try ShareLink.parse("tuic://uuid-1:secret@1.2.3.4:443?sni=a.internal&pinSHA256=\(hash)#U")
        XCTAssertEqual(tuic.outbound.at("tls", "certificate_sha256"), [.string(hash)])

        // Not a whole hash: no pin (the core would refuse to start on it).
        let broken = try ShareLink.parse("hysteria2://pass@1.2.3.4:443?sni=a.internal&pinSHA256=abcd&insecure=1#H")
        XCTAssertNil(broken.outbound.at("tls", "certificate_sha256"))
        XCTAssertEqual(broken.outbound.at("tls", "insecure"), true)

        // REALITY never takes a pin.
        let reality = try ShareLink.parse("vless://uuid@1.2.3.4:443?security=reality&sni=a.b&pbk=\(realityKey)&sid=ab&type=tcp&pcs=\(hash)#R")
        XCTAssertNil(reality.outbound.at("tls", "certificate_sha256"))
    }

    func testTUIC() throws {
        let node = try ShareLink.parse("tuic://uuid-1:secret@tuic.example.com:443?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=tuic.example.com#TUIC")
        XCTAssertEqual(node.outbound["uuid"], "uuid-1")
        XCTAssertEqual(node.outbound["password"], "secret")
        XCTAssertEqual(node.outbound["congestion_control"], "bbr")
        XCTAssertEqual(node.outbound.at("tls", "alpn"), ["h3"])
    }

    func testWireGuardAndAmneziaWG() throws {
        let node = try ShareLink.parse("wireguard://cHJpdmF0ZWtleXByaXZhdGVrZXlwcml2YXRla2V5MTI%3D@wg.example.com:51820?publickey=cHVibGlja2V5cHVibGlja2V5cHVibGlja2V5MTIzNDU%3D&address=10.7.0.2,fd00::2&mtu=1280&reserved=1,2,3&keepalive=25&jc=4&jmin=40&jmax=70&h1=123456#WG")
        XCTAssertEqual(node.outbound["type"], "wireguard")
        XCTAssertEqual(node.outbound["address"], ["10.7.0.2/32", "fd00::2/128"])
        XCTAssertEqual(node.outbound["mtu"], 1280)
        XCTAssertEqual(node.outbound["jc"], 4)
        XCTAssertEqual(node.outbound["h1"], 123456)
        XCTAssertEqual(node.outbound.at("peers")?[0]?["port"], 51820)
        XCTAssertEqual(node.outbound.at("peers")?[0]?["reserved"], [1, 2, 3])
        let wrapped = ServerNode(id: "WG", name: "WG", outbound: node.outbound)
        XCTAssertTrue(wrapped.isEndpoint)
        XCTAssertTrue(wrapped.isUDPBased)
        XCTAssertEqual(wrapped.address?.host, "wg.example.com")
        XCTAssertEqual(wrapped.address?.port, 51820)
    }

    func testUnsupportedSchemesExplainThemselves() {
        XCTAssertThrowsError(try ShareLink.parse("ssr://abcdef")) { error in
            XCTAssertEqual((error as? ImportError)?.message, "ShadowsocksR не входит в сборку ядра.")
        }
        XCTAssertFalse(ShareLink.isLink("https://example.com/sub"))
        XCTAssertTrue(ShareLink.isLink("hy2://x@y:1"))
    }

    func testLinkPartsHandlesIPv6AndMissingPieces() {
        let parts = LinkParts("vless://id@[2001:db8::2]:8443/?type=tcp#n")
        XCTAssertEqual(parts?.host, "2001:db8::2")
        XCTAssertEqual(parts?.port, 8443)
        XCTAssertNil(LinkParts("not a link"))
        XCTAssertThrowsError(try ShareLink.parse("vless://id@host?type=tcp"))
    }
}
