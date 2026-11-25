import Foundation
import SwiftData

enum Estado: String, Codable, CaseIterable {
    case gravado, aguardandoInternet, enviado, processado, erro

    var rotulo: String {
        switch self {
        case .gravado: return "Gravado"
        case .aguardandoInternet: return "Aguardando internet"
        case .enviado: return "Enviado"
        case .processado: return "Processado"
        case .erro: return "Erro"
        }
    }
}

@Model
final class Item {
    var notaId: UUID
    var cofre: String
    var criadoEm: Date
    var duracaoS: Int
    var estado: Estado
    /// Caminho RELATIVO a Application Support (ex.: "fila/<uuid>.bin"); resolva com `Fila.url(_:base:)`.
    var arquivoCifrado: String?
    var enviadoEm: Date?
    var processadoEm: Date?
    var titulo: String?
    var resumo: String?
    var tipo: String?
    var clienteSugerido: String?
    var erroTexto: String?
    var tentativas: Int = 0
    var proximaTentativa: Date?
    var pontos: Int = 0
    var emAberto: Int = 0
    var texto: String?  // nota digitada (sem áudio)
    var partesEnviadas: Int = 0
    var caminhosInbox: [String] = []  // caminhos no GitHub das partes enviadas, para checar reenvio

    init(notaId: UUID, cofre: String, criadoEm: Date, duracaoS: Int, estado: Estado = .gravado) {
        self.notaId = notaId
        self.cofre = cofre
        self.criadoEm = criadoEm
        self.duracaoS = duracaoS
        self.estado = estado
    }
}
