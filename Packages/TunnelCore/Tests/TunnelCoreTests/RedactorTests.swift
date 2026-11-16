@testable import TunnelCore
import XCTest

/// 3.3 (PT-16): every line of the audit's table, and what text leaving the app keeps.
final class RedactorTests: XCTestCase {
    private func assertGone(_ secret: String, in text: String, file: StaticString = #filePath, line: UInt = #line) {
        let redacted = Redactor.redact(text)
        XCTAssertFalse(redacted.contains(secret), "«\(secret)» left in «\(redacted)»", file: file, line: line)
    }

    func testEveryLinkSchemeIsCut() {
        for scheme in ["socks4", "http-proxy", "https-proxy", "socks5", "vless", "ss", "hysteria2", "hy2", "tuic", "anytls", "naive+https", "wireguard"] {
            assertGone("SECRET", in: "\(scheme)://user:SECRET@1.2.3.4:1080#name")
        }
        // Every scheme ShareLink reads is in the list, so a new one cannot be forgotten.
        XCTAssertTrue(ShareLink.schemes.isSubset(of: Set(Redactor.linkSchemes)))
        XCTAssertEqual(Redactor.redact("socks4://u:p@h:1"), "socks4://***")
    }

    func testTheAuditTableRows() {
        assertGone("SECRETKEYBASE64=", in: #""peer_public_key":"SECRETKEYBASE64=""#)
        assertGone("SECRETKEY", in: #""publicKey":"SECRETKEY", "shortId":"abcd""#)
        assertGone("abcd", in: #""publicKey":"SECRETKEY", "shortId":"abcd""#)
        assertGone("SECRET", in: #"{\"password\":\"SECRET\"}"#)
        assertGone("SECRETUSER", in: #""username":"SECRETUSER""#)
        assertGone("my-custom-xray-id", in: #""id":"my-custom-xray-id""#)
        assertGone("SECRETPBK", in: "sni=reality.example.org&pbk=SECRETPBK&sid=ab12")
        assertGone("ab12", in: "sni=reality.example.org&pbk=SECRETPBK&sid=ab12")
        assertGone("SECRET", in: #""obfs-password":"SECRET""#)
        assertGone("SECRET", in: "Authorization: Bearer SECRET")
        assertGone("SECRET123", in: "https://panel.example.net?token=SECRET123")
        assertGone("SECRETPATH", in: "https://panel.example.net/?SECRETPATH")
        assertGone("SECRETPATH", in: "fetch https://panel.example.net/sub/SECRETPATH failed")
        XCTAssertEqual(Redactor.redact("Authorization: Bearer SECRET"), "Authorization: *** ***")
        XCTAssertEqual(Redactor.redact(#"{\"password\":\"SECRET\"}"#), #"{\"password\":\"***\"}"#)
        // Ordinary words stay.
        XCTAssertEqual(Redactor.redact("valid=1 passed: 5 oauth"), "valid=1 passed: 5 oauth")
    }

    func testSharedTextHidesDestinationsAndAddressesButTheTunnels() {
        let text = """
        2026/11/16 08:02:01 INFO [1234 15.1s] outbound/vless[proxy]: outbound connection to 203.0.113.7:443
        INFO inbound/tun[tun-in]: inbound connection to private-site.example:443
        INFO inbound/tun[tun-in]: inbound packet connection from 172.19.0.1:50000 to [2001:db8::5]:53
        [Info] [77] proxy/socks: tunneling request to tcp:shop.example.org:443
        [Info] [77] app/dispatcher: taking detour [n20000-proxy] for [tcp:198.51.100.4:443]
        DEBUG dns: exchange cdn.server.example via fdfe:dcba:9876::2 answered 192.0.2.10
        """
        let shared = Redactor.forSharing(text, hosts: ["cdn.server.example"])
        for gone in ["203.0.113.7", "private-site.example", "2001:db8::5", "shop.example.org", "198.51.100.4", "cdn.server.example", "192.0.2.10"] {
            XCTAssertFalse(shared.contains(gone), "«\(gone)» left in:\n\(shared)")
        }
        XCTAssertTrue(shared.contains("<назначение>"))
        XCTAssertTrue(shared.contains("<адрес>"))
        // The tunnel's own addresses and the times stay readable.
        XCTAssertTrue(shared.contains("172.19.0.1"))
        XCTAssertTrue(shared.contains("fdfe:dcba:9876::2"))
        XCTAssertTrue(shared.contains("2026/11/16 08:02:01"))
        XCTAssertTrue(shared.contains("15.1s"))
    }

    /// The core logs at «warn» by default; «info» lasts the diagnostic half hour only.
    func testTheDiagnosticLogLevelEndsByItself() throws {
        XCTAssertEqual(TunnelOptions().logLevel, "warn")
        var options = TunnelOptions()
        options.logLevel = "info"
        let subscription = Subscription(id: 1, name: "S", nodes: NodeAssembler.assemble([try ShareLink.parse("trojan://pw@t.example.net:443?security=tls&sni=t.example.net#T")]))
        let info = try ConfigBuilder.build(subscription: subscription, selected: nil, options: options)
        let now = Date()
        XCTAssertEqual(ConfigBuilder.expireDiagnosticLog(in: info, until: now.addingTimeInterval(60), now: now).at("log", "level"), "info")
        XCTAssertEqual(ConfigBuilder.expireDiagnosticLog(in: info, until: now.addingTimeInterval(-1), now: now).at("log", "level"), "warn")
        XCTAssertEqual(ConfigBuilder.expireDiagnosticLog(in: info, until: nil, now: now).at("log", "level"), "warn")
        options.logLevel = "trace"
        let trace = try ConfigBuilder.build(subscription: subscription, selected: nil, options: options)
        XCTAssertEqual(ConfigBuilder.expireDiagnosticLog(in: trace, until: nil, now: now).at("log", "level"), "trace")
        XCTAssertEqual(ConfigBuilder.diagnosticLogDuration, 1800)
    }
}
