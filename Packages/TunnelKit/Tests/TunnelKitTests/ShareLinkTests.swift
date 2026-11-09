@testable import TunnelKit
import XCTest

final class ShareLinkTests: XCTestCase {
    func testVLESSReality() throws {
        let link = "vless://11111111-2222-3333-4444-555555555555@example.com:443?type=tcp&security=reality&sni=www.microsoft.com&fp=chrome&pbk=PUBKEYabc&sid=6ba8&flow=xtls-rprx-vision#%F0%9F%87%A9%F0%9F%87%AA%20Germany"
        let server = try ShareLinkParser.parse(link)
        XCTAssertEqual(server.name, "🇩🇪 Germany")
        let outbound = server.outbound
        XCTAssertEqual(outbound["type"], "vless")
        XCTAssertEqual(outbound["server"], "example.com")
        XCTAssertEqual(outbound["server_port"], 443)
        XCTAssertEqual(outbound["flow"], "xtls-rprx-vision")
        XCTAssertNil(outbound["transport"])
        XCTAssertEqual(outbound["tls"]?["server_name"], "www.microsoft.com")
        XCTAssertEqual(outbound["tls"]?["reality"]?["public_key"], "PUBKEYabc")
        XCTAssertEqual(outbound["tls"]?["reality"]?["short_id"], "6ba8")
        XCTAssertEqual(outbound["tls"]?["utls"]?["fingerprint"], "chrome")
        XCTAssertEqual(Server(imported: server).protocolTags, ["VLESS", "Reality", "Vision"])
        XCTAssertEqual(Server(imported: server).country?.code, "DE")
    }

    func testVLESSWebSocketEarlyData() throws {
        let link = "vless://uuid-1@1.2.3.4:8443?type=ws&security=tls&host=cdn.example.org&path=%2Fws%3Fed%3D2048&alpn=h2,http/1.1#WS"
        let outbound = try ShareLinkParser.parse(link).outbound
        XCTAssertEqual(outbound["transport"]?["type"], "ws")
        XCTAssertEqual(outbound["transport"]?["path"], "/ws")
        XCTAssertEqual(outbound["transport"]?["max_early_data"], 2048)
        XCTAssertEqual(outbound["transport"]?["early_data_header_name"], "Sec-WebSocket-Protocol")
        XCTAssertEqual(outbound["transport"]?["headers"]?["Host"], "cdn.example.org")
        XCTAssertEqual(outbound["tls"]?["alpn"], ["h2", "http/1.1"])
        // IP address servers get no implicit SNI.
        XCTAssertNil(outbound["tls"]?["server_name"])
    }

    func testVLESSXHTTPExtra() throws {
        let extra = TextCoding.percentEncoded(#"{"xPaddingBytes":"100-1000","noGRPCHeader":true,"xmux":{"maxConcurrency":"16-32"}}"#)
        let link = "vless://id@host.example:443?type=xhttp&security=tls&path=%2Fx&mode=packet-up&extra=\(extra)#X"
        let transport = try XCTUnwrap(try ShareLinkParser.parse(link).outbound["transport"])
        XCTAssertEqual(transport["type"], "xhttp")
        XCTAssertEqual(transport["mode"], "packet-up")
        XCTAssertEqual(transport["x_padding_bytes"], "100-1000")
        XCTAssertEqual(transport["no_grpc_header"], true)
        XCTAssertEqual(transport["xmux"]?["max_concurrency"], "16-32")
    }

    func testVMessBase64() throws {
        let payload = #"{"v":"2","ps":"VMess 1","add":"vm.example.com","port":"443","id":"abcd","aid":"0","scy":"auto","net":"grpc","type":"none","host":"","path":"svc","tls":"tls","sni":"vm.example.com"}"#
        let link = "vmess://" + TextCoding.base64Encode(payload)
        let server = try ShareLinkParser.parse(link)
        XCTAssertEqual(server.name, "VMess 1")
        XCTAssertEqual(server.outbound["type"], "vmess")
        XCTAssertEqual(server.outbound["server_port"], 443)
        XCTAssertEqual(server.outbound["transport"]?["type"], "grpc")
        XCTAssertEqual(server.outbound["transport"]?["service_name"], "svc")
        XCTAssertEqual(server.outbound["tls"]?["server_name"], "vm.example.com")
    }

    func testTrojanDefaultsToTLS() throws {
        let outbound = try ShareLinkParser.parse("trojan://p%40ss@tr.example.com:443?type=grpc&serviceName=gun#T").outbound
        XCTAssertEqual(outbound["password"], "p@ss")
        XCTAssertEqual(outbound["tls"]?["enabled"], true)
        XCTAssertEqual(outbound["tls"]?["server_name"], "tr.example.com")
        XCTAssertEqual(outbound["transport"]?["service_name"], "gun")
    }

    func testShadowsocksForms() throws {
        let sip002 = "ss://" + TextCoding.base64Encode("aes-256-gcm:secret", urlSafe: true, padded: false) + "@ss.example.com:8388#SS"
        let first = try ShareLinkParser.parse(sip002).outbound
        XCTAssertEqual(first["method"], "aes-256-gcm")
        XCTAssertEqual(first["password"], "secret")

        let plain = "ss://2022-blake3-aes-128-gcm:YWJjZA%3D%3D@[2001:db8::1]:443#v6"
        let second = try ShareLinkParser.parse(plain).outbound
        XCTAssertEqual(second["server"], "2001:db8::1")
        XCTAssertEqual(second["password"], "YWJjZA==")

        let legacy = "ss://" + TextCoding.base64Encode("chacha20-ietf-poly1305:pw@1.1.1.1:443") + "#Legacy"
        let third = try ShareLinkParser.parse(legacy)
        XCTAssertEqual(third.name, "Legacy")
        XCTAssertEqual(third.outbound["server_port"], 443)

        XCTAssertThrowsError(try ShareLinkParser.parse("ss://" + TextCoding.base64Encode("bf-cfb:pw") + "@h:1"))
    }

    func testHysteria2PortHoppingAndObfs() throws {
        let link = "hy2://letmein@hy.example.com:443,20000-30000/?sni=real.example.com&obfs=salamander&obfs-password=ob&insecure=1#HY"
        let outbound = try ShareLinkParser.parse(link).outbound
        XCTAssertEqual(outbound["type"], "hysteria2")
        XCTAssertEqual(outbound["password"], "letmein")
        XCTAssertEqual(outbound["server_port"], 443)
        XCTAssertEqual(outbound["server_ports"], ["443:443", "20000:30000"])
        XCTAssertEqual(outbound["hop_interval"], "30s")
        XCTAssertEqual(outbound["obfs"]?["type"], "salamander")
        XCTAssertEqual(outbound["obfs"]?["password"], "ob")
        XCTAssertEqual(outbound["tls"]?["insecure"], true)
        XCTAssertEqual(outbound["tls"]?["server_name"], "real.example.com")
        XCTAssertTrue(Server(imported: try ShareLinkParser.parse(link)).descriptor.isUDPBased)
    }

    func testTUIC() throws {
        let outbound = try ShareLinkParser.parse("tuic://uuid:pass@tuic.example.com:443?congestion_control=bbr&udp_relay_mode=native&alpn=h3#TUIC").outbound
        XCTAssertEqual(outbound["uuid"], "uuid")
        XCTAssertEqual(outbound["password"], "pass")
        XCTAssertEqual(outbound["congestion_control"], "bbr")
        XCTAssertEqual(outbound["tls"]?["alpn"], ["h3"])
    }

    func testWireGuardLinkWithAmnezia() throws {
        let link = "wireguard://cHJpdmF0ZQ%3D%3D@wg.example.com:51820?publickey=cHVibGlj&address=10.7.0.2,fd00::2&mtu=1280&reserved=1,2,3&jc=4&jmin=40&jmax=70&h1=1234#WG"
        let server = Server(imported: try ShareLinkParser.parse(link))
        let outbound = server.outbound
        XCTAssertTrue(server.isEndpoint)
        XCTAssertEqual(outbound["private_key"], "cHJpdmF0ZQ==")
        XCTAssertEqual(outbound["address"], ["10.7.0.2/32", "fd00::2/128"])
        XCTAssertEqual(outbound["peers"]?[0]?["public_key"], "cHVibGlj")
        XCTAssertEqual(outbound["peers"]?[0]?["reserved"], [1, 2, 3])
        XCTAssertEqual(outbound["jc"], 4)
        XCTAssertEqual(outbound["h1"], 1234)
        XCTAssertEqual(server.protocolTags.first, "AmneziaWG")
        XCTAssertEqual(server.host, "wg.example.com")
        XCTAssertEqual(server.port, 51820)
    }

    func testNaiveAndSOCKS() throws {
        let naive = try ShareLinkParser.parse("naive+https://user:pw@naive.example.com:443#N").outbound
        XCTAssertEqual(naive["type"], "naive")
        XCTAssertEqual(naive["username"], "user")
        XCTAssertEqual(naive["tls"]?["server_name"], "naive.example.com")
        let socks = try ShareLinkParser.parse("socks://" + TextCoding.base64Encode("a:b") + "@10.0.0.1:1080#S").outbound
        XCTAssertEqual(socks["username"], "a")
        XCTAssertEqual(socks["password"], "b")
    }

    func testUnsupportedProtocolsAreNamed() {
        XCTAssertThrowsError(try ShareLinkParser.parse("ssr://abc")) { error in
            XCTAssertEqual(error as? ImportError, .unsupportedProtocol("ShadowsocksR"))
        }
        XCTAssertThrowsError(try ShareLinkParser.parse("vless://id@h:443?type=kcp#k")) { error in
            XCTAssertEqual(error as? ImportError, .unsupportedTransport("mKCP"))
        }
    }
}
