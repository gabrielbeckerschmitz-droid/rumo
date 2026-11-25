import CryptoKit
import SwiftData
import XCTest
@testable import Rumo

// MARK: - Servidor falso da API do GitHub (só memória; nada de rede)

/// Imita o trecho da Contents API que o Rumo usa: PUT cria, GET lista pasta ou devolve o arquivo cru,
/// DELETE exige o sha. Pasta sem arquivos devolve 404, como o GitHub de verdade.
final class FakeGitHub: URLProtocol {
    enum Falha { case rede, status(Int) }

    private static let trava = NSLock()
    static var arquivos: [String: Data] = [:]
    static var putsEmOrdem: [String] = []
    static var numeroDePuts = 0
    static var cabecalhosDoUltimoPut: [String: String]?
    /// (método, caminho, nº do PUT) -> falha a simular nesta chamada.
    static var falha: ((String, String, Int) -> Falha?)?
    static var aoApagar: ((String) -> Void)?

    static func reiniciar() {
        trava.lock(); defer { trava.unlock() }
        arquivos = [:]; putsEmOrdem = []; numeroDePuts = 0; cabecalhosDoUltimoPut = nil; falha = nil; aoApagar = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private static func corpo(_ r: URLRequest) -> Data {
        if let b = r.httpBody { return b }
        guard let s = r.httpBodyStream else { return Data() }
        s.open(); defer { s.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65_536)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }

    override func startLoading() {
        let req = request
        let metodo = req.httpMethod ?? "GET"
        let caminho = String((req.url?.path ?? "").dropFirst("/repos/dono/caixa/contents/".count))
        let corpo = Self.corpo(req)
        Self.trava.lock()
        let (status, dados, caiu) = Self.responder(metodo, caminho, req, corpo)
        Self.trava.unlock()
        if caiu {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: dados)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func json(_ o: Any) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data() }

    private static func responder(_ metodo: String, _ caminho: String, _ req: URLRequest, _ corpo: Data) -> (Int, Data, Bool) {
        var n = 0
        if metodo == "PUT" { numeroDePuts += 1; n = numeroDePuts }
        switch falha?(metodo, caminho, n) {
        case .rede?: return (0, Data(), true)
        case .status(let s)?: return (s, json(["message": "falha simulada"]), false)
        case nil: break
        }
        let obj = (try? JSONSerialization.jsonObject(with: corpo)) as? [String: Any] ?? [:]
        switch metodo {
        case "PUT":
            guard let b64 = obj["content"] as? String, let dados = Data(base64Encoded: b64) else { return (422, Data(), false) }
            if arquivos[caminho] != nil && obj["sha"] == nil { return (422, json(["message": "sha wasn't supplied"]), false) }
            let novo = arquivos[caminho] == nil
            arquivos[caminho] = dados
            putsEmOrdem.append(caminho)
            cabecalhosDoUltimoPut = req.allHTTPHeaderFields
            return (novo ? 201 : 200, json([:]), false)
        case "DELETE":
            guard arquivos[caminho] != nil else { return (404, json(["message": "Not Found"]), false) }
            aoApagar?(caminho)
            arquivos[caminho] = nil
            return (200, json([:]), false)
        default:  // GET
            if let dados = arquivos[caminho] {
                return (200, (req.value(forHTTPHeaderField: "Accept") ?? "").contains("raw") ? dados : json(["path": caminho]), false)
            }
            let prefixo = caminho + "/"
            let nomes = arquivos.keys.filter { $0.hasPrefix(prefixo) && !$0.dropFirst(prefixo.count).contains("/") }.sorted()
            if nomes.isEmpty { return (404, json(["message": "Not Found"]), false) }
            return (200, json(nomes.map { ["path": $0, "sha": "sha-" + $0, "size": arquivos[$0]!.count, "type": "file"] as [String: Any] }), false)
        }
    }
}

// MARK: - Ambiente de teste

private let agora = Date(timeIntervalSince1970: 1_800_000_000)
private let chave = SymmetricKey(data: Data(repeating: 7, count: 32))
private let msgToken = "O token do GitHub venceu — gere um novo no PC (passo a passo no guia)."

@MainActor
struct Ambiente {
    let container: ModelContainer
    let ctx: ModelContext
    let tmp: URL
    let client: GitHubClient
    let sync: Sync

    init() throws {
        FakeGitHub.reiniciar()
        container = try ModelContainer(for: Item.self, Pedido.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        ctx = container.mainContext
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FakeGitHub.self]
        client = GitHubClient(token: "tok-teste", dono: "dono", repo: "caixa", session: URLSession(configuration: cfg))
        sync = Sync()
        sync.destinosURL = tmp.appendingPathComponent("destinos.json")
        sync.defaults = UserDefaults(suiteName: "rumo.testes.\(UUID().uuidString)")!
    }

    /// Item na fila com o arquivo cifrado em disco (como o Task B5 grava) ou com texto.
    @discardableResult
    func item(audio: Data? = nil, texto: String? = nil, estado: Estado = .gravado,
              criadoEm: Date = Date(timeIntervalSince1970: 1_799_990_000), duracaoS: Int = 42) throws -> Item {
        let i = Item(notaId: UUID(), cofre: "Cofre A", criadoEm: criadoEm, duracaoS: duracaoS, estado: estado)
        if let audio {
            let url = tmp.appendingPathComponent("\(i.notaId.uuidString).bin")
            try Crypto.seal(audio, key: chave).write(to: url)
            i.arquivoCifrado = url
        }
        i.texto = texto
        ctx.insert(i)
        try ctx.save()
        return i
    }

    func rodar(_ now: Date = agora) async -> SyncReport {
        await sync.run(store: ctx, client: client, chave: chave, now: now)
    }

    func inbox() -> [String] { FakeGitHub.arquivos.keys.filter { $0.hasPrefix("inbox/") }.sorted() }
    func outbox() -> [String] { FakeGitHub.arquivos.keys.filter { $0.hasPrefix("outbox/") }.sorted() }
    func abrir(_ caminho: String) throws -> Msg { try Msg.open(try XCTUnwrap(FakeGitHub.arquivos[caminho]), key: chave) }
    func colocar(_ msg: Msg, em caminho: String) throws { FakeGitHub.arquivos[caminho] = try msg.sealed(key: chave) }

    func resultado(_ nota: UUID, status: Resultado.Status = .processado, quando: Date, titulo: String = "Título") -> Msg {
        let r = Resultado(notaId: ID(nota), status: status, titulo: titulo, tipo: "ideia", resumo: "Resumo", cofre: "Cofre A",
                          clienteSugerido: nil, pontos: 2, emAberto: 1, erro: status == .erro ? "Falhou." : nil)
        return Msg(id: ID(UUID()), criadoEm: Instante(quando), corpo: .resultado(r))
    }
}

// MARK: - Testes

@MainActor
final class SyncTests: XCTestCase {
    func testUploadMarksEnviadoOn201() async throws {
        let a = try Ambiente()
        let audio = Data((0..<100).map { UInt8($0) })
        let i = try a.item(audio: audio)
        let rel = await a.rodar()

        XCTAssertEqual(i.estado, .enviado)
        XCTAssertEqual(i.enviadoEm, agora)
        XCTAssertEqual(rel.enviados, 1)
        let caminhos = a.inbox()
        XCTAssertEqual(caminhos.count, 1)
        XCTAssertEqual(i.caminhosInbox, caminhos)
        XCTAssertEqual(i.partesEnviadas, 1)
        XCTAssertNotNil(caminhos[0].range(of: #"^inbox/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.bin$"#, options: .regularExpression))

        let m = try a.abrir(caminhos[0])
        guard case .notaAudio(let n) = m.corpo else { return XCTFail("esperava nota_audio") }
        XCTAssertEqual(n.audio, audio)
        XCTAssertEqual(n.notaId.uuid, i.notaId)
        XCTAssertEqual(n.cofre, "Cofre A")
        XCTAssertEqual(n.duracaoS, 42)
        XCTAssertEqual(m.criadoEm.date, i.criadoEm)

        let h = try XCTUnwrap(FakeGitHub.cabecalhosDoUltimoPut)
        XCTAssertEqual(h["Authorization"], "Bearer tok-teste")
        XCTAssertEqual(h["Accept"], "application/vnd.github+json")
        XCTAssertEqual(h["X-GitHub-Api-Version"], "2022-11-28")
        XCTAssertEqual(h["User-Agent"], "rumo-ios")
    }

    func testSendsTextNote() async throws {
        let a = try Ambiente()
        let i = try a.item(texto: "ideia digitada")
        _ = await a.rodar()
        XCTAssertEqual(i.estado, .enviado)
        guard case .notaTexto(let n) = try a.abrir(try XCTUnwrap(a.inbox().first)).corpo else { return XCTFail("esperava nota_texto") }
        XCTAssertEqual(n.texto, "ideia digitada")
        XCTAssertEqual(n.notaId.uuid, i.notaId)
    }

    func testOfflineMarksAguardando() async throws {
        let a = try Ambiente()
        let i = try a.item(audio: Data(repeating: 1, count: 50))
        FakeGitHub.falha = { _, _, _ in .rede }
        let rel = await a.rodar()

        XCTAssertEqual(i.estado, .aguardandoInternet)
        XCTAssertEqual(i.tentativas, 1)
        XCTAssertEqual(i.proximaTentativa, agora.addingTimeInterval(Backoff.proxima(tentativas: 0)))
        XCTAssertTrue(rel.semInternet)
        XCTAssertNil(a.sync.ultimoErro)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(i.arquivoCifrado).path), "a gravação nunca sai do disco")

        FakeGitHub.falha = nil  // a internet volta: sai sozinha
        _ = await a.rodar(agora.addingTimeInterval(60))
        XCTAssertEqual(i.estado, .enviado)
        XCTAssertEqual(a.inbox().count, 1)
    }

    func testSplitsLargeAudio() async throws {
        let a = try Ambiente()
        a.sync.tamanhoParte = 10
        let audio = Data((0..<25).map { UInt8($0 &* 3) })
        let i = try a.item(audio: audio, duracaoS: 77)
        _ = await a.rodar()

        XCTAssertEqual(i.estado, .enviado)
        XCTAssertEqual(i.partesEnviadas, 3)
        XCTAssertEqual(i.caminhosInbox.count, 3)
        var partes: [NotaAudioParte] = []
        for c in a.inbox() {
            guard case .notaAudioParte(let p) = try a.abrir(c).corpo else { return XCTFail("esperava nota_audio_parte") }
            partes.append(p)
        }
        partes.sort { $0.parte < $1.parte }
        XCTAssertEqual(partes.map(\.parte), [1, 2, 3])
        XCTAssertTrue(partes.allSatisfy { $0.totalPartes == 3 && $0.notaId.uuid == i.notaId && $0.cofre == "Cofre A" })
        XCTAssertEqual(partes.map(\.audio.count), [10, 10, 5])
        XCTAssertEqual(partes.map(\.duracaoS), [77, nil, nil])
        XCTAssertEqual(partes.reduce(Data()) { $0 + $1.audio }, audio)
    }

    func testResumesAfterPartialUpload() async throws {
        let a = try Ambiente()
        a.sync.tamanhoParte = 10
        let audio = Data((0..<25).map { UInt8($0) })
        let i = try a.item(audio: audio)
        FakeGitHub.falha = { metodo, _, n in metodo == "PUT" && n == 2 ? .rede : nil }
        _ = await a.rodar()

        XCTAssertEqual(i.estado, .aguardandoInternet)
        XCTAssertEqual(i.partesEnviadas, 1)
        XCTAssertEqual(a.inbox().count, 1)

        FakeGitHub.falha = nil
        _ = await a.rodar(agora.addingTimeInterval(60))
        XCTAssertEqual(i.estado, .enviado)
        XCTAssertEqual(i.partesEnviadas, 3)
        XCTAssertEqual(a.inbox().count, 3, "a parte 1 não é enviada de novo")
        var partes: [NotaAudioParte] = []
        for c in a.inbox() {
            guard case .notaAudioParte(let p) = try a.abrir(c).corpo else { return XCTFail("esperava nota_audio_parte") }
            partes.append(p)
        }
        partes.sort { $0.parte < $1.parte }
        XCTAssertEqual(partes.map(\.parte), [1, 2, 3])
        XCTAssertEqual(partes.reduce(Data()) { $0 + $1.audio }, audio)
    }

    func testAppliesResultado() async throws {
        let a = try Ambiente()
        let i = try a.item(audio: Data(repeating: 2, count: 10), estado: .enviado)
        i.enviadoEm = agora.addingTimeInterval(-3600)
        i.caminhosInbox = ["inbox/ainda.bin"]
        FakeGitHub.arquivos["inbox/ainda.bin"] = Data([1])
        let quando = agora.addingTimeInterval(-600)
        try a.colocar(a.resultado(i.notaId, quando: quando), em: "outbox/r1.bin")

        // No instante do DELETE, o resultado já tem de estar salvo no banco (outro contexto lê do disco/store).
        let container = a.container
        var estadoNoDelete: Estado?
        FakeGitHub.aoApagar = { _ in
            estadoNoDelete = (try? ModelContext(container).fetch(FetchDescriptor<Item>()))?.first?.estado
        }
        let rel = await a.rodar()

        XCTAssertEqual(i.estado, .processado)
        XCTAssertEqual(i.titulo, "Título")
        XCTAssertEqual(i.processadoEm, quando)
        XCTAssertEqual(i.pontos, 2)
        XCTAssertEqual(rel.resultadosAplicados, 1)
        XCTAssertTrue(a.outbox().isEmpty, "o resultado é apagado da caixa depois de aplicado")
        XCTAssertEqual(estadoNoDelete, .processado, "só apaga depois de salvar")
    }

    func testInvalidBlobAndUnknownNotaAreDeleted() async throws {
        let a = try Ambiente()
        FakeGitHub.arquivos["outbox/ruim.bin"] = Data("lixo".utf8)
        try a.colocar(a.resultado(UUID(), quando: agora), em: "outbox/orfa.bin")
        _ = await a.rodar()
        XCTAssertTrue(a.outbox().isEmpty)
    }

    func test401ShowsTokenMessage() async throws {
        let a = try Ambiente()
        let i = try a.item(audio: Data(repeating: 3, count: 20))
        FakeGitHub.falha = { _, _, _ in .status(401) }
        let rel = await a.rodar()

        XCTAssertEqual(a.sync.ultimoErro, msgToken)
        XCTAssertEqual(rel.erro, msgToken)
        XCTAssertEqual(i.estado, .gravado, "token vencido não vira erro da gravação")
        XCTAssertNil(i.erroTexto)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(i.arquivoCifrado).path))

        FakeGitHub.falha = nil  // token renovado: envia
        _ = await a.rodar(agora.addingTimeInterval(60))
        XCTAssertEqual(i.estado, .enviado)
        XCTAssertNil(a.sync.ultimoErro)
    }

    func testDuplicateResultadoIdempotent() async throws {
        let a = try Ambiente()
        let i = try a.item(audio: Data(repeating: 4, count: 10), estado: .enviado)
        i.enviadoEm = agora.addingTimeInterval(-7200)
        i.caminhosInbox = ["inbox/ainda.bin"]
        FakeGitHub.arquivos["inbox/ainda.bin"] = Data([1])
        let t1 = agora.addingTimeInterval(-3600)
        try a.colocar(a.resultado(i.notaId, quando: t1), em: "outbox/a.bin")
        try a.colocar(a.resultado(i.notaId, quando: t1.addingTimeInterval(500)), em: "outbox/b.bin")
        try a.colocar(a.resultado(i.notaId, status: .erro, quando: t1.addingTimeInterval(900)), em: "outbox/c.bin")

        let rel = await a.rodar()
        XCTAssertEqual(rel.resultadosAplicados, 3)
        XCTAssertTrue(a.outbox().isEmpty)
        XCTAssertEqual(i.estado, .processado, "um erro repetido não rebaixa uma nota processada")
        XCTAssertEqual(i.processadoEm, t1, "repetição não reinicia a retenção")
        XCTAssertNil(i.erroTexto)
        XCTAssertEqual(try a.ctx.fetch(FetchDescriptor<Item>()).count, 1)

        try a.colocar(a.resultado(i.notaId, quando: t1.addingTimeInterval(5000)), em: "outbox/d.bin")
        _ = await a.rodar()
        XCTAssertEqual(i.processadoEm, t1)
        XCTAssertTrue(a.outbox().isEmpty)
    }

    func testResendAfter24hWhenMissing() async throws {
        let a = try Ambiente()
        let i = try a.item(audio: Data(repeating: 5, count: 30), estado: .enviado)
        i.enviadoEm = agora.addingTimeInterval(-25 * 3600)
        i.caminhosInbox = ["inbox/sumiu.bin"]
        i.partesEnviadas = 1
        let rel = await a.rodar()

        XCTAssertEqual(rel.reenviados, 1)
        XCTAssertEqual(i.estado, .enviado)
        XCTAssertEqual(i.enviadoEm, agora)
        XCTAssertEqual(a.inbox().count, 1)
        XCTAssertEqual(i.caminhosInbox, a.inbox())
        XCTAssertNotEqual(i.caminhosInbox, ["inbox/sumiu.bin"])
    }

    func testNoResendWhenStillInInboxOrTooRecent() async throws {
        let a = try Ambiente()
        let presente = try a.item(audio: Data(repeating: 6, count: 10), estado: .enviado)
        presente.enviadoEm = agora.addingTimeInterval(-25 * 3600)
        presente.caminhosInbox = ["inbox/ainda.bin"]
        FakeGitHub.arquivos["inbox/ainda.bin"] = Data([1])
        let recente = try a.item(audio: Data(repeating: 6, count: 10), estado: .enviado)
        recente.enviadoEm = agora.addingTimeInterval(-23 * 3600)
        recente.caminhosInbox = ["inbox/sumiu.bin"]
        let rel = await a.rodar()

        XCTAssertEqual(rel.reenviados, 0)
        XCTAssertEqual(a.inbox(), ["inbox/ainda.bin"])
        XCTAssertEqual(presente.enviadoEm, agora.addingTimeInterval(-25 * 3600))
        XCTAssertEqual(recente.enviadoEm, agora.addingTimeInterval(-23 * 3600))
    }

    func testDestinosSavedLocally() async throws {
        let a = try Ambiente()
        XCTAssertEqual(Destinos.carregarLocal(de: a.sync.destinosURL), [])
        let cofres = [Cofre(nome: "Cofre A", cliente: false), Cofre(nome: "Cofre B", cliente: true)]
        let d = Destinos(cofres: cofres, atualizadoEm: Instante(agora))
        try a.colocar(Msg(id: ID(UUID()), criadoEm: Instante(agora), corpo: .destinos(d)), em: "config/destinos.bin")
        _ = await a.rodar()
        XCTAssertEqual(Destinos.carregarLocal(de: a.sync.destinosURL), cofres)
        XCTAssertNotNil(FakeGitHub.arquivos["config/destinos.bin"], "o app só lê, nunca apaga os destinos")
    }

    func testRetentionDeletesAudioOnly() async throws {
        let a = try Ambiente()
        let dia: TimeInterval = 86_400
        func processado(_ idade: Double) throws -> Item {
            let i = try a.item(audio: Data(repeating: 8, count: 10), estado: .processado)
            i.processadoEm = agora.addingTimeInterval(-idade * dia)
            i.titulo = "Mantido"
            return i
        }
        let velho = try processado(31)
        let novo = try processado(29)
        let enviado = try a.item(audio: Data(repeating: 8, count: 10), estado: .enviado)
        enviado.enviadoEm = agora.addingTimeInterval(-100 * dia)
        enviado.caminhosInbox = ["inbox/ainda.bin"]
        FakeGitHub.arquivos["inbox/ainda.bin"] = Data([1])
        let arquivoVelho = try XCTUnwrap(velho.arquivoCifrado)

        let rel = await a.rodar()
        XCTAssertEqual(rel.audiosApagados, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: arquivoVelho.path))
        XCTAssertNil(velho.arquivoCifrado)
        XCTAssertEqual(velho.titulo, "Mantido", "o item continua no histórico")
        XCTAssertEqual(try a.ctx.fetch(FetchDescriptor<Item>()).count, 3)
        XCTAssertNotNil(novo.arquivoCifrado)
        XCTAssertNotNil(enviado.arquivoCifrado, "nunca apaga antes de processado")

        a.sync.defaults.set(7, forKey: "retencaoDias")  // retenção ajustável
        let rel2 = await a.rodar()
        XCTAssertEqual(rel2.audiosApagados, 1)
        XCTAssertNil(novo.arquivoCifrado)
        XCTAssertNotNil(enviado.arquivoCifrado)
    }

    func testPedidosSentInCreationOrder() async throws {
        let a = try Ambiente()
        func mover(_ destino: String, _ seg: Double) -> Msg {
            Msg(id: ID(UUID()), criadoEm: Instante(agora.addingTimeInterval(seg)), corpo: .mover(Mover(notaId: ID(UUID()), destino: destino)))
        }
        let segundo = try Pedido.novo(msg: mover("Cofre B", -10), chave: chave)
        let primeiro = try Pedido.novo(msg: mover("Cofre A", -20), chave: chave)
        a.ctx.insert(segundo); a.ctx.insert(primeiro)  // inseridos fora de ordem de propósito
        try a.ctx.save()

        let rel = await a.rodar()
        XCTAssertEqual(rel.pedidosEnviados, 2)
        XCTAssertTrue(primeiro.enviado && segundo.enviado)
        let destinos: [String] = try FakeGitHub.putsEmOrdem.map {
            guard case .mover(let m) = try a.abrir($0).corpo else { throw CryptoError() }
            return m.destino
        }
        XCTAssertEqual(destinos, ["Cofre A", "Cofre B"])

        _ = await a.rodar(agora.addingTimeInterval(60))
        XCTAssertEqual(FakeGitHub.putsEmOrdem.count, 2, "pedido já enviado não sai de novo")
    }

    func testClientBasics() async throws {
        let a = try Ambiente()
        let c = a.client
        let vazio = try await c.list("inbox")
        XCTAssertEqual(vazio, [])
        let existeAntes = try await c.exists("inbox/x.bin")
        XCTAssertFalse(existeAntes)
        try await c.put("inbox/x.bin", Data([1, 2, 3]))
        let lista = try await c.list("inbox")
        XCTAssertEqual(lista, [Entrada(path: "inbox/x.bin", sha: "sha-inbox/x.bin", size: 3)])
        let existeDepois = try await c.exists("inbox/x.bin")
        XCTAssertTrue(existeDepois)
        let lido = try await c.get("inbox/x.bin")
        XCTAssertEqual(lido, Data([1, 2, 3]))
        try await c.delete("inbox/x.bin", sha: "sha-inbox/x.bin")
        try await c.delete("inbox/x.bin", sha: "sha-inbox/x.bin")  // 404 é aceito
        XCTAssertTrue(a.inbox().isEmpty)

        FakeGitHub.falha = { _, _, _ in .status(401) }
        do { _ = try await c.list("inbox"); XCTFail("deveria falhar") } catch { XCTAssertEqual(error as? GitHubErro, .tokenVencido) }
        FakeGitHub.falha = { _, _, _ in .status(500) }
        do { _ = try await c.list("inbox"); XCTFail("deveria falhar") } catch { XCTAssertEqual(error as? GitHubErro, .github(500)) }
        FakeGitHub.falha = { _, _, _ in .rede }
        do { _ = try await c.list("inbox"); XCTFail("deveria falhar") } catch {
            XCTAssertEqual(error as? GitHubErro, .semConexao("Sem internet — a gravação está guardada e sai sozinha."))
        }
        XCTAssertEqual(GitHubErro.tokenVencido.errorDescription, msgToken)
    }

    func testRunIsNotReentrant() async throws {
        let a = try Ambiente()
        try a.item(audio: Data(repeating: 9, count: 10))
        async let primeiro = a.rodar()
        async let segundo = a.rodar()
        let (r1, r2) = await (primeiro, segundo)
        XCTAssertEqual(r1.enviados + r2.enviados, 1)
        XCTAssertEqual(a.inbox().count, 1, "duas chamadas juntas não duplicam o envio")
    }
}
