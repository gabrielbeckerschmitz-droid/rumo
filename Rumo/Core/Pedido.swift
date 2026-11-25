import CryptoKit
import Foundation
import SwiftData

/// Mensagem que não é nota (complemento, mover, novo_cofre), já cifrada e pronta para a caixa.
/// O Sync envia os pendentes na ordem de criação.
@Model
final class Pedido {
    var id: UUID
    var criadoEm: Date
    var blob: Data
    var enviado: Bool = false
    var tentativas: Int = 0
    var proximaTentativa: Date?

    init(id: UUID, criadoEm: Date, blob: Data) {
        self.id = id
        self.criadoEm = criadoEm
        self.blob = blob
    }

    static func novo(msg: Msg, chave: SymmetricKey) throws -> Pedido {
        Pedido(id: msg.id.uuid, criadoEm: msg.criadoEm.date, blob: try msg.sealed(key: chave))
    }
}
