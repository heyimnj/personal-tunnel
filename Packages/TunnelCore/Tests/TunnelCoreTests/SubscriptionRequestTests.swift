@testable import TunnelCore
import XCTest

/// 3.3: how subscriptions are asked for (PT-12, PT-13, PT-14).
final class SubscriptionRequestTests: XCTestCase {
    func testSHA256AndHMACMatchTheStandardVectors() {
        func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(SHA256.hash(Array("".utf8))), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex(SHA256.hash(Array("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex(SHA256.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // RFC 4231, test cases 2 and 6 (a key longer than the block).
        XCTAssertEqual(hex(SHA256.hmac(key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8))),
                       "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        XCTAssertEqual(hex(SHA256.hmac(key: [UInt8](repeating: 0xaa, count: 131), message: Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8))),
                       "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
    }

    func testANewSubscriptionSendsAnHWIDOfItsOwnPerHost() throws {
        let device = "0123456789abcdef0123456789abcdef"
        let a = SubscriptionRequest.hwid(device, host: "panel-a.example.org")
        XCTAssertEqual(a.count, 32)
        XCTAssertTrue(a.allSatisfy(\.isHexDigit))
        XCTAssertEqual(a, SubscriptionRequest.hwid(device, host: "PANEL-A.example.org"))
        XCTAssertNotEqual(a, SubscriptionRequest.hwid(device, host: "panel-b.example.org"))
        XCTAssertNotEqual(a, device)
        let fresh = Subscription(id: 1, name: "A", url: "https://panel-a.example.org/sub/token", hwidPerHost: true)
        XCTAssertEqual(fresh.hwid(device: device), a)
        // Added before 3.3 (no field in the stored library): the device's own HWID.
        let old = try JSONDecoder().decode(Subscription.self, from: Data(#"{"id": 2, "name": "B", "url": "https://panel-b.example.org/sub/x"}"#.utf8))
        XCTAssertFalse(old.hwidPerHost)
        XCTAssertEqual(old.hwid(device: device), device)
        let round = try JSONDecoder().decode(Subscription.self, from: JSONEncoder().encode(fresh))
        XCTAssertTrue(round.hwidPerHost)
    }

    func testTheIOSVersionAndLanguageGoOnlyOnTheSecondTry() {
        let device = SubscriptionRequest.Device(hwid: "h", model: "iPhone17,1", osVersion: "26.1", locale: "ru_RU")
        let attempts = SubscriptionRequest.attempts(device: device)
        XCTAssertEqual(attempts.map(\.agent), ["INCY/2.7.2", "INCY/2.7.2", "Happ/3.13.0", "Happ/3.13.0", "PersonalTunnel/2.0"])
        XCTAssertEqual(Set(attempts[0].headers.keys), ["X-HWID", "X-Device-OS", "X-Device-Model"])
        XCTAssertEqual(attempts[1].headers["X-Ver-OS"], "26.1")
        XCTAssertEqual(attempts[1].headers["X-Device-Locale"], "ru_RU")
        XCTAssertTrue(attempts[4].headers.isEmpty)
        XCTAssertTrue(SubscriptionRequest.attempts(device: nil).allSatisfy { $0.headers.isEmpty })
        XCTAssertEqual(SubscriptionRequest.attempts(device: nil).count, 3)
    }

    func testRedirectsDropDeviceHeadersAndNeverGoToHTTP() throws {
        let headers = ["User-Agent": "Happ/3.13.0", "X-HWID": "h", "X-Device-OS": "iOS", "X-Ver-OS": "26.1", "X-Device-Model": "m", "X-Device-Locale": "ru_RU", "Accept": "*/*"]
        let from = try XCTUnwrap(URL(string: "https://panel.example.org/sub/t"))
        XCTAssertEqual(SubscriptionRequest.redirected(headers, from: from, to: URL(string: "https://panel.example.org/other")!), headers)
        XCTAssertEqual(SubscriptionRequest.redirected(headers, from: from, to: URL(string: "https://cdn.example.net/x")!), ["User-Agent": "Happ/3.13.0", "Accept": "*/*"])
        XCTAssertNil(SubscriptionRequest.redirected(headers, from: from, to: URL(string: "http://panel.example.org/sub/t")!))
    }

    func testPlainHTTPIsRefusedBeforeAnyRequest() {
        XCTAssertNoThrow(try SubscriptionRequest.address(" https://panel.example.org/sub/t "))
        XCTAssertThrowsError(try SubscriptionRequest.address("http://panel.example.org/sub/t")) { error in
            XCTAssertTrue((error as? ImportError)?.message.contains("https://") ?? false)
        }
        XCTAssertThrowsError(try SubscriptionRequest.address("ftp://panel.example.org"))
        XCTAssertThrowsError(try SubscriptionRequest.address("https://"))
    }

    func testThePreviewShowsTheHostOnlyAndCountsServers() {
        XCTAssertEqual(ImportPreview.of("https://panel.example.org/sub/SECRET-TOKEN?x=1"), .subscription(host: "panel.example.org"))
        if case .invalid = ImportPreview.of("http://panel.example.org/sub/t") {} else { XCTFail("http accepted") }
        let links = "trojan://pw@t.example.net:443?security=tls&sni=t.example.net&allowInsecure=1#A\nss://" + Data("aes-128-gcm:pw".utf8).base64EncodedString() + "@s.example.net:8388#B"
        XCTAssertEqual(ImportPreview.of(links), .servers(count: 2, protocols: ["TROJAN", "SHADOWSOCKS"], unchecked: 1))
        if case .invalid = ImportPreview.of("hello") {} else { XCTFail("text without servers accepted") }
    }
}
