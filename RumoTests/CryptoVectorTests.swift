import XCTest
import CryptoKit
@testable import Rumo

/// Carrega os vetores gerados pelo lado Python (dados sintéticos).
enum Vectors {
    static func load() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: CryptoVectorTests.self).url(forResource: "vectors", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

final class CryptoVectorTests: XCTestCase {
    func testOpensAllPythonVectors() throws {
        let rows = try XCTUnwrap(Vectors.load()["crypto"] as? [[String: String]])
        XCTAssertFalse(rows.isEmpty)
        for r in rows {
            let key = SymmetricKey(data: Data(base64Encoded: r["key_b64"]!)!)
            let blob = Data(base64Encoded: r["blob_b64"]!)!
            let plain = Data(base64Encoded: r["plaintext_b64"]!)!
            XCTAssertEqual(try Crypto.open(blob, key: key), plain)
            // mesmo nonce => mesmo blob que o Python produziu
            let nonce = try AES.GCM.Nonce(data: Data(base64Encoded: r["nonce_b64"]!)!)
            XCTAssertEqual(try Crypto.seal(plain, key: key, nonce: nonce), blob)
        }
    }

    func testSealLayout() throws {
        let key = SymmetricKey(size: .bits256)
        let pt = Data("ideia de ação".utf8)
        let a = try Crypto.seal(pt, key: key), b = try Crypto.seal(pt, key: key)
        XCTAssertEqual(a.count, 12 + pt.count + 16)
        XCTAssertNotEqual(a.prefix(12), b.prefix(12), "nonce aleatório por arquivo")
        XCTAssertEqual(try Crypto.open(a, key: key), pt)
    }

    func testWrongKeyAndCorruptionFail() throws {
        let key = SymmetricKey(size: .bits256)
        var blob = try Crypto.seal(Data("x".utf8), key: key)
        XCTAssertThrowsError(try Crypto.open(blob, key: SymmetricKey(size: .bits256)))
        blob[blob.count - 1] ^= 1
        XCTAssertThrowsError(try Crypto.open(blob, key: key))
        XCTAssertThrowsError(try Crypto.open(Data([1, 2, 3]), key: key))
    }
}
