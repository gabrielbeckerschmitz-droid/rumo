import AVFoundation
import CryptoKit
import SwiftData
import XCTest
@testable import Rumo

/// Gera um CAF PCM 16 kHz mono 16 bits à mão (seno de 440 Hz).
/// `truncado: true` reproduz o que sobra quando o app é encerrado gravando: o tamanho do bloco "data" fica -1
/// (o gravador só o corrige ao fechar) e o arquivo termina onde parou.
enum CAFTeste {
    static func dados(segundos: Double, truncado: Bool) -> Data {
        let frames = Int(segundos * 16_000)
        var amostras = Data()
        for n in 0..<frames {
            let v = Int16(8_000 * sin(2 * Double.pi * 440 * Double(n) / 16_000))
            withUnsafeBytes(of: v.littleEndian) { amostras.append(contentsOf: $0) }
        }
        var d = Data("caff".utf8)
        func be<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        be(UInt16(1)); be(UInt16(0))
        d.append(Data("desc".utf8)); be(Int64(32))
        be((16_000.0 as Double).bitPattern)
        d.append(Data("lpcm".utf8))
        be(UInt32(2))  // little-endian, inteiro
        be(UInt32(2)); be(UInt32(1)); be(UInt32(1)); be(UInt32(16))
        d.append(Data("data".utf8)); be(truncado ? Int64(-1) : Int64(4 + amostras.count))
        be(UInt32(0))
        d.append(amostras)
        return d
    }

    /// Duração (s) de um .m4a (bytes) aberto com o AVFoundation de verdade.
    static func duracaoM4A(_ bytes: Data) throws -> Double {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let f = try AVAudioFile(forReading: url)
        return Double(f.length) / f.processingFormat.sampleRate
    }
}

/// Motor de áudio falso: escreve um CAF de verdade (sem microfone).
final class FakeEngine: AudioEngineProtocol {
    var tempo: TimeInterval = 2.4
    var potencia: Float = -25
    var falhaAoIniciar = false
    private(set) var url: URL?
    private(set) var iniciou = false
    private(set) var parou = false

    func start(url: URL) throws {
        if falhaAoIniciar {
            try Data([1, 2, 3]).write(to: url)  // arquivo parcial
            throw Recorder.Erro("microfone ocupado")
        }
        try CAFTeste.dados(segundos: tempo, truncado: false).write(to: url)
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

    var pasta: URL { base.appendingPathComponent("gravando") }
    func itens() throws -> [Item] { try ctx.fetch(FetchDescriptor<Item>()) }
    func fila(_ i: Item) throws -> URL { Fila.url(try XCTUnwrap(i.arquivoCifrado), base: base) }
    func m4a(_ i: Item) throws -> Data { try Crypto.open(Data(contentsOf: fila(i)), key: chaveTeste) }
    func interromper(_ tipo: AVAudioSession.InterruptionType) {
        centro.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: tipo.rawValue])
    }
    /// Deixa na pasta de temporários o que um app encerrado gravando deixaria.
    @discardableResult
    func sobra(id: UUID = UUID(), segundos: Double = 5, cofre: String? = nil, inicioGravacao: Date = inicio) throws -> UUID {
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        try CAFTeste.dados(segundos: segundos, truncado: true).write(to: pasta.appendingPathComponent("\(id.uuidString).caf"))
        if let cofre {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            try enc.encode(["cofre": cofre, "inicio": ISO8601DateFormatter().string(from: inicioGravacao)])
                .write(to: pasta.appendingPathComponent("\(id.uuidString).json"))
        }
        return id
    }
}

@MainActor
final class RecorderTests: XCTestCase {
    func testStopOrderEncryptsBeforeDeletingTemp() async throws {
        let a = try AmbienteGravador()
        try a.recorder.start(cofre: "Cofre A")
        let temp = try XCTUnwrap(a.engine.url)
        XCTAssertEqual(temp.pathExtension, "caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path))

        let item = try await a.recorder.stop()

        // ordem: fecha → converte → cifra → escreve a fila → salva o item → só então apaga o temporário → Sync
        XCTAssertEqual(a.passos.lista, ["fechou", "convertido", "cifrou", "fila", "item", "apagou", "sync"])
        XCTAssertEqual(a.passos.tempExiste, [true, true, true, true, true, false, false], "o temporário só some depois do item salvo")
        XCTAssertTrue(a.engine.parou)
        XCTAssertEqual(a.gatilhos.n, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: a.pasta.path), [], "CAF, .m4a e metadados apagados")

        XCTAssertEqual(item.estado, .gravado)
        XCTAssertEqual(item.cofre, "Cofre A")
        XCTAssertEqual(item.criadoEm, inicio)
        XCTAssertEqual(item.duracaoS, 2, "duração vem dos quadros do CAF")
        XCTAssertEqual(item.arquivoCifrado, Fila.caminhoRelativo(item.notaId))
        XCTAssertEqual(try a.itens().count, 1)

        let blob = try Data(contentsOf: a.fila(item))
        let m4a = try a.m4a(item)
        XCTAssertNotEqual(blob, m4a, "a fila nunca guarda o áudio em claro")
        XCTAssertEqual(try CAFTeste.duracaoM4A(m4a), 2.4, accuracy: 0.3, "o que o Sync lê é um .m4a que abre de verdade")
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
        XCTAssertEqual(try CAFTeste.duracaoM4A(Crypto.open(blob, key: chaveTeste)), 2.4, accuracy: 0.3)
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
        XCTAssertEqual(try CAFTeste.duracaoM4A(a.m4a(item)), 2.4, accuracy: 0.3)
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
        let original = try Data(contentsOf: temp)

        do {
            _ = try await a.recorder.stop()
            XCTFail("deveria falhar")
        } catch {
            XCTAssertEqual(error.localizedDescription, msgFalha)
        }
        XCTAssertEqual(try Data(contentsOf: temp), original, "o CAF continua intacto no aparelho")
        XCTAssertEqual(try a.itens().count, 0, "sem item sem fila")
        XCTAssertEqual(a.gatilhos.n, 0)
        XCTAssertFalse(a.passos.lista.contains("apagou"))
        XCTAssertFalse(a.recorder.gravando)

        // depois: o problema some e a recuperação guarda o que ficou
        try FileManager.default.removeItem(at: a.base.appendingPathComponent("fila"))
        let n = await a.recorder.recuperarPendentes()
        XCTAssertEqual(n, 1)
        let item = try XCTUnwrap(try a.itens().first)
        XCTAssertEqual(item.cofre, "Cofre A", "o cofre veio dos metadados gravados no start")
        XCTAssertEqual(try CAFTeste.duracaoM4A(a.m4a(item)), 2.4, accuracy: 0.3)
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

    func testEngineStartFailureCleansUp() throws {
        let a = try AmbienteGravador()
        a.engine.falhaAoIniciar = true
        XCTAssertThrowsError(try a.recorder.start(cofre: "Cofre A"))
        XCTAssertTrue(a.engine.parou, "a sessão de áudio é desativada")
        XCTAssertFalse(a.recorder.gravando)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: a.pasta.path), [], "sem arquivo parcial nem metadados")
    }

    func testTempFolderExcludedFromBackup() throws {
        let a = try AmbienteGravador()
        try a.recorder.start(cofre: "Cofre A")
        let v = try a.pasta.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(v.isExcludedFromBackup, true, "áudio em claro nunca vai para o backup")
    }

    // MARK: Recuperação

    func testRecuperarConverteCAFTruncadoComCofreDosMetadados() async throws {
        let a = try AmbienteGravador()
        let t1 = Date(timeIntervalSince1970: 1_700_000_000), t2 = Date(timeIntervalSince1970: 1_700_005_000)
        let idA = try a.sobra(segundos: 5, cofre: "Cofre A", inicioGravacao: t1)
        let idB = try a.sobra(segundos: 3, cofre: "Cofre B", inicioGravacao: t2)
        UserDefaults.standard.set("Cofre Z", forKey: Recorder.chaveUltimoCofre)  // não pode vazar para a recuperação

        let n = await a.recorder.recuperarPendentes()
        XCTAssertEqual(n, 2)
        XCTAssertEqual(a.gatilhos.n, 1)
        let itemA = try XCTUnwrap(try a.itens().first { $0.notaId == idA })
        let itemB = try XCTUnwrap(try a.itens().first { $0.notaId == idB })
        XCTAssertEqual(itemA.cofre, "Cofre A")
        XCTAssertEqual(itemB.cofre, "Cofre B")
        XCTAssertEqual(itemA.criadoEm.timeIntervalSince1970, t1.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(itemB.criadoEm.timeIntervalSince1970, t2.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(itemA.duracaoS, 5)
        XCTAssertEqual(itemB.duracaoS, 3)
        XCTAssertEqual(itemA.estado, .gravado)
        XCTAssertEqual(try CAFTeste.duracaoM4A(a.m4a(itemA)), 5, accuracy: 0.3, "CAF truncado virou .m4a decodificável")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: a.pasta.path), [], "temporários limpos")

        let outraVez = await a.recorder.recuperarPendentes()  // idempotente
        XCTAssertEqual(outraVez, 0)
        XCTAssertEqual(try a.itens().count, 2)
    }

    func testRecuperarSemMetadadosUsaUltimoCofre() async throws {
        let a = try AmbienteGravador()
        UserDefaults.standard.set("Cofre U", forKey: Recorder.chaveUltimoCofre)
        let id = try a.sobra(segundos: 2, cofre: nil)
        let n = await a.recorder.recuperarPendentes()
        XCTAssertEqual(n, 1)
        XCTAssertEqual(try XCTUnwrap(try a.itens().first { $0.notaId == id }).cofre, "Cofre U")
    }

    func testRecuperarLimpaOQueJaTemItemEOVazio() async throws {
        let a = try AmbienteGravador()
        let jaSalvo = UUID()
        a.ctx.insert(Item(notaId: jaSalvo, cofre: "Cofre A", criadoEm: inicio, duracaoS: 5, estado: .gravado))
        try a.ctx.save()
        try a.sobra(id: jaSalvo, segundos: 1, cofre: "Cofre A")  // caiu entre salvar e apagar
        let vazio = UUID()
        try Data().write(to: a.pasta.appendingPathComponent("\(vazio.uuidString).caf"))
        let orfaoM4A = UUID()  // .m4a/.json soltos, sem CAF
        try Data([1]).write(to: a.pasta.appendingPathComponent("\(orfaoM4A.uuidString).m4a"))

        let n = await a.recorder.recuperarPendentes()
        XCTAssertEqual(n, 0)
        XCTAssertEqual(try a.itens().count, 1, "sem duplicar")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: a.pasta.path), [])
    }

    func testRecuperarIgnoraGravacaoEmAndamentoMesmoComOutroCaminho() async throws {
        let a = try AmbienteGravador()
        try a.recorder.start(cofre: "Cofre A")
        let caf = try XCTUnwrap(a.engine.url)

        // a mesma pasta por outro caminho (como /var x /private/var): a comparação é pelo UUID, não pela URL
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a.base)
        a.recorder.base = link

        let n = await a.recorder.recuperarPendentes()
        XCTAssertEqual(n, 0)
        XCTAssertTrue(a.recorder.gravando)
        XCTAssertTrue(FileManager.default.fileExists(atPath: caf.path))
        XCTAssertEqual(try a.itens().count, 0)
    }

    func testStopRunsRecoveryOfLeftovers() async throws {
        let a = try AmbienteGravador()
        try a.sobra(segundos: 2, cofre: "Cofre B")
        try a.recorder.start(cofre: "Cofre A")
        _ = try await a.recorder.stop()
        XCTAssertEqual(try a.itens().count, 2, "o stop também guarda o que sobrou de antes")
        XCTAssertEqual(Set(try a.itens().map(\.cofre)), ["Cofre A", "Cofre B"])
    }

    func testStopWithNothingRecordedReportsEmpty() async throws {
        let a = try AmbienteGravador()
        a.engine.tempo = 0
        try a.recorder.start(cofre: "Cofre A")
        do { _ = try await a.recorder.stop(); XCTFail("deveria falhar") } catch {
            XCTAssertEqual(error.localizedDescription, Recorder.msgVazia)
        }
        XCTAssertEqual(try a.itens().count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: a.pasta.path), [])
    }

    // MARK: Conversão e motor real

    func testConversorConvertePCMEmAAC() throws {
        let tmp = FileManager.default.temporaryDirectory
        let caf = tmp.appendingPathComponent("\(UUID().uuidString).caf")
        let m4a = tmp.appendingPathComponent("\(UUID().uuidString).m4a")
        try CAFTeste.dados(segundos: 3, truncado: false).write(to: caf)
        XCTAssertEqual(try Conversor.caf(caf, paraM4A: m4a), 3)
        let f = try AVAudioFile(forReading: m4a)
        XCTAssertEqual(Double(f.length) / f.processingFormat.sampleRate, 3, accuracy: 0.3)
        XCTAssertEqual(f.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(f.fileFormat.channelCount, 1)
    }

    func testConversorLeCAFTruncadoSemTamanhoNoCabecalho() throws {
        let tmp = FileManager.default.temporaryDirectory
        let caf = tmp.appendingPathComponent("\(UUID().uuidString).caf")
        let m4a = tmp.appendingPathComponent("\(UUID().uuidString).m4a")
        try CAFTeste.dados(segundos: 4, truncado: true).write(to: caf)
        XCTAssertEqual(try Conversor.caf(caf, paraM4A: m4a), 4)
        let f = try AVAudioFile(forReading: m4a)
        XCTAssertEqual(Double(f.length) / f.processingFormat.sampleRate, 4, accuracy: 0.3)
    }

    func testRealEngineRecordsCrashTolerantPCM() {
        let s = AVAudioEngineRecorder.configuracoes
        XCTAssertEqual(s[AVFormatIDKey] as? Int, Int(kAudioFormatLinearPCM))
        XCTAssertEqual(s[AVSampleRateKey] as? Int, 16_000)
        XCTAssertEqual(s[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(s[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(s[AVLinearPCMIsFloatKey] as? Bool, false)
        XCTAssertEqual(s[AVLinearPCMIsBigEndianKey] as? Bool, false)
        XCTAssertEqual(Conversor.saida[AVFormatIDKey] as? Int, Int(kAudioFormatMPEG4AAC))
        XCTAssertEqual(Conversor.saida[AVEncoderBitRateKey] as? Int, 24_000)
        XCTAssertEqual(Conversor.saida[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(Conversor.saida[AVSampleRateKey] as? Int, 16_000)
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
