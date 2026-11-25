import XCTest
@testable import Rumo

final class KeychainTests: XCTestCase {
    override func setUp() { Keychain.delete() }
    override func tearDown() { Keychain.delete() }

    func testSaveLoadReplaceDelete() throws {
        XCTAssertNil(Keychain.load())
        let a = Pareamento(chave: Data(repeating: 7, count: 32), token: "t1", dono: "d", repo: "r")
        try Keychain.save(a)
        XCTAssertEqual(Keychain.load(), a)
        let b = Pareamento(chave: Data(repeating: 9, count: 32), token: "t2", dono: "d2", repo: "r2")
        try Keychain.save(b)
        XCTAssertEqual(Keychain.load(), b)
        Keychain.delete()
        XCTAssertNil(Keychain.load())
    }
}
