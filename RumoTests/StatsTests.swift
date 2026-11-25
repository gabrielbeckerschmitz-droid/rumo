import XCTest
@testable import Rumo

final class StatsTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2  // semana começa na segunda
        return c
    }

    private func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    private func item(_ quando: String, _ cofre: String = "Cofre A", dur: Int = 60, _ estado: Estado = .processado) -> Item {
        Item(notaId: UUID(), cofre: cofre, criadoEm: d(quando), duracaoS: dur, estado: estado)
    }

    // 2026-11-25 é quarta-feira; a semana vai de seg 23/11 a dom 29/11.
    func testWeekStats() {
        let itens = [
            item("2026-11-22T23:30:00Z"),                                // domingo da semana passada
            item("2026-11-18T10:00:00Z"),                                // semana passada
            item("2026-11-23T00:00:00Z", dur: 120, .gravado),            // segunda 00:00 (conta)
            item("2026-11-23T10:00:00Z", dur: 180),
            item("2026-11-25T09:00:00Z", "Cofre B", .enviado),
            item("2026-11-29T23:59:00Z", .erro),                         // domingo (conta)
            item("2026-11-30T00:00:00Z", dur: 600),                      // próxima semana (não conta)
        ]
        let s = Stats.semana(itens: itens, hoje: d("2026-11-25T12:00:00Z"), calendario: cal)
        XCTAssertEqual(s.porDia, [2, 0, 1, 0, 0, 0, 1])
        XCTAssertEqual(s.total, 4)
        XCTAssertEqual(s.minutos, 7)            // 120 + 180 + 60 + 60 = 420 s
        XCTAssertEqual(s.fila, 3)               // gravado + enviado + erro (todos os itens, não só a semana)
        XCTAssertEqual(s.deltaSemanaPassada, 2) // 4 nesta, 2 na passada
        XCTAssertEqual(s.porCofre.map(\.0), ["Cofre A", "Cofre B"])
        XCTAssertEqual(s.porCofre.map(\.1), [3, 1])
    }

    func testPorCofreUsesDestinationNotCitations() {
        let i = item("2026-11-24T10:00:00Z", "Cofre A")
        i.clienteSugerido = "Cofre B"  // citado na fala, mas o destino é o A
        let s = Stats.semana(itens: [i], hoje: d("2026-11-25T12:00:00Z"), calendario: cal)
        XCTAssertEqual(s.porCofre.map(\.0), ["Cofre A"])
        XCTAssertEqual(s.porCofre.map(\.1), [1])
    }

    func testWeekStartsOnMondayWhenTodayIsSunday() {
        let i = item("2026-11-23T08:00:00Z")  // segunda
        let s = Stats.semana(itens: [i], hoje: d("2026-11-29T20:00:00Z"), calendario: cal)
        XCTAssertEqual(s.porDia, [1, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Stats.indiceDoDia(d("2026-11-29T20:00:00Z"), calendario: cal), 6)
        XCTAssertEqual(Stats.indiceDoDia(d("2026-11-23T08:00:00Z"), calendario: cal), 0)
    }

    func testPCOnlineWithin15Min() {
        let agora = d("2026-11-25T12:00:00Z")
        XCTAssertTrue(Stats.pc(ultimoResultado: agora.addingTimeInterval(-14 * 60), agora: agora).online)
        XCTAssertEqual(Stats.pc(ultimoResultado: agora.addingTimeInterval(-14 * 60), agora: agora).texto, "PC online")
        let off = Stats.pc(ultimoResultado: agora.addingTimeInterval(-15 * 60), agora: agora)
        XCTAssertFalse(off.online)
        XCTAssertEqual(off.texto, "PC sem resposta há 15 min")
        XCTAssertEqual(Stats.pc(ultimoResultado: agora.addingTimeInterval(-3 * 3600), agora: agora).texto, "PC sem resposta há 3 h")
        XCTAssertEqual(Stats.pc(ultimoResultado: agora.addingTimeInterval(-2 * 86_400), agora: agora).texto, "PC sem resposta há 2 dias")
        XCTAssertEqual(Stats.pc(ultimoResultado: nil, agora: agora).texto, "PC sem resposta")
    }

    func testGreetingByHour() {
        XCTAssertEqual(Stats.saudacao(hora: 5, nome: ""), "Bom dia")
        XCTAssertEqual(Stats.saudacao(hora: 11, nome: "  "), "Bom dia")
        XCTAssertEqual(Stats.saudacao(hora: 12, nome: "Ana"), "Boa tarde, Ana")
        XCTAssertEqual(Stats.saudacao(hora: 17, nome: " Ana "), "Boa tarde, Ana")
        XCTAssertEqual(Stats.saudacao(hora: 18, nome: ""), "Boa noite")
        XCTAssertEqual(Stats.saudacao(hora: 2, nome: ""), "Boa noite")
    }
}
