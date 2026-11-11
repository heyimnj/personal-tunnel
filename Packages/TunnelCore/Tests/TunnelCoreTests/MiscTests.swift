import XCTest
@testable import TunnelCore

final class MiscTests: XCTestCase {
    func testArrangementMatches1x() {
        var a = Arrangement.decode(#"{"pinned":["subscription:3"],"manual":["subscription:2","subscription:1"],"recent":[],"byName":false}"#)
        let ids: [Int64] = [1, 2, 3]
        XCTAssertEqual(a.sorted(ids, key: Arrangement.subscription, name: { "\($0)" }), [3, 2, 1])
        a.byName = true
        XCTAssertEqual(a.sorted(ids, key: Arrangement.subscription, name: { "\($0)" }), [3, 1, 2])
        a.togglePin("subscription:3")
        XCTAssertFalse(a.isPinned("subscription:3"))
        XCTAssertEqual(Arrangement.decode(a.encoded), a)
    }

    func testHeaders() {
        var info = SubscriptionInfo()
        let title = SubscriptionHeaders.parse(["Profile-Title": "base64:" + Data("Мой VPN".utf8).base64EncodedString(),
                                               "Subscription-Userinfo": "upload=10; download=20; total=100; expire=1800000000",
                                               "profile-update-interval": "12"], into: &info)
        XCTAssertEqual(title, "Мой VPN")
        XCTAssertEqual(info.usedBytes, 30)
        XCTAssertTrue(info.isLimited)
        XCTAssertEqual(info.updateIntervalHours, 12)
        XCTAssertNotNil(info.expiresAt)
    }

    func testFormat() {
        XCTAssertEqual(Format.bytes(0), "Zero KB")
        XCTAssertEqual(Format.bytes(415 * 1024), "415 KB")
        XCTAssertEqual(Format.bytes(Int64(106.7 * 1024 * 1024)), "106.7 MB")
        XCTAssertEqual(Format.duration(118_370), "32:52:50")
        XCTAssertEqual(Format.plural(36, "сервер", "сервера", "серверов"), "36 серверов")
        XCTAssertEqual(Format.plural(21, "сервер", "сервера", "серверов"), "21 сервер")
    }

    func testLegacyMigrationKeepsIDsAndTags() {
        let config = #"{"outbounds":[{"type":"selector","tag":"proxy","outbounds":["auto","США-2","Эстония-2"]},{"type":"urltest","tag":"auto","outbounds":["США-2","Эстония-2"]},{"type":"vless","tag":"США-2","server":"a.example","server_port":443,"uuid":"u"},{"type":"vless","tag":"Эстония-2","server":"b.example","server_port":443,"uuid":"u"},{"type":"direct","tag":"direct"}]}"#
        let library = LegacyMigration.library(from: [
            LegacyProfile(id: 7, name: "B", order: 1, remoteURL: "https://example.com/sub", lastUpdated: nil, config: config),
            LegacyProfile(id: 4, name: "A", order: 0, remoteURL: "", lastUpdated: nil, config: "{}"),
        ], selectedProfileID: 7, preferredTag: "Эстония-2")
        XCTAssertEqual(library.subscriptions.map(\.id), [4, 7])
        XCTAssertEqual(library.subscriptions[1].nodes.map(\.id), ["США-2", "Эстония-2"])
        XCTAssertEqual(library.subscriptions[1].nodes[0].outbound["tag"], "США-2")
        XCTAssertNil(library.subscriptions[0].url)
        XCTAssertFalse(library.subscriptions[0].warnings.isEmpty)
        XCTAssertEqual(library.activeNode?.id, "Эстония-2")
        XCTAssertEqual(library.nextID, 8)
    }

    func testBinaryCodableBlobs() {
        XCTAssertEqual(LegacyMigration.decodeBool(Data([1])), true)
        XCTAssertEqual(LegacyMigration.decodeBool(Data([0])), false)
        XCTAssertNil(LegacyMigration.decodeBool(Data()))
        XCTAssertEqual(LegacyMigration.decodeInt(Data([14])), 7)
        XCTAssertEqual(LegacyMigration.decodeInt(Data([1])), -1)
    }
}
