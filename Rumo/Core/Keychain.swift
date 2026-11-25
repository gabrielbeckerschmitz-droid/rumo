import Foundation
import Security

struct Pareamento: Codable, Equatable {
    var chave: Data   // 32 bytes (AES-256); no JSON vai em base64
    var token: String
    var dono: String
    var repo: String

    struct Erro: Error, LocalizedError {
        let errorDescription: String?
    }

    /// Lê o QR do PC: {"v":1,"chave":<b64>,"token":..,"dono":..,"repo":..}
    static func fromQR(_ json: String) throws -> Pareamento {
        struct QR: Decodable { let v: Int; let chave: Data; let token: String; let dono: String; let repo: String }
        let qr: QR
        do { qr = try JSONDecoder().decode(QR.self, from: Data(json.utf8)) }
        catch { throw Erro(errorDescription: "Este QR não é do Rumo. Gere outro no PC e leia de novo.") }
        guard qr.v == 1 else {
            throw Erro(errorDescription: "Este QR é de outra versão do Rumo. Atualize o app e o programa do PC.")
        }
        guard qr.chave.count == 32, !qr.token.isEmpty, !qr.dono.isEmpty, !qr.repo.isEmpty else {
            throw Erro(errorDescription: "O QR está incompleto ou com a chave inválida. Gere outro no PC.")
        }
        return Pareamento(chave: qr.chave, token: qr.token, dono: qr.dono, repo: qr.repo)
    }
}

struct KeychainError: Error, LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Não foi possível guardar o pareamento no Keychain do iPhone (código \(status))." }
}

enum Keychain {
    static let service = "br.com.nortea.rumo"
    static let account = "pareamento"

    private static var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    /// Substitui o item existente (apaga e adiciona).
    static func save(_ cfg: Pareamento) throws {
        let data = try JSONEncoder().encode(cfg)
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData] = data
        q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func load() -> Pareamento? {
        var q = query
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Pareamento.self, from: data)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
