import CryptoKit
import Foundation

struct CryptoError: Error, LocalizedError {
    var errorDescription: String? { "Não foi possível abrir o arquivo: chave errada ou arquivo corrompido." }
}

/// AES-256-GCM. Blob = nonce(12) || ciphertext || tag(16) (o `combined` do CryptoKit).
enum Crypto {
    static func seal(_ pt: Data, key: SymmetricKey, nonce: AES.GCM.Nonce? = nil) throws -> Data {
        let box = try AES.GCM.seal(pt, using: key, nonce: nonce ?? AES.GCM.Nonce())
        guard let combined = box.combined else { throw CryptoError() }
        return combined
    }

    static func open(_ blob: Data, key: SymmetricKey) throws -> Data {
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: key) }
        catch { throw CryptoError() }
    }
}
