import XCTest
@testable import TunnelCore

final class CountriesTests: XCTestCase {
    func testRussianCountryNameBecomesEnglishWithoutItsNumber() {
        let result = Countries.resolve(name: "🇺🇸 США-2")
        XCTAssertEqual(result.code, "US")
        XCTAssertEqual(result.label, "USA")
        XCTAssertEqual(result.droppedIndex, "2")
    }

    func testLatinCountryKeepsItsNumber() {
        XCTAssertEqual(Countries.resolve(name: "Switzerland 1").label, "Switzerland 1")
        XCTAssertEqual(Countries.resolve(name: "Switzerland 1").code, "CH")
        XCTAssertEqual(Countries.resolve(name: "🇭🇰 Hong Kong").label, "Hong Kong")
        XCTAssertEqual(Countries.resolve(name: "Нидерланды").label, "Netherlands")
    }

    func testOtherNamesStayAsGiven() {
        let result = Countries.resolve(name: "Белые списки | Авто")
        XCTAssertNil(result.code)
        XCTAssertEqual(result.label, "Белые списки | Авто")
        XCTAssertEqual(Countries.resolve(name: "🇩🇪 Frankfurt fast").label, "Frankfurt fast")
        XCTAssertEqual(Countries.resolve(name: "🇩🇪 Frankfurt fast").code, "DE")
        XCTAssertEqual(Countries.resolve(name: "Germany Frankfurt").code, "DE")
        XCTAssertEqual(Countries.resolve(name: "Польша-Безлим-Wi-Fi").code, "PL")
        XCTAssertNil(Countries.resolve(name: "Wi-Fi 5G").code)
    }

    func testFlagEmoji() {
        XCTAssertEqual(Countries.flagEmoji(code: "us"), "🇺🇸")
        XCTAssertNil(Countries.flagEmoji(code: "X1"))
        XCTAssertNil(Countries.flagEmoji(code: nil))
    }

    func testCollidingShortLabelsGetTheirNumbersBack() {
        let nodes = ["США-1", "США-2", "Эстония-2"].map { ServerNode(id: $0, name: $0, outbound: ["type": "vless", "tag": .string($0)]) }
        let labels = ServerLabels.make(for: nodes)
        XCTAssertEqual(labels["США-1"]?.text, "USA 1")
        XCTAssertEqual(labels["США-2"]?.text, "USA 2")
        XCTAssertEqual(labels["Эстония-2"]?.text, "Estonia")
        XCTAssertEqual(labels["Эстония-2"]?.countryCode, "EE")
    }
}
