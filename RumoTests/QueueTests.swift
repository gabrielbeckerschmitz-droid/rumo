import XCTest
import SwiftData
@testable import Rumo

final class QueueTests: XCTestCase {
    private func data(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    private let dia: TimeInterval = 86_400

    private func item(_ estado: Estado = .gravado) -> Item {
        Item(notaId: UUID(), cofre: "Cofre A", criadoEm: data("2026-01-01T10:00:00Z"), duracaoS: 60, estado: estado)
    }

    func testNeverDeleteBeforeProcessed() {
        let agora = data("2030-01-01T00:00:00Z")  // anos depois: ainda assim não pode
        for e in [Estado.gravado, .aguardandoInternet, .enviado, .erro] {
            let i = item(e)
            i.enviadoEm = data("2026-01-01T10:01:00Z")
            i.processadoEm = data("2026-01-02T10:00:00Z")
            XCTAssertFalse(Store.podeApagarAudio(i, agora: agora, retencaoDias: 30), "estado \(e)")
        }
        let semData = item(.processado)  // processado sem data registrada: nunca apagar
        XCTAssertFalse(Store.podeApagarAudio(semData, agora: agora, retencaoDias: 30))
    }

    func testDeleteAfterRetention() {
        let i = item(.processado)
        i.processadoEm = data("2026-01-10T12:00:00Z")
        XCTAssertFalse(Store.podeApagarAudio(i, agora: i.processadoEm!.addingTimeInterval(30 * dia - 1), retencaoDias: 30))
        XCTAssertTrue(Store.podeApagarAudio(i, agora: i.processadoEm!.addingTimeInterval(30 * dia), retencaoDias: 30))
        XCTAssertTrue(Store.podeApagarAudio(i, agora: i.processadoEm!.addingTimeInterval(8 * dia), retencaoDias: 7))
    }

    func testResendAfter24hWhenMissing() {
        let i = item(.enviado)
        i.enviadoEm = data("2026-01-10T12:00:00Z")
        XCTAssertFalse(Store.precisaReenviar(i, agora: i.enviadoEm!.addingTimeInterval(24 * 3600), existeNaCaixa: false))
        XCTAssertTrue(Store.precisaReenviar(i, agora: i.enviadoEm!.addingTimeInterval(24 * 3600 + 1), existeNaCaixa: false))
        let outro = item(.processado)
        outro.enviadoEm = i.enviadoEm
        XCTAssertFalse(Store.precisaReenviar(outro, agora: data("2030-01-01T00:00:00Z"), existeNaCaixa: false))
    }

    func testNoResendWhenPresent() {
        let i = item(.enviado)
        i.enviadoEm = data("2026-01-10T12:00:00Z")
        XCTAssertFalse(Store.precisaReenviar(i, agora: data("2026-02-10T12:00:00Z"), existeNaCaixa: true))
    }

    func testBackoffCaps() {
        XCTAssertEqual(Backoff.proxima(tentativas: 0), 30)
        XCTAssertEqual(Backoff.proxima(tentativas: 1), 60)
        XCTAssertEqual(Backoff.proxima(tentativas: 3), 240)
        XCTAssertEqual(Backoff.proxima(tentativas: 7), 3600)
        XCTAssertEqual(Backoff.proxima(tentativas: 500), 3600)
    }

    func testRotulos() {
        XCTAssertEqual(Estado.allCases.map(\.rotulo), ["Gravado", "Aguardando internet", "Enviado", "Processado", "Erro"])
    }

    @MainActor
    func testAplicarResultadoPersiste() throws {
        let container = try ModelContainer(for: Item.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let i = item(.enviado)
        container.mainContext.insert(i)
        let quando = data("2026-01-11T09:00:00Z")
        let r = Resultado(notaId: ID(i.notaId), status: .processado, titulo: "Título", tipo: "ideia", resumo: "Resumo",
                          cofre: "Cofre B", clienteSugerido: "Cliente X", pontos: 3, emAberto: 1, erro: nil)
        Store.aplicarResultado(i, resultado: Msg(id: ID(UUID()), criadoEm: Instante(quando), corpo: .resultado(r)))
        try container.mainContext.save()
        XCTAssertEqual(i.estado, .processado)
        XCTAssertEqual(i.titulo, "Título"); XCTAssertEqual(i.resumo, "Resumo"); XCTAssertEqual(i.tipo, "ideia")
        XCTAssertEqual(i.cofre, "Cofre B"); XCTAssertEqual(i.clienteSugerido, "Cliente X")
        XCTAssertEqual(i.pontos, 3); XCTAssertEqual(i.emAberto, 1)
        XCTAssertEqual(i.processadoEm, quando); XCTAssertNil(i.erroTexto)

        let e = Resultado(notaId: ID(i.notaId), status: .erro, titulo: "", tipo: "", resumo: "", cofre: "Cofre B",
                          clienteSugerido: nil, pontos: 0, emAberto: 0, erro: "Falhou ao transcrever.")
        let j = item(.enviado)
        Store.aplicarResultado(j, resultado: Msg(id: ID(UUID()), criadoEm: Instante(quando), corpo: .resultado(e)))
        XCTAssertEqual(j.estado, .erro); XCTAssertEqual(j.erroTexto, "Falhou ao transcrever.")
        XCTAssertNil(j.processadoEm)  // erro não libera a retenção
    }
}
