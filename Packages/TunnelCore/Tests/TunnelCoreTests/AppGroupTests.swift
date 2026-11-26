import XCTest
@testable import TunnelCore

final class AppGroupTests: XCTestCase {
    /// PT Lab: with `AppGroupStrict` the declared group is used as it is, never one
    /// borrowed from the signing profile.
    func testStrictKeepsTheDeclaredGroup() {
        XCTAssertEqual(AppGroup.resolve(declared: "group.example.lab", strict: true), "group.example.lab")
    }

    /// Without a granted group (Linux, tests) the declared one stands either way.
    func testDeclaredWithoutAGrantedGroup() {
        XCTAssertEqual(AppGroup.resolve(declared: "group.example.app", strict: false), "group.example.app")
    }
}
