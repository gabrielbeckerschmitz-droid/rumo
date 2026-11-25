import AVFoundation
import CryptoKit
import Foundation
import SwiftData

/// Motor de áudio (abstração para os testes). A implementação real usa `AVAudioRecorder`.
protocol AudioEngineProtocol: AnyObject {
    func start(url: URL) throws
    func stop()
    /// Potência média em dB (-160…0).
    func averagePower() -> Float
    var currentTime: TimeInterval { get }
}

/// `AVAudioRecorder` gravando PCM 16 kHz mono 16 bits em .caf: o CAF não depende de índice no fim do arquivo,
/// então sobrevive a o app ser encerrado no meio da gravação (o AAC/.m4a perderia tudo). A conversão para AAC
/// acontece depois, em `Conversor`. Sessão `.playAndRecord` (segue com a tela bloqueada, modo de fundo "audio").
final class AVAudioEngineRecorder: AudioEngineProtocol {
    private var recorder: AVAudioRecorder?

    static let configuracoes: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    /// Pede acesso ao microfone (chame antes do primeiro `start`).
    static func pedirPermissao() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(url: URL) throws {
        if AVAudioApplication.shared.recordPermission == .denied {
            throw Recorder.Erro("O Rumo não tem acesso ao microfone. Libere em Ajustes > Rumo > Microfone.")
        }
        let sessao = AVAudioSession.sharedInstance()
        do {
            try sessao.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetooth, .defaultToSpeaker])
            try sessao.setActive(true)
            let r = try AVAudioRecorder(url: url, settings: Self.configuracoes)
            r.isMeteringEnabled = true
            guard r.prepareToRecord(), r.record() else {
                throw Recorder.Erro("Não consegui começar a gravar. Feche outros apps que usam o microfone e tente de novo.")
            }
            recorder = r
        } catch {
            recorder = nil
            try? sessao.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    func stop() {
        recorder?.stop()  // fecha o arquivo
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func averagePower() -> Float {
        guard let recorder else { return -160 }
        recorder.updateMeters()
        return recorder.averagePower(forChannel: 0)
    }

    var currentTime: TimeInterval { recorder?.currentTime ?? 0 }
}

/// Converte o CAF (PCM) em .m4a (AAC mono 16 kHz 24 kbps) em blocos, sem carregar tudo na memória.
enum Conversor {
    struct SemAudio: Error {}

    static let saida: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 24_000,
    ]

    /// Devolve a duração em segundos, contada pelos quadros realmente lidos (um CAF truncado também funciona).
    @discardableResult
    static func caf(_ origem: URL, paraM4A destino: URL) throws -> Int {
        try? FileManager.default.removeItem(at: destino)
        let entrada = try AVAudioFile(forReading: origem)
        let formato = entrada.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: formato, frameCapacity: 16_384) else { throw SemAudio() }
        var total: AVAudioFramePosition = 0
        do {
            // O arquivo de saída só é finalizado quando o objeto some: por isso fica dentro deste bloco.
            let arquivo = try AVAudioFile(forWriting: destino, settings: saida,
                                          commonFormat: formato.commonFormat, interleaved: formato.isInterleaved)
            while true {
                buffer.frameLength = 0
                do { try entrada.read(into: buffer) } catch { break }  // fim do arquivo
                if buffer.frameLength == 0 { break }
                try arquivo.write(from: buffer)
                total += AVAudioFramePosition(buffer.frameLength)
            }
        }
        guard total > 0 else { throw SemAudio() }
        return Int((Double(total) / formato.sampleRate).rounded())
    }
}

/// Grava uma ideia e a guarda CIFRADA no aparelho antes de qualquer outra coisa. Nada se perde:
/// o CAF temporário só é apagado depois da fila cifrada escrita e do `Item` salvo; se algo falhar,
/// ele fica e `recuperarPendentes()` guarda na próxima chance.
@MainActor
final class Recorder: ObservableObject {
    struct Erro: Error, LocalizedError, Equatable {
        let errorDescription: String?
        init(_ texto: String) { errorDescription = texto }
    }

    static let msgSemPareamento = "Leia o QR Code no PC antes de gravar."
    static let msgFalhaAoGuardar = "Não consegui guardar a gravação — ela continua salva no aparelho e vou tentar de novo."
    static let msgVazia = "Não gravei nada. Toque de novo para gravar."

    @Published private(set) var nivel: Float = 0  // 0…1
    @Published private(set) var decorrido: TimeInterval = 0
    @Published private(set) var gravando = false
    /// Último item criado por `stop()` ou por uma interrupção (a UI observa para mostrar o resultado).
    @Published private(set) var ultimoItem: Item?
    /// Erro de uma parada automática (interrupção), para a UI avisar.
    @Published private(set) var ultimoErro: String?

    /// Pasta-base (Application Support). `nil` = a do container atual. Troque só em testes.
    var base: URL?
    /// Dispara a sincronização depois de guardar.
    var gatilhoSync: () -> Void = { Task { @MainActor in await Sync.shared.run() } }
    /// Gancho de teste: nome de cada passo do `stop()`.
    var registrarPasso: (String) -> Void = { _ in }
    /// Tarefa da última interrupção tratada (os testes aguardam por ela).
    var tarefaInterrupcao: Task<Void, Never>? { caixa.tarefa }
    private let caixa = CaixaTarefa()
    private final class CaixaTarefa: @unchecked Sendable {
        private let trava = NSLock()
        private var _tarefa: Task<Void, Never>?
        var tarefa: Task<Void, Never>? {
            get { trava.lock(); defer { trava.unlock() }; return _tarefa }
            set { trava.lock(); _tarefa = newValue; trava.unlock() }
        }
    }
    /// Conveniência para a UI ("último cofre usado"); na recuperação só vale se o arquivo de metadados faltar.
    static let chaveUltimoCofre = "rumo.ultimoCofre"

    private let engine: AudioEngineProtocol
    private let contextoFixo: ModelContext?
    private let centro: NotificationCenter
    private let chave: () -> SymmetricKey?
    private let agora: () -> Date
    private var observador: NSObjectProtocol?
    private var timer: Timer?

    /// Metadados ao lado do áudio (`<uuid>.json`), para recuperar com o cofre e a hora certos.
    private struct Meta: Codable { var cofre: String; var inicio: Date }
    private struct Sessao { let notaId: UUID; let url: URL; let cofre: String; let inicio: Date }
    private var sessao: Sessao?

    init(engine: AudioEngineProtocol,
         contexto: ModelContext? = nil,
         base: URL? = nil,
         centro: NotificationCenter = .default,
         chave: @escaping () -> SymmetricKey? = { Keychain.load().map { SymmetricKey(data: $0.chave) } },
         agora: @escaping () -> Date = { Date() }) {
        self.engine = engine
        self.contextoFixo = contexto
        self.base = base
        self.centro = centro
        self.chave = chave
        self.agora = agora
        let caixa = self.caixa
        observador = centro.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] nota in
            guard let bruto = nota.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: bruto) == .began else { return }
            caixa.tarefa = Task { @MainActor in await self?.aoInterromper() }
        }
    }

    deinit {
        if let observador { centro.removeObserver(observador) }
    }

    private func raiz() throws -> URL { try base ?? Fila.baseURL() }

    /// Temporários da gravação em andamento (CAF + metadados + .m4a intermediário). Fica em Application Support
    /// (e não em tmp/Caches) para o sistema não apagar uma gravação sobrada, e fora do backup (áudio em claro).
    func pastaTemporarios() throws -> URL { try raiz().appendingPathComponent("gravando") }

    /// 0…1 a partir de dB: -50 dB → 0, 0 dB → 1.
    static func nivel(db: Float) -> Float { min(1, max(0, (db + 50) / 50)) }

    private static func protegido() -> [FileAttributeKey: Any] {
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    }

    private func preparar(pasta: URL) throws {
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true, attributes: Self.protegido())
        Destinos.excluirDoBackup(pasta)
    }

    private func caminho(_ pasta: URL, _ id: UUID, _ ext: String) -> URL {
        pasta.appendingPathComponent("\(id.uuidString).\(ext)")
    }

    // MARK: Gravar

    func start(cofre: String) throws {
        guard !gravando else { throw Erro("Já estou gravando.") }
        guard chave() != nil else { throw Erro(Self.msgSemPareamento) }
        let pasta = try pastaTemporarios()
        try preparar(pasta: pasta)
        let id = UUID()
        let url = caminho(pasta, id, "caf")
        let inicio = agora()
        let json = caminho(pasta, id, "json")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(Meta(cofre: cofre, inicio: inicio))
            .write(to: json, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        do { try engine.start(url: url) } catch {
            engine.stop()  // desativa a sessão
            try? FileManager.default.removeItem(at: url)  // arquivo parcial
            try? FileManager.default.removeItem(at: json)
            throw error
        }
        try? FileManager.default.setAttributes(Self.protegido(), ofItemAtPath: url.path)
        UserDefaults.standard.set(cofre, forKey: Self.chaveUltimoCofre)
        sessao = Sessao(notaId: id, url: url, cofre: cofre, inicio: inicio)
        ultimoItem = nil
        ultimoErro = nil
        nivel = 0
        decorrido = 0
        gravando = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.atualizarMedidas() }
        }
    }

    func atualizarMedidas() {
        guard gravando else { return }
        nivel = Self.nivel(db: engine.averagePower())
        decorrido = engine.currentTime
    }

    // MARK: Parar

    @discardableResult
    func stop() async throws -> Item {
        let item = try finalizar()
        await recuperarPendentes()  // aproveita para guardar algo que tenha sobrado de antes
        return item
    }

    private func aoInterromper() async {
        guard gravando else { return }
        do { _ = try finalizar() } catch { ultimoErro = error.localizedDescription }
        await recuperarPendentes()
    }

    /// Ordem: fecha o arquivo → converte → cifra → escreve a fila → cria o Item e salva → apaga o temporário → Sync.
    private func finalizar() throws -> Item {
        guard let s = sessao else { throw Erro("Não há gravação em andamento.") }
        timer?.invalidate()
        timer = nil
        engine.stop()
        registrarPasso("fechou")
        sessao = nil
        gravando = false
        nivel = 0
        let item = try guardar(caf: s.url, notaId: s.notaId, cofre: s.cofre, criadoEm: s.inicio)
        ultimoItem = item
        gatilhoSync()
        registrarPasso("sync")
        return item
    }

    private func limpar(_ pasta: URL, _ id: UUID) {
        let fm = FileManager.default
        try? fm.removeItem(at: caminho(pasta, id, "m4a"))
        try? fm.removeItem(at: caminho(pasta, id, "json"))
        try? fm.removeItem(at: caminho(pasta, id, "caf"))  // por último: enquanto existir, a recuperação enxerga a gravação
    }

    /// Converte o CAF, cifra para a fila, cria o Item e só então apaga os temporários. Em qualquer falha, o CAF fica.
    private func guardar(caf: URL, notaId: UUID, cofre: String, criadoEm: Date) throws -> Item {
        let fm = FileManager.default
        let pasta = caf.deletingLastPathComponent()
        do {
            guard let k = chave() else { throw Erro(Self.msgSemPareamento) }
            let m4a = caminho(pasta, notaId, "m4a")
            let frames: Int
            do { frames = try Conversor.caf(caf, paraM4A: m4a) } catch is Conversor.SemAudio { frames = 0 }
            if frames == 0 { limpar(pasta, notaId); throw Erro(Self.msgVazia) }  // nada gravado: não há o que perder
            registrarPasso("convertido")
            let duracaoS = frames  // contada pelos quadros lidos; vale também para o CAF truncado
            let blob = try Crypto.seal(try Data(contentsOf: m4a), key: k)
            registrarPasso("cifrou")

            let destino = try raiz().appendingPathComponent("fila")
            try fm.createDirectory(at: destino, withIntermediateDirectories: true, attributes: Self.protegido())
            let relativo = Fila.caminhoRelativo(notaId)
            // completeUntilFirstUserAuthentication (não .complete): o sync em segundo plano lê com o telefone bloqueado.
            try blob.write(to: Fila.url(relativo, base: try raiz()), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            registrarPasso("fila")

            guard let ctx = contextoFixo ?? Sync.shared.contexto else { throw Erro("Banco de dados indisponível.") }
            let item = Item(notaId: notaId, cofre: cofre, criadoEm: criadoEm, duracaoS: duracaoS, estado: .gravado)
            item.arquivoCifrado = relativo
            ctx.insert(item)
            do { try ctx.save() } catch { ctx.delete(item); throw error }
            registrarPasso("item")

            limpar(pasta, notaId)
            registrarPasso("apagou")
            return item
        } catch let e as Erro where e == Erro(Self.msgVazia) {
            throw e
        } catch {
            throw Erro(Self.msgFalhaAoGuardar)
        }
    }

    // MARK: Recuperação

    /// Chame ao abrir o app e depois de cada gravação: todo `.caf` que sobrou (app encerrado gravando,
    /// ou falha ao guardar) vira Item. Devolve quantas gravações foram recuperadas.
    @discardableResult
    func recuperarPendentes() async -> Int {
        let fm = FileManager.default
        guard let pasta = try? pastaTemporarios(),
              let arquivos = try? fm.contentsOfDirectory(at: pasta, includingPropertiesForKeys: nil),
              let ctx = contextoFixo ?? Sync.shared.contexto else { return 0 }
        let existentes = Set(((try? ctx.fetch(FetchDescriptor<Item>())) ?? []).map(\.notaId))
        func id(_ u: URL) -> UUID? { UUID(uuidString: u.deletingPathExtension().lastPathComponent) }
        let comCaf = Set(arquivos.filter { $0.pathExtension == "caf" }.compactMap(id))
        for u in arquivos where u.pathExtension != "caf" {  // .m4a/.json sem o CAF: sobra de uma limpeza interrompida
            if let i = id(u), !comCaf.contains(i) { try? fm.removeItem(at: u) }
        }
        var recuperados = 0
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        for caf in arquivos where caf.pathExtension == "caf" {
            guard let notaId = id(caf) else { continue }
            if let s = sessao, s.notaId == notaId { continue }  // gravação em andamento (compara UUID, não o caminho)
            if existentes.contains(notaId) { limpar(pasta, notaId); continue }  // caiu entre salvar e apagar
            let atributos = try? fm.attributesOfItem(atPath: caf.path)
            if ((atributos?[.size] as? NSNumber)?.intValue ?? 0) == 0 { limpar(pasta, notaId); continue }
            let meta = (try? Data(contentsOf: caminho(pasta, notaId, "json"))).flatMap { try? dec.decode(Meta.self, from: $0) }
            let inicio = meta?.inicio ?? (atributos?[.creationDate] as? Date) ?? agora()
            let cofre = meta?.cofre ?? UserDefaults.standard.string(forKey: Self.chaveUltimoCofre) ?? ""
            if (try? guardar(caf: caf, notaId: notaId, cofre: cofre, criadoEm: inicio)) != nil { recuperados += 1 }
        }
        if recuperados > 0 { gatilhoSync() }
        return recuperados
    }
}
