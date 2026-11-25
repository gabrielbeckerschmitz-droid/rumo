import XCTest
@testable import Rumo

final class AppLockTests: XCTestCase {
    private let saiu = Date(timeIntervalSince1970: 1_800_000_000)

    func testLockAfter5Min() {
        XCTAssertTrue(AppLock.precisaDesbloquear(saiuEm: saiu, agora: saiu.addingTimeInterval(300)))
        XCTAssertTrue(AppLock.precisaDesbloquear(saiuEm: saiu, agora: saiu.addingTimeInterval(3600)))
        XCTAssertTrue(AppLock.precisaDesbloquear(saiuEm: nil, agora: saiu))  // abertura a frio
    }

    func testNoLockUnder5Min() {
        XCTAssertFalse(AppLock.precisaDesbloquear(saiuEm: saiu, agora: saiu.addingTimeInterval(299)))
        XCTAssertFalse(AppLock.precisaDesbloquear(saiuEm: saiu, agora: saiu))
    }
}
