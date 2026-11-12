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

    func testCoreTextFormatsAndPlurals() {
        XCTAssertEqual(CoreText.fill("Есть %@ из %@ (100%%)", ["1", "2"]), "Есть 1 из 2 (100%)")
        XCTAssertEqual(CoreText.f("%@ с назад", "5"), "5 с назад")
        CoreText.russianPlurals = false
        defer { CoreText.russianPlurals = true }
        XCTAssertEqual(Format.plural(21, "server", "servers", "servers"), "21 servers")
        XCTAssertEqual(Format.plural(1, "server", "servers", "servers"), "1 server")
    }

    func testEmptySubscriptionIsNeverActive() {
        let server = ServerNode(id: "a", name: "a", outbound: ["type": "socks", "tag": "a", "server": "h", "server_port": 1])
        let library = Library(subscriptions: [Subscription(id: 1, name: "VPN Direct Free"), Subscription(id: 2, name: "B", nodes: [server])],
                              activeSubscriptionID: 1)
        XCTAssertEqual(library.activeSubscription?.id, 2)
        XCTAssertEqual(library.activeNode?.id, "a")
    }

    func testBinaryCodableBlobs() {
        XCTAssertEqual(LegacyMigration.decodeBool(Data([1])), true)
        XCTAssertEqual(LegacyMigration.decodeBool(Data([0])), false)
        XCTAssertNil(LegacyMigration.decodeBool(Data()))
        XCTAssertEqual(LegacyMigration.decodeInt(Data([14])), 7)
        XCTAssertEqual(LegacyMigration.decodeInt(Data([1])), -1)
    }
}

final class LogTextTests: XCTestCase {
    func testColourCodesAndLevelGo() {
        XCTAssertEqual(LogText.clean("[31mERROR[0m[0031] [[38;5;134m2639462006[0m 15.12s] connection: open connection to 1.2.3.4:443 using outbound/vless[A]: context deadline exceeded"),
                       "[0031] [2639462006 15.12s] connection: open connection to 1.2.3.4:443 using outbound/vless[A]: context deadline exceeded")
        XCTAssertEqual(LogText.clean("\u{1B}[36mINFO\u{1B}[0m[0029] inbound/tun[tun-in]: inbound DNS packet"), "[0029] inbound/tun[tun-in]: inbound DNS packet")
        XCTAssertEqual(LogText.clean("[app] Подписка «A»: Xray JSON"), "[app] Подписка «A»: Xray JSON")
        XCTAssertEqual(LogText.clean("[mem] занято 21.4 МиБ"), "[mem] занято 21.4 МиБ")
    }
}

final class ServerInspectionTests: XCTestCase {
    func testSafeJSONMasksSecretsAndKeepsTheRest() throws {
        let node = NodeAssembler.assemble([try ShareLink.parse("vless://11111111-2222-3333-4444-555555555555@h.example:443?security=reality&pbk=SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc&sid=ab12&sni=h.example&fp=chrome&flow=xtls-rprx-vision&type=tcp#A"),
                                           try ShareLink.parse("hysteria2://secretpass@hy.example:443?obfs=salamander&obfs-password=obfspass#B")])
        let reality = ServerInspection.safeJSON(node[0])
        XCTAssertFalse(reality.contains("11111111-2222"))
        XCTAssertFalse(reality.contains("\"ab12\""))
        XCTAssertTrue(reality.contains("h.example"))
        XCTAssertTrue(reality.contains("xtls-rprx-vision"))
        let hy = ServerInspection.safeJSON(node[1])
        XCTAssertFalse(hy.contains("secretpass"))
        XCTAssertFalse(hy.contains("obfspass"))
        XCTAssertTrue(hy.contains("salamander"))
        let details = Dictionary(uniqueKeysWithValues: ServerInspection.details(node[0]))
        XCTAssertEqual(details["Flow"], "xtls-rprx-vision")
        XCTAssertEqual(details["uTLS"], "chrome")
    }
}

final class SubscriptionMergeTests: XCTestCase {
    func testOnlyServersTheFirstAnswerLacksAreAdded() throws {
        let base = [try ShareLink.parse("vless://11111111-2222-3333-4444-555555555555@a.example:443?security=tls&type=ws#A")]
        let extra = [
            try ShareLink.parse("vless://11111111-2222-3333-4444-555555555555@a.example:443?security=tls&type=ws#A again"),
            try ShareLink.parse("hysteria2://pass@b.example:443#B"),
            try ShareLink.parse("trojan://pw@a.example:8443#Other port"),
        ]
        let added = SubscriptionMerge.missing(from: extra, in: base)
        XCTAssertEqual(added.map(\.name), ["B", "Other port"])
        // A server Xray runs is the same server as its plain link.
        let xray = try ContentImporter.parse(#"[{"remarks": "X", "outbounds": [{"protocol": "vless", "settings": {"vnext": [{"address": "x.example", "port": 443, "users": [{"id": "11111111-2222-3333-4444-555555555555"}]}]}, "streamSettings": {"finalmask": {"tcp": [{"type": "sudoku"}]}}}]}]"#).nodes
        XCTAssertEqual(xray[0].outbound["type"], "xray")
        XCTAssertTrue(SubscriptionMerge.missing(from: [try ShareLink.parse("vless://11111111-2222-3333-4444-555555555555@x.example:443#X")], in: xray).isEmpty)
    }
}

final class HideServersTests: XCTestCase {
    func testServerNamesAndTheirAddressesGo() {
        let text = """
        DEBUG [0011] dns: cached A connect.example.online. 84 IN A 31.77.217.124
        INFO [0011] outbound/vless[США]: outbound connection to 17.253.53.146:443
        DEBUG [0016] outbound/urltest[auto]: dial tcp 188.225.34.92:443 via 188.225.34.92.example.online
        """
        let hidden = Redactor.hideServers(text, hosts: ["connect.example.online", "188.225.34.92.example.online"])
        XCTAssertFalse(hidden.contains("example.online"))
        XCTAssertFalse(hidden.contains("31.77.217.124"))
        XCTAssertFalse(hidden.contains("188.225.34.92"))
        // Other sites' addresses stay: they are not the user's servers.
        XCTAssertTrue(hidden.contains("17.253.53.146"))
    }
}

final class SubscriptionStubTests: XCTestCase {
    func testThePanelsMessageIsNotAList() {
        XCTAssertTrue(SubscriptionStub.isStub(["❌ Ваше приложение не поддерживается", "⚙️ Включите поддержку HWID", "📲 Либо используйте HAPP или INCY"]))
        XCTAssertFalse(SubscriptionStub.isStub(["Россия", "Финляндия"]))
        XCTAssertFalse(SubscriptionStub.isStub(Array(repeating: "не поддерживается", count: 8)))
    }
}

final class ServerDraftTests: XCTestCase {
    func testRealityVisionDraftAndBack() throws {
        var draft = ServerDraft()
        draft.name = "Ручной"
        draft.host = "r.example.net"
        draft.secret = "11111111-2222-3333-4444-555555555555"
        draft.vision = true
        draft.security = .reality
        draft.sni = "www.apple.com"
        draft.publicKey = "SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc"
        draft.shortID = "ab12"
        let object = try draft.outbound()
        XCTAssertEqual(object["type"], "vless")
        XCTAssertEqual(object["flow"], "xtls-rprx-vision")
        XCTAssertEqual(object.at("tls", "reality", "short_id"), "ab12")
        XCTAssertEqual(object.at("tls", "utls", "fingerprint"), "chrome")
        XCTAssertEqual(object.at("tls", "server_name"), "www.apple.com")
        XCTAssertNil(object["transport"])
        var back = try XCTUnwrap(ServerDraft(outbound: object, name: "Ручной"))
        XCTAssertEqual(back, draft)
        back.transport = .ws
        back.path = "/ws"
        back.hostHeader = "cdn.example.net"
        let ws = try back.outbound()
        XCTAssertNil(ws["flow"])   // Vision only over TCP
        XCTAssertEqual(ws.at("transport", "headers", "Host"), "cdn.example.net")
    }

    func testOtherProtocolsAndMistakes() throws {
        var draft = ServerDraft()
        draft.proto = .hysteria2
        draft.host = "hy.example.net"
        draft.secret = "pw"
        draft.obfsPassword = "mask"
        draft.hopPorts = "20000-30000"
        let hy = try draft.outbound()
        XCTAssertEqual(hy.at("tls", "alpn"), ["h3"])
        XCTAssertEqual(hy["server_ports"], ["20000:30000"])
        XCTAssertEqual(hy.at("obfs", "type"), "salamander")

        draft = ServerDraft()
        draft.proto = .wireguard
        draft.host = "wg.example.net"
        draft.port = "51820"
        draft.privateKey = "a"
        draft.peerPublicKey = "b"
        draft.localAddress = "10.7.0.2"
        let wg = try draft.outbound()
        XCTAssertEqual(wg["address"], ["10.7.0.2/32"])
        XCTAssertEqual(ServerDraft(outbound: wg, name: "W")?.localAddress, "10.7.0.2/32")

        draft = ServerDraft()
        XCTAssertThrowsError(try draft.outbound())   // no address
        draft.host = "x.example.net"
        draft.port = "70000"
        XCTAssertThrowsError(try draft.outbound())
        XCTAssertNil(ServerDraft(outbound: ["type": "urltest"], name: "G"))
    }

    /// Editing keeps what the form does not show and drops what it turned off.
    func testEditKeepsFieldsTheFormDoesNotShow() throws {
        let original: JSONValue = [
            "type": "vless", "tag": "a", "server": "x.example.net", "server_port": 443,
            "uuid": "11111111-2222-3333-4444-555555555555", "flow": "xtls-rprx-vision", "packet_encoding": "packetaddr",
            "multiplex": ["enabled": true, "protocol": "h2mux"],
            "tls": ["enabled": true, "server_name": "x.example.net", "min_version": "1.3",
                    "utls": ["enabled": true, "fingerprint": "firefox"],
                    "ech": ["enabled": true]],
        ]
        var draft = try XCTUnwrap(ServerDraft(outbound: original, name: "A"))
        draft.host = "y.example.net"
        draft.port = "8443"
        let edited = try draft.outbound(updating: original)
        XCTAssertEqual(edited["server"], "y.example.net")
        XCTAssertEqual(edited["server_port"], 8443)
        XCTAssertEqual(edited["flow"], "xtls-rprx-vision")
        XCTAssertEqual(edited["packet_encoding"], "packetaddr")
        XCTAssertEqual(edited.at("multiplex", "protocol"), "h2mux")
        XCTAssertEqual(edited.at("tls", "min_version"), "1.3")
        XCTAssertEqual(edited.at("tls", "ech", "enabled"), true)
        XCTAssertEqual(edited.at("tls", "utls", "fingerprint"), "firefox")

        draft.vision = false
        draft.security = .none
        let plain = try draft.outbound(updating: original)
        XCTAssertNil(plain["flow"])
        XCTAssertNil(plain["tls"])
        XCTAssertEqual(plain.at("multiplex", "enabled"), true)

        let xhttp: JSONValue = [
            "type": "vless", "server": "x.example.net", "server_port": 443, "uuid": "11111111-2222-3333-4444-555555555555",
            "transport": ["type": "xhttp", "path": "/a", "mode": "packet-up", "x_padding_bytes": "100-1000"],
        ]
        var other = try XCTUnwrap(ServerDraft(outbound: xhttp, name: "X"))
        other.path = "/b"
        let moved = try other.outbound(updating: xhttp)
        XCTAssertEqual(moved.at("transport", "path"), "/b")
        XCTAssertEqual(moved.at("transport", "mode"), "packet-up")
        XCTAssertEqual(moved.at("transport", "x_padding_bytes"), "100-1000")
        other.transport = .tcp
        XCTAssertNil(try other.outbound(updating: xhttp)["transport"])
    }
}
