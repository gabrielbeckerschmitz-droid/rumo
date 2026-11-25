import Foundation

enum Backoff {
    /// 30 s × 2ⁿ, no máximo 1 h.
    static func proxima(tentativas: Int) -> TimeInterval {
        min(30 * pow(2, Double(min(max(tentativas, 0), 20))), 3600)
    }
}

enum Store {
    /// Regra do usuário: nunca apagar antes de `processado`; depois, só passada a retenção.
    static func podeApagarAudio(_ item: Item, agora: Date, retencaoDias: Int) -> Bool {
        guard item.estado == .processado, let quando = item.processadoEm else { return false }
        return agora >= quando.addingTimeInterval(TimeInterval(retencaoDias) * 86_400)
    }

    static func precisaReenviar(_ item: Item, agora: Date, existeNaCaixa: Bool) -> Bool {
        guard item.estado == .enviado, let enviado = item.enviadoEm, !existeNaCaixa else { return false }
        return agora.timeIntervalSince(enviado) > 24 * 3600
    }

    static func aplicarResultado(_ item: Item, resultado msg: Msg) {
        guard case .resultado(let r) = msg.corpo else { return }
        item.cofre = r.cofre
        item.titulo = r.titulo
        item.resumo = r.resumo
        item.tipo = r.tipo
        item.clienteSugerido = r.clienteSugerido
        item.pontos = r.pontos
        item.emAberto = r.emAberto
        switch r.status {
        case .processado:
            item.estado = .processado
            item.processadoEm = msg.criadoEm.date
            item.erroTexto = nil
        case .erro:
            item.estado = .erro
            item.erroTexto = r.erro
        }
    }
}
