import CryptoKit
import SwiftData
import XCTest
@testable import Rumo

private var cal: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    c.firstWeekday = 2
    return c
}
private func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
private func item(_ quando: String, _ cofre: String = "Cofre A", dur: Int = 60, estado: Estado = .processado) -> Item {
    Item(notaId: UUID(), cofre: cofre, criadoEm: d(quando), duracaoS: dur, estado: estado)
}

final class DiarioTests: XCTestCase {
    func testGroupsByDayNewestFirst() {
        let a = item("2026-11-25T09:00:00Z", dur: 120)
        let b = item("2026-11-25T18:00:00Z", dur: 180)
        let c = item("2026-11-24T10:00:00Z", dur: 60)
        let g = Diario.agrupar([a, c, b], cofre: nil, calendario: cal)
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g[0].dia, d("2026-11-25T00:00:00Z"))
        XCTAssertTrue(g[0].itens[0] === b && g[0].itens[1] === a, "mais recente primeiro")
        XCTAssertEqual(g[0].rotulo, "2 notas · 5 min")
        XCTAssertEqual(g[1].rotulo, "1 nota · 1 min")
    }

    func testFilterByVault() {
        let itens = [item("2026-11-25T09:00:00Z", "Cofre B"), item("2026-11-25T10:00:00Z", "Cofre A"), item("2026-11-24T10:00:00Z", "Cofre B")]
        XCTAssertEqual(Diario.cofres(itens), ["Cofre A", "Cofre B"])
        let g = Diario.agrupar(itens, cofre: "Cofre B", calendario: cal)
        XCTAssertEqual(g.flatMap(\.itens).count, 2)
        XCTAssertTrue(g.flatMap(\.itens).allSatisfy { $0.cofre == "Cofre B" })
        XCTAssertEqual(Diario.agrupar(itens, cofre: nil, calendario: cal).flatMap(\.itens).count, 3)
        XCTAssertTrue(Diario.agrupar([], cofre: nil, calendario: cal).isEmpty)
    }
}

final class PedidosTests: XCTestCase {
    private let agora = Date(timeIntervalSince1970: 1_800_000_000)
    private let chave = SymmetricKey(data: Data(repeating: 7, count: 32))

    func testMoveSuggestionOnlyWhenDifferentVault() {
        let i = item("2026-11-25T09:00:00Z", "Cofre A")
        XCTAssertNil(Pedidos.sugestaoMover(i))
        i.clienteSugerido = ""
        XCTAssertNil(Pedidos.sugestaoMover(i))
        i.clienteSugerido = "Cofre A"
        XCTAssertNil(Pedidos.sugestaoMover(i), "já está lá")
        i.clienteSugerido = "Cofre B"
        XCTAssertEqual(Pedidos.sugestaoMover(i), "Cofre B")
    }

    func testMoverMsgIsValid() throws {
        let nota = UUID()
        let m = Pedidos.mover(notaId: nota, destino: "Cofre B", agora: agora)
        XCTAssertEqual(m.tipo, "mover")
        XCTAssertEqual(try Msg.decode(m.json()), m)
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: m.json()) as? [String: Any])
        XCTAssertEqual(j["nota_id"] as? String, nota.uuidString.lowercased())
        XCTAssertEqual(j["destino"] as? String, "Cofre B")
        XCTAssertEqual(j["v"] as? Int, 1)
    }

    func testComplementoAudioMsgIsValid() throws {
        let nota = UUID()
        let m = Pedidos.complemento(notaId: nota, audio: Data([1, 2, 3]), duracaoS: 7, agora: agora)
        XCTAssertEqual(try Msg.decode(m.json()), m)
        guard case .complemento(let c) = m.corpo else { return XCTFail("não é complemento") }
        XCTAssertEqual(c.notaId.uuid, nota)
        XCTAssertNotEqual(c.complementoId.uuid, nota, "complemento_id é novo")
        XCTAssertEqual(c.audio, Data([1, 2, 3]))
        XCTAssertEqual(c.duracaoS, 7)
        XCTAssertNil(c.texto)
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: m.json()) as? [String: Any])
        XCTAssertEqual(j["audio"] as? String, "AQID")
        XCTAssertEqual(j["duracao_s"] as? Int, 7)
        XCTAssertNil(j["texto"])
    }

    func testComplementoTextoMsgIsValid() throws {
        let m = Pedidos.complemento(notaId: UUID(), texto: "mais um ponto", agora: agora)
        XCTAssertEqual(try Msg.decode(m.json()), m)
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: m.json()) as? [String: Any])
        XCTAssertEqual(j["texto"] as? String, "mais um ponto")
        XCTAssertNil(j["audio"])
    }

    func testNovoCofreMsgIsValid() throws {
        let m = Pedidos.novoCofre(nome: "Cofre C", cliente: true, agora: agora)
        XCTAssertEqual(m.tipo, "novo_cofre")
        XCTAssertEqual(try Msg.decode(m.json()), m)
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: m.json()) as? [String: Any])
        XCTAssertEqual(j["nome"] as? String, "Cofre C")
        XCTAssertEqual(j["cliente"] as? Bool, true)
    }

    func testPedidoIsSealedAndOpens() throws {
        let m = Pedidos.mover(notaId: UUID(), destino: "Cofre B", agora: agora)
        let p = try Pedido.novo(msg: m, chave: chave)
        XCTAssertEqual(try Msg.open(p.blob, key: chave), m)
        XCTAssertEqual(p.id, m.id.uuid)
    }

    func testVaultNameValidation() throws {
        let existentes = [Cofre(nome: "Cofre A", cliente: false)]
        XCTAssertEqual(try Pedidos.nomeCofre("  Cofre C ", existentes: existentes), "Cofre C")
        let ruins = ["", "   ", "a/b", "a\\b", "a:b", "a*b", "a?b", "a\"b", "a<b", "a|b", "a..b", "termina.", "tab\there"]
        for ruim in ruins {
            XCTAssertThrowsError(try Pedidos.nomeCofre(ruim, existentes: []), ruim)
        }
        XCTAssertThrowsError(try Pedidos.nomeCofre("cofre a", existentes: existentes), "repetido, sem diferenciar caixa")
    }

    func testTypedNote() {
        XCTAssertNil(Pedidos.itemTexto("  \n ", cofre: "Cofre A", agora: agora))
        let i = Pedidos.itemTexto("  ideia nova ", cofre: "Cofre A", agora: agora)
        XCTAssertEqual(i?.texto, "ideia nova")
        XCTAssertEqual(i?.estado, .gravado)
        XCTAssertEqual(i?.cofre, "Cofre A")
        XCTAssertEqual(i?.duracaoS, 0)
        XCTAssertEqual(i?.criadoEm, agora)
        XCTAssertNil(i?.arquivoCifrado)
    }

    func testUnsentCountAndKeyChangeWarning() {
        let itens = [item("2026-11-25T09:00:00Z", estado: .gravado), item("2026-11-25T09:00:00Z", estado: .aguardandoInternet),
                     item("2026-11-25T09:00:00Z", estado: .enviado), item("2026-11-25T09:00:00Z", estado: .processado),
                     item("2026-11-25T09:00:00Z", estado: .erro)]
        XCTAssertEqual(Pedidos.naoEnviados(itens, pedidos: 1), 3)
        XCTAssertEqual(Pedidos.avisoTrocaChave(3),
                       "Há 3 gravações ainda não enviadas. Envie-as antes de trocar a chave, senão o PC não vai conseguir abri-las.")
        XCTAssertEqual(Pedidos.avisoTrocaChave(1),
                       "Há 1 gravação ainda não enviada. Envie-a antes de trocar a chave, senão o PC não vai conseguir abri-la.")
    }

    func testPendingVaultsMergeUntilPCConfirms() {
        let a = Cofre(nome: "Cofre A", cliente: false), c = Cofre(nome: "Cofre C", cliente: true)
        var r = Destinos.mesclar(locais: [a], pendentes: [c])
        XCTAssertEqual(r.lista, [a, c])
        XCTAssertEqual(r.restantes, [c])
        r = Destinos.mesclar(locais: [a, c], pendentes: [c])
        XCTAssertEqual(r.lista, [a, c])
        XCTAssertTrue(r.restantes.isEmpty, "o PC confirmou")
    }
}

@MainActor
final class RecorderAvulsoTests: XCTestCase {
    func testComplementoAudioDoesNotCreateItem() throws {
        let a = try AmbienteGravador()
        try a.recorder.startAvulso(cofre: "Cofre A")
        XCTAssertTrue(a.recorder.gravando)
        var recebido: (Data, Int)?
        try a.recorder.stopAvulso { recebido = ($0, $1) }
        let (m4a, seg) = try XCTUnwrap(recebido)
        XCTAssertEqual(seg, 2)
        XCTAssertEqual(try CAFTeste.duracaoM4A(m4a), 2.4, accuracy: 0.3)
        XCTAssertEqual(try a.itens().count, 0)
        XCTAssertEqual(a.gatilhos.n, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: a.pasta.path), [])
        XCTAssertFalse(a.recorder.gravando)
    }

    func testComplementoAudioKeepsRecordingIfSavingFails() async throws {
        let a = try AmbienteGravador()
        try a.recorder.startAvulso(cofre: "Cofre A")
        XCTAssertThrowsError(try a.recorder.stopAvulso { _, _ in throw Recorder.Erro("sem espaço") })
        XCTAssertEqual(try a.itens().count, 0)
        let n = await a.recorder.recuperarPendentes()
        XCTAssertEqual(n, 1, "o áudio não se perde: vira uma nota normal")
        XCTAssertEqual(try a.itens().first?.cofre, "Cofre A")
    }

    func testStopAvulsoWithoutRecordingThrows() throws {
        let a = try AmbienteGravador()
        XCTAssertThrowsError(try a.recorder.stopAvulso { _, _ in })
    }
}
