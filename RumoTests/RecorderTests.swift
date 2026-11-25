import AVFoundation
import CryptoKit
import SwiftData
import XCTest
@testable import Rumo

/// Motor de áudio falso: grava bytes aleatórios no arquivo, sem microfone.
final class FakeEngine: AudioEngineProtocol {
    var bytes = Data((0..<2_000).map { _ in UInt8.random(in: 0...255) })
    var potencia: Float = -25
    var tempo: TimeInterval = 12.4
    private(set) var url: URL?
    private(set) var iniciou = false
    private(set) var parou = false

    func start(url: URL) throws {
        try bytes.write(to: url)
        self.url = url
        iniciou = true
    }
    func stop() { parou = true }
    func averagePower() -> Float { potencia }
    var currentTime: TimeInterval { tempo }
}

private let chaveTeste = SymmetricKey(data: Data(repeating: 9, count: 32))
private let inicio = Date(timeIntervalSince1970: 1_800_000_000)
private let msgFalha = "Não consegui guardar a gravação — ela continua salva no aparelho e vou tentar de novo."

@MainActor
struct AmbienteGravador {
    let container: ModelContainer
    let ctx: ModelContext
    let base: URL
    let engine = FakeEngine()
    let recorder: Recorder
    let centro = NotificationCenter()
    let gatilhos = Contador()
    let passos = Passos()

    final class Contador { var n = 0 }
    final class Passos { var lista: [String] = []; var tempExiste: [Bool] = [] }

    init(comChave: Bool = true) throws {
        container = try ModelContainer(for: Item.self, Pedido.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        ctx = container.mainContext
        base = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        recorder = Recorder(engine: engine, contexto: ctx, base: base, centro: centro,
                            chave: { comChave ? chaveTeste : nil }, agora: { inicio })
        let g = gatilhos, p = passos, e = engine
        recorder.gatilhoSync = { g.n += 1 }
        recorder.registrarPasso = { nome in
            p.lista.append(nome)
            if let u = e.url { p.tempExiste.append(FileManager.default.fileExists(atPath: u.path)) }
        }
    }

    func itens() throws -> [Item] { try ctx.fetch(FetchDescriptor<Item>()) }
    func fila(_ i: Item) throws -> URL { Fila.url(try XCTUnwrap(i.arquivoCifrado), base: base) }
    func interromper(_ tipo: AVAudioSession.InterruptionType) {
        centro.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: tipo.rawValue])
    }
}

@MainActor
final class RecorderTests: XCTestCase {
    func testStopOrderEncryptsBeforeDeletingTemp() async throws {
        let a = try AmbienteGravador()
        try a.recorder.start(cofre: "Cofre A")
        let temp = try XCTUnwrap(a.engine.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path))

        let item = try await a.recorder.stop()

        // ordem: fecha → cifra → escreve a fila → salva o item → só então apaga o temporário → Sync
        XCTAssertEqual(a.passos.lista, ["fechou", "cifrou", "fila", "item", "apagou", "sync"])
        XCTAssertEqual(a.passos.tempExiste, [true, true, true, true, false, false], "o temporário só some depois do item salvo")
        XCTAssertTrue(a.engine.parou)
        XCTAssertEqual(a.gatilhos.n, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))

        XCTAssertEqual(item.estado, .gravado)
        XCTAssertEqual(item.cofre, "Cofre A")
        XCTAssertEqual(item.criadoEm, inicio)
        XCTAssertEqual(item.duracaoS, 12)
        XCTAssertEqual(item.arquivoCifrado, Fila.caminhoRelativo(item.notaId))
        XCTAssertEqual(try a.itens().count, 1)

        let blob = try Data(contentsOf: a.fila(item))
        XCTAssertNotEqual(blob, a.engine.bytes, "a fila nunca guarda o áudio em claro")
        XCTAssertEqual(try Crypto.open(blob, key: chaveTeste), a.engine.bytes, "mesmo formato que o Sync lê")
        XCTAssertFalse(a.recorder.gravando)
    }

    func testRelativePathResolvesAgainstCurrentContainer() async throws {
        let a = try AmbienteGravador()
        try a.recorder.start(cofre: "Cofre A")
        let item = try await a.recorder.stop()
        let rel = try XCTUnwrap(item.arquivoCifrado)
        XCTAssertFalse(rel.hasPrefix("/"))
        XCTAssertFalse(rel.contains(a.base.path), "nada de caminho absoluto do container")
        XCTAssertEqual(rel, "fila/\(item.notaId.uuidString).bin")

        // o container "muda" (atualização/reinstalação): a mesma pasta num novo endereço
        let novaBase = FileManager.default.temporaryDirectory.appendingPathComponent("rec-novo-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: a.base, to: novaBase)
        let blob = try Data(contentsOf: Fila.url(rel, base: novaBase))
        XCTAssertEqual(try Crypto.open(blob, key: chaveTeste), a.engine.bytes)
    }

    func testInterruptionSavesPartial() async throws {
        let a = try AmbienteGravador()
        try a.recorder.start(cofre: "Cofre A")
        let temp = try XCTUnwrap(a.engine.url)

        a.interromper(.began)  // ligação chegou
        await a.recorder.tarefaInterrupcao?.value

        let itens = try a.itens()
        XCTAssertEqual(itens.count, 1, "o que foi gravado até a ligação fica salvo")
        let item = try XCTUnwrap(itens.first)
        XCTAssertEqual(item.estado, .gravado)
        XCTAssertEqual(try Crypto.open(Data(contentsOf: a.fila(item)), key: chaveTeste), a.engine.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        XCTAssertFalse(a.recorder.gravando)
        XCTAssertTrue(a.engine.parou)
        XCTAssertEqual(a.gatilhos.n, 1)
        XCTAssertTrue(a.recorder.ultimoItem === item)
    }

    func testInterruptionEndedAndWhenIdleDoNothing() async throws {
        let a = try AmbienteGravador()
        a.interromper(.began)  // sem gravar: nada acontece
        await a.recorder.tarefaInterrupcao?.value
        XCTAssertEqual(try a.itens().count, 0)

        try a.recorder.start(cofre: "Cofre A")
        a.interromper(.ended)  // fim da ligação não cria nada nem para a gravação
        await a.recorder.tarefaInterrupcao?.value
        XCTAssertTrue(a.recorder.gravando)
        XCTAssertEqual(try a.itens().count, 0)
    }

    func testFailureToEncryptKeepsTemp() async throws {
        let a = try AmbienteGravador()
        // a pasta da fila não pode ser criada: já existe um ARQUIVO no lugar dela
        try Data([1]).write(to: a.base.appendingPathComponent("fila"))
        try a.recorder.start(cofre: "Cofre A")
        let temp = try XCTUnwrap(a.engine.url)

        do {
            _ = try await a.recorder.stop()
            XCTFail("deveria falhar")
        } catch {
            XCTAssertEqual(error.localizedDescription, msgFalha)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path), "o temporário continua no aparelho")
        XCTAssertEqual(try Data(contentsOf: temp), a.engine.bytes)
        XCTAssertEqual(try a.itens().count, 0, "sem item sem fila")
        XCTAssertEqual(a.gatilhos.n, 0)
        XCTAssertFalse(a.passos.lista.contains("apagou"))
        XCTAssertFalse(a.recorder.gravando)

        // depois: o problema some e a recuperação guarda o que ficou
        try FileManager.default.removeItem(at: a.base.appendingPathComponent("fila"))
        let n = await a.recorder.recuperarPendentes()
        XCTAssertEqual(n, 1)
        let item = try XCTUnwrap(try a.itens().first)
        XCTAssertEqual(try Crypto.open(Data(contentsOf: a.fila(item)), key: chaveTeste), a.engine.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }

    func testStartWithoutPairingRefuses() throws {
        let a = try AmbienteGravador(comChave: false)
        XCTAssertThrowsError(try a.recorder.start(cofre: "Cofre A")) { erro in
            XCTAssertEqual(erro.localizedDescription, "Leia o QR Code no PC antes de gravar.")
        }
        XCTAssertFalse(a.engine.iniciou)
        XCTAssertFalse(a.recorder.gravando)
    }

    func testStartTwiceRefuses() throws {
        let a = try AmbienteGravador()
        try a.recorder.start(cofre: "Cofre A")
        XCTAssertThrowsError(try a.recorder.start(cofre: "Cofre A"))
        XCTAssertTrue(a.recorder.gravando)
    }

    func testRecuperarPendentes() async throws {
        let a = try AmbienteGravador()
        let pasta = a.recorder.pastaTemporarios
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)

        let orfao = UUID()
        let bytes = Data((0..<500).map { _ in UInt8.random(in: 0...255) })
        try bytes.write(to: pasta.appendingPathComponent("\(orfao.uuidString).m4a"))

        // já tem Item (caiu entre salvar e apagar): só limpa, sem duplicar
        let jaSalvo = UUID()
        let existente = Item(notaId: jaSalvo, cofre: "Cofre A", criadoEm: inicio, duracaoS: 5, estado: .gravado)
        a.ctx.insert(existente)
        try a.ctx.save()
        try Data([1, 2, 3]).write(to: pasta.appendingPathComponent("\(jaSalvo.uuidString).m4a"))

        // vazio: nada a salvar
        try Data().write(to: pasta.appendingPathComponent("\(UUID().uuidString).m4a"))

        let n = await a.recorder.recuperarPendentes()
        XCTAssertEqual(n, 1)
        XCTAssertEqual(try a.itens().count, 2)
        let novo = try XCTUnwrap(try a.itens().first { $0.notaId == orfao })
        XCTAssertEqual(novo.estado, .gravado)
        XCTAssertEqual(novo.arquivoCifrado, "fila/\(orfao.uuidString).bin")
        XCTAssertEqual(try Crypto.open(Data(contentsOf: a.fila(novo)), key: chaveTeste), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pasta.path), [], "temporários limpos")
        XCTAssertEqual(a.gatilhos.n, 1)

        let outraVez = await a.recorder.recuperarPendentes()  // idempotente
        XCTAssertEqual(outraVez, 0)
        XCTAssertEqual(try a.itens().count, 2)
    }

    func testRecuperarIgnoraGravacaoEmAndamento() async throws {
        let a = try AmbienteGravador()
        try a.recorder.start(cofre: "Cofre A")
        let n = await a.recorder.recuperarPendentes()
        XCTAssertEqual(n, 0)
        XCTAssertTrue(a.recorder.gravando)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(a.engine.url).path))
    }

    func testLevelMappingAndMeters() throws {
        XCTAssertEqual(Recorder.nivel(db: -50), 0)
        XCTAssertEqual(Recorder.nivel(db: -80), 0)
        XCTAssertEqual(Recorder.nivel(db: -160), 0)
        XCTAssertEqual(Recorder.nivel(db: 0), 1)
        XCTAssertEqual(Recorder.nivel(db: 6), 1)
        XCTAssertEqual(Recorder.nivel(db: -25), 0.5, accuracy: 0.0001)

        let a = try AmbienteGravador()
        try a.recorder.start(cofre: "Cofre A")
        a.engine.potencia = -10
        a.engine.tempo = 3.5
        a.recorder.atualizarMedidas()
        XCTAssertEqual(a.recorder.nivel, 0.8, accuracy: 0.0001)
        XCTAssertEqual(a.recorder.decorrido, 3.5, accuracy: 0.0001)
    }

    func testStopWithoutRecordingThrows() async throws {
        let a = try AmbienteGravador()
        do { _ = try await a.recorder.stop(); XCTFail("deveria falhar") } catch {
            XCTAssertEqual(error.localizedDescription, "Não há gravação em andamento.")
        }
    }
}
