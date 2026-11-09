@testable import TunnelKit
import XCTest

final class FormatTests: XCTestCase {
    func testJSONRoundTrip() throws {
        let text = #"{"a":1,"b":1.5,"c":true,"d":null,"e":["x","é😀"],"f":{"g":-3}}"#
        let json = try JSON.parse(text)
        XCTAssertEqual(json["a"], .int(1))
        XCTAssertEqual(json["b"], .double(1.5))
        XCTAssertEqual(json["c"], .bool(true))
        XCTAssertEqual(json["e"]?[1], .string("é😀"))
        XCTAssertEqual(try JSON.parse(json.serialized()), json)
        XCTAssertEqual(JSON.object(["b": 2, "a": 1]).serialized(), #"{"a":1,"b":2}"#)
        XCTAssertThrowsError(try JSON.parse("{\"a\":}"))
    }

    func testBase64ListWithBodyMetadata() throws {
        let body = """
        #profile-title: base64:\(TextCoding.base64Encode("Моя подписка"))
        #subscription-userinfo: upload=10; download=20; total=1000; expire=1893456000
        trojan://pw@a.example.com:443#A
        ssr://unsupported
        vless://id@b.example.com:443?security=tls#B
        """
        let content = try ContentDecoder.decode(TextCoding.base64Encode(body))
        XCTAssertEqual(content.format, .base64Links)
        XCTAssertEqual(content.servers.map(\.name), ["A", "B"])
        XCTAssertEqual(content.skipped.count, 1)
        let metadata = SubscriptionMetadata.parse(headers: [:], bodyMetadata: content.bodyMetadata)
        XCTAssertEqual(metadata.title, "Моя подписка")
        XCTAssertEqual(metadata.info.totalBytes, 1000)
        XCTAssertEqual(metadata.info.usedBytes, 30)
        XCTAssertEqual(metadata.info.expiresAt, Date(timeIntervalSince1970: 1_893_456_000))
    }

    func testHeaderMetadata() {
        let metadata = SubscriptionMetadata.parse(headers: [
            "Profile-Title": "base64:" + TextCoding.base64Encode("Сервис"),
            "Subscription-Userinfo": "upload=0; download=0; total=0; expire=0",
            "profile-update-interval": "6",
            "x-hwid-device-limit": "3",
            "Support-Url": "https://t.me/support",
        ])
        XCTAssertEqual(metadata.title, "Сервис")
        XCTAssertNil(metadata.info.totalBytes)
        XCTAssertNil(metadata.info.expiresAt)
        XCTAssertEqual(metadata.info.updateIntervalHours, 6)
        XCTAssertEqual(metadata.info.deviceLimit, 3)
        XCTAssertEqual(metadata.info.supportURL, "https://t.me/support")
        XCTAssertEqual(SubscriptionMetadata.filename(fromContentDisposition: "attachment; filename=\"Work.yaml\""), "Work")
    }

    func testClashYAML() throws {
        let yaml = """
        mixed-port: 7890
        proxies:
          - name: "🇳🇱 NL vless"
            type: vless
            server: nl.example.com
            port: 443
            uuid: 0000-1111
            network: ws
            tls: true
            servername: nl.example.com
            client-fingerprint: chrome
            ws-opts:
              path: /path # comment
              headers:
                Host: cdn.example.com
          - {name: SS 1, type: ss, server: 1.2.3.4, port: 8388, cipher: aes-128-gcm, password: "p#ss"}
          - name: hy
            type: hysteria2
            server: hy.example.com
            port: 443
            password: secret
            ports: 30000-40000
            obfs: salamander
            obfs-password: o
          - name: reality
            type: vless
            server: r.example.com
            port: 443
            uuid: id
            flow: xtls-rprx-vision
            tls: true
            servername: www.apple.com
            reality-opts:
              public-key: KEY
              short-id: ab
          - name: Old
            type: ssr
            server: x
            port: 1
        proxy-groups: []
        """
        let content = try ContentDecoder.decode(yaml)
        XCTAssertEqual(content.format, .clash)
        XCTAssertEqual(content.servers.count, 4)
        XCTAssertEqual(content.skipped.count, 1)
        let vless = content.servers[0].outbound
        XCTAssertEqual(content.servers[0].name, "🇳🇱 NL vless")
        XCTAssertEqual(vless["transport"]?["path"], "/path")
        XCTAssertEqual(vless["transport"]?["headers"]?["Host"], "cdn.example.com")
        XCTAssertEqual(vless["tls"]?["utls"]?["fingerprint"], "chrome")
        XCTAssertEqual(content.servers[1].outbound["password"], "p#ss")
        XCTAssertEqual(content.servers[2].outbound["server_ports"], ["30000:40000"])
        XCTAssertEqual(content.servers[3].outbound["tls"]?["reality"]?["public_key"], "KEY")
    }

    func testXrayJSONRemnawave() throws {
        let json = """
        [
          {"remarks": "🇫🇮 Finland", "outbounds": [
            {"tag": "proxy", "protocol": "vless", "settings": {"vnext": [{"address": "fi.example.com", "port": 443,
              "users": [{"id": "uuid-fi", "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
             "streamSettings": {"network": "tcp", "security": "reality",
              "realitySettings": {"serverName": "www.google.com", "publicKey": "PK", "shortId": "01", "fingerprint": "firefox"}}},
            {"tag": "direct", "protocol": "freedom"}]},
          {"remarks": "XHTTP", "outbounds": [
            {"tag": "proxy", "protocol": "vless", "settings": {"address": "x.example.com", "port": 443, "id": "uuid-x"},
             "streamSettings": {"network": "xhttp", "security": "tls", "tlsSettings": {"serverName": "x.example.com", "alpn": ["h2"]},
              "xhttpSettings": {"path": "/xh", "mode": "stream-one", "extra": {"xPaddingBytes": {"from": 50, "to": 100}}}}}]},
          {"remarks": "HY", "outbounds": [
            {"tag": "proxy", "protocol": "hysteria", "settings": {"address": "hy.example.com", "port": 8443, "version": 2},
             "streamSettings": {"network": "hysteria", "security": "tls", "tlsSettings": {"serverName": "hy.example.com"},
              "hysteriaSettings": {"auth": "pw"},
              "finalmask": {"udp": [{"type": "salamander", "settings": {"password": "mask"}}],
                "quicParams": {"udpHop": {"ports": "20000-20010", "interval": "10-20"}, "brutalUp": "50 mbps", "brutalDown": 200}}}}]}
        ]
        """
        let content = try ContentDecoder.decode(json)
        XCTAssertEqual(content.format, .xray)
        XCTAssertEqual(content.servers.count, 3, "\(content.skipped)")
        let reality = content.servers[0].outbound
        XCTAssertEqual(content.servers[0].name, "🇫🇮 Finland")
        XCTAssertEqual(reality["tls"]?["reality"]?["public_key"], "PK")
        XCTAssertEqual(reality["tls"]?["utls"]?["fingerprint"], "firefox")
        XCTAssertNil(reality["encryption"])
        let xhttp = content.servers[1].outbound
        XCTAssertEqual(xhttp["transport"]?["mode"], "stream-one")
        XCTAssertEqual(xhttp["transport"]?["x_padding_bytes"], "50-100")
        let hy = content.servers[2].outbound
        XCTAssertEqual(hy["type"], "hysteria2")
        XCTAssertEqual(hy["password"], "pw")
        XCTAssertEqual(hy["obfs"]?["password"], "mask")
        XCTAssertEqual(hy["server_ports"], ["20000:20010"])
        XCTAssertEqual(hy["hop_interval"], "10s")
        XCTAssertEqual(hy["hop_interval_max"], "20s")
        XCTAssertEqual(hy["up_mbps"], 50)
        XCTAssertEqual(hy["down_mbps"], 200)
    }

    func testSingBoxJSON() throws {
        let json = """
        {"outbounds": [
          {"type": "selector", "tag": "select", "outbounds": ["a"]},
          {"type": "trojan", "tag": "a", "server": "t.example.com", "server_port": 443, "password": "x", "detour": "other", "domain_strategy": "ipv4_only"},
          {"type": "wireguard", "tag": "old-wg", "server": "w.example.com", "server_port": 51820, "local_address": ["10.0.0.2/32"], "private_key": "k", "peer_public_key": "p"},
          {"type": "tailscale", "tag": "ts"}
        ]}
        """
        let content = try ContentDecoder.decode(json)
        XCTAssertEqual(content.format, .singBox)
        XCTAssertEqual(content.servers.map(\.name), ["a", "old-wg"])
        XCTAssertNil(content.servers[0].outbound["detour"])
        XCTAssertNil(content.servers[0].outbound["domain_strategy"])
        XCTAssertNil(content.servers[0].outbound["tag"])
        XCTAssertEqual(content.servers[1].outbound["peers"]?[0]?["address"], "w.example.com")
        XCTAssertEqual(content.skipped.count, 1)
    }

    func testWireGuardConf() throws {
        let conf = """
        [Interface]
        PrivateKey = privkey=
        Address = 10.8.0.2/32, fd42::2/128
        DNS = 1.1.1.1
        Jc = 5
        Jmin = 10
        Jmax = 50
        S1 = 20
        H1 = 100-200
        I1 = <b 0xabcdef>

        [Peer]
        PublicKey = pubkey=
        Endpoint = vpn.example.com:51820
        AllowedIPs = 0.0.0.0/0, ::/0
        PersistentKeepalive = 25
        """
        let content = try ContentDecoder.decode(conf)
        XCTAssertEqual(content.format, .wireGuard)
        let endpoint = content.servers[0].outbound
        XCTAssertEqual(endpoint["peers"]?[0]?["address"], "vpn.example.com")
        XCTAssertEqual(endpoint["peers"]?[0]?["persistent_keepalive_interval"], 25)
        XCTAssertEqual(endpoint["jc"], 5)
        XCTAssertEqual(endpoint["h1"], "100-200")
        XCTAssertEqual(endpoint["i1"], "<b 0xabcdef>")
    }

    func testUnrecognized() {
        XCTAssertThrowsError(try ContentDecoder.decode("hello world")) { error in
            XCTAssertEqual(error as? ImportError, .unrecognizedFormat)
        }
        XCTAssertThrowsError(try ContentDecoder.decode("   ")) { error in
            XCTAssertEqual(error as? ImportError, .empty)
        }
    }

    func testRedactor() {
        let text = "fetch https://panel.example.com/sub/abcdef123456 uuid 11111111-2222-3333-4444-555555555555 link vless://secret@host:443 password=hunter2"
        let redacted = Redactor.redact(text)
        XCTAssertFalse(redacted.contains("abcdef123456"))
        XCTAssertFalse(redacted.contains("11111111-2222"))
        XCTAssertFalse(redacted.contains("secret@host"))
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertTrue(redacted.contains("panel.example.com"))
        XCTAssertEqual(Redactor.redactPath("/sub/token"), "/sub/•••")
    }

    func testCountryDetection() {
        XCTAssertEqual(Country.detect(in: "🇯🇵 Tokyo 01")?.code, "JP")
        XCTAssertEqual(Country.detect(in: "Нидерланды #2")?.code, "NL")
        XCTAssertEqual(Country.detect(in: "[UK] London")?.code, "GB")
        XCTAssertNil(Country.detect(in: "Fast server"))
        XCTAssertEqual(Country(code: "us").flag, "🇺🇸")
        XCTAssertEqual(Country.stripFlags(from: "🇩🇪 | Frankfurt"), "Frankfurt")
    }
}
