import XCTest
@testable import TunnelCore

final class JSONTests: XCTestCase {
    func testKeepsIntegersBooleansAndDoublesApart() throws {
        let value = try JSONValue.parse(#"{"a":1,"b":true,"c":1.5,"d":"x","e":null,"f":[1,2],"g":1e3}"#)
        XCTAssertEqual(value["a"], .int(1))
        XCTAssertEqual(value["b"], .bool(true))
        XCTAssertEqual(value["c"], .double(1.5))
        XCTAssertEqual(value["e"], .null)
        XCTAssertEqual(value["g"]?.intValue, 1000)
        XCTAssertEqual(value.serialized(), #"{"a":1,"b":true,"c":1.5,"d":"x","e":null,"f":[1,2],"g":1000}"#)
    }

    func testToleratesCommentsBOMAndTrailingCommas() throws {
        let text = "\u{FEFF}{ // comment\n \"a\": [1, 2, ], /* block */ \"b\": \"\\u0441\\ud83d\\ude00\\n\", }"
        let value = try JSONValue.parse(text)
        XCTAssertEqual(value["a"], [1, 2])
        XCTAssertEqual(value["b"], .string("с😀\n"))
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try JSONValue.parse("{\"a\":}"))
        XCTAssertThrowsError(try JSONValue.parse("[1,2"))
        XCTAssertThrowsError(try JSONValue.parse("{} x"))
    }

    func testRoundTripsThroughCodable() throws {
        let value: JSONValue = ["type": "vless", "server_port": 443, "tls": ["enabled": true], "list": ["a", 1, 2.5, nil]]
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
        XCTAssertEqual(try JSONValue.parse(value.serialized(pretty: true)), value)
    }

    func testEscapesControlCharacters() {
        XCTAssertEqual(JSONValue.string("a\"b\\c\u{01}\t").serialized(), #""a\"b\\c\u0001\t""#)
    }
}
