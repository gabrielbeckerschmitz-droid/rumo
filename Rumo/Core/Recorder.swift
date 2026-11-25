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

/// `AVAudioRecorder`: AAC, mono, 16 kHz, 24 kbps, com medição de nível.
/// Sessão `.playAndRecord` (continua com a tela bloqueada, graças ao modo de fundo "audio").
final class AVAudioEngineRecorder: AudioEngineProtocol {
    private var recorder: AVAudioRecorder?

    static let configuracoes: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVNumberOfChannelsKey: 1,
        AVSampleRateKey: 16_000,
        AVEncoderBitRateKey: 24_000,
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
        try sessao.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetooth, .defaultToSpeaker])
        try sessao.setActive(true)
        let r = try AVAudioRecorder(url: url, settings: Self.configuracoes)
        r.isMeteringEnabled = true
        guard r.prepareToRecord(), r.record() else {
            throw Recorder.Erro("Não consegui começar a gravar. Feche outros apps que usam o microfone e tente de novo.")
        }
        recorder = r
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

/// Grava uma ideia e a guarda CIFRADA no aparelho antes de qualquer outra coisa. Nada se perde:
/// o arquivo temporário só é apagado depois da fila cifrada escrita e do `Item` salvo; se algo falhar,
/// o temporário fica e `recuperarPendentes()` guarda na próxima abertura.
@MainActor
final class Recorder: ObservableObject {
    struct Erro: Error, LocalizedError, Equatable {
        let errorDescription: String?
        init(_ texto: String) { errorDescription = texto }
    }

    static let msgSemPareamento = "Leia o QR Code no PC antes de gravar."
    static let msgFalhaAoGuardar = "Não consegui guardar a gravação — ela continua salva no aparelho e vou tentar de novo."

    @Published private(set) var nivel: Float = 0  // 0…1
    @Published private(set) var decorrido: TimeInterval = 0
    @Published private(set) var gravando = false
    /// Último item criado por `stop()` ou por uma interrupção (a UI observa para mostrar o resultado).
    @Published private(set) var ultimoItem: Item?
    /// Erro de uma parada automática (interrupção), para a UI avisar.
    @Published private(set) var ultimoErro: String?

    /// Pasta-base (Application Support). Troque só em testes.
    var base: URL
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
        var tarefa: Task<Void, Never>? { get { trava.lock(); defer { trava.unlock() }; return _tarefa }
                                         set { trava.lock(); _tarefa = newValue; trava.unlock() } }
    }
    static let chaveUltimoCofre = "rumo.ultimoCofre"

    private let engine: AudioEngineProtocol
    private let contextoFixo: ModelContext?
    private let centro: NotificationCenter
    private let chave: () -> SymmetricKey?
    private let agora: () -> Date
    private var observador: NSObjectProtocol?
    private var timer: Timer?

    private struct Sessao { let notaId: UUID; let url: URL; let cofre: String; let inicio: Date }
    private var sessao: Sessao?

    init(engine: AudioEngineProtocol,
         contexto: ModelContext? = nil,
         base: URL = Fila.base,
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
            caixa.tarefa = Task { @MainActor in self?.aoInterromper() }
        }
    }

    deinit {
        if let observador { centro.removeObserver(observador) }
    }

    /// Temporários da gravação em andamento. Application Support (e não tmp/Caches) para o sistema não apagar
    /// uma gravação que sobrou de um app encerrado.
    var pastaTemporarios: URL { base.appendingPathComponent("gravando") }

    /// 0…1 a partir de dB: -50 dB → 0, 0 dB → 1.
    static func nivel(db: Float) -> Float { min(1, max(0, (db + 50) / 50)) }

    // MARK: Gravar

    func start(cofre: String) throws {
        guard !gravando else { throw Erro("Já estou gravando.") }
        guard chave() != nil else { throw Erro(Self.msgSemPareamento) }
        let fm = FileManager.default
        try fm.createDirectory(at: pastaTemporarios, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let id = UUID()
        let url = pastaTemporarios.appendingPathComponent("\(id.uuidString).m4a")
        try engine.start(url: url)
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        UserDefaults.standard.set(cofre, forKey: Self.chaveUltimoCofre)
        sessao = Sessao(notaId: id, url: url, cofre: cofre, inicio: agora())
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
        try finalizar()
    }

    private func aoInterromper() {
        guard gravando else { return }
        do { _ = try finalizar() } catch { ultimoErro = error.localizedDescription }
    }

    /// Ordem: fecha o arquivo → cifra → escreve a fila → cria o Item e salva → apaga o temporário → Sync.
    private func finalizar() throws -> Item {
        guard let s = sessao else { throw Erro("Não há gravação em andamento.") }
        timer?.invalidate()
        timer = nil
        let duracao = max(0, Int(engine.currentTime.rounded()))  // antes de fechar (depois zera)
        engine.stop()
        registrarPasso("fechou")
        sessao = nil
        gravando = false
        nivel = 0
        let item = try guardar(temporario: s.url, notaId: s.notaId, cofre: s.cofre, criadoEm: s.inicio, duracaoS: duracao)
        ultimoItem = item
        gatilhoSync()
        registrarPasso("sync")
        return item
    }

    /// Cifra o temporário para a fila, cria o Item e só então apaga o temporário. Em qualquer falha, o temporário fica.
    private func guardar(temporario: URL, notaId: UUID, cofre: String, criadoEm: Date, duracaoS: Int) throws -> Item {
        let fm = FileManager.default
        do {
            guard let k = chave() else { throw Erro(Self.msgSemPareamento) }
            let m4a = try Data(contentsOf: temporario)
            let blob = try Crypto.seal(m4a, key: k)
            registrarPasso("cifrou")

            let pasta = base.appendingPathComponent("fila")
            try fm.createDirectory(at: pasta, withIntermediateDirectories: true,
                                   attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let relativo = Fila.caminhoRelativo(notaId)
            // completeUntilFirstUserAuthentication (não .complete): o sync em segundo plano lê com o telefone bloqueado.
            try blob.write(to: Fila.url(relativo, base: base), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            registrarPasso("fila")

            guard let ctx = contextoFixo ?? Sync.shared.contexto else { throw Erro("Banco de dados indisponível.") }
            let item = Item(notaId: notaId, cofre: cofre, criadoEm: criadoEm, duracaoS: duracaoS, estado: .gravado)
            item.arquivoCifrado = relativo
            ctx.insert(item)
            do { try ctx.save() } catch { ctx.delete(item); throw error }
            registrarPasso("item")

            try? fm.removeItem(at: temporario)
            registrarPasso("apagou")
            return item
        } catch {
            throw Erro(Self.msgFalhaAoGuardar)
        }
    }

    // MARK: Recuperação

    /// Chame ao abrir o app: todo `.m4a` que sobrou (app encerrado gravando, ou falha ao cifrar) vira Item.
    /// Devolve quantas gravações foram recuperadas.
    @discardableResult
    func recuperarPendentes() async -> Int {
        let fm = FileManager.default
        guard let arquivos = try? fm.contentsOfDirectory(at: pastaTemporarios, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]) else { return 0 }
        guard let ctx = contextoFixo ?? Sync.shared.contexto else { return 0 }
        let existentes = Set(((try? ctx.fetch(FetchDescriptor<Item>())) ?? []).map(\.notaId))
        var recuperados = 0
        for url in arquivos where url.pathExtension == "m4a" {
            if let ativa = sessao?.url, ativa == url { continue }  // gravação em andamento
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            let valores = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            if existentes.contains(id) {  // caiu entre salvar e apagar: já está guardado
                try? fm.removeItem(at: url)
                continue
            }
            if (valores?.fileSize ?? 0) == 0 {  // nada gravado
                try? fm.removeItem(at: url)
                continue
            }
            let quando = valores?.creationDate ?? agora()
            if (try? guardar(temporario: url, notaId: id, cofre: UserDefaults.standard.string(forKey: Self.chaveUltimoCofre) ?? "", criadoEm: quando, duracaoS: Self.duracao(de: url))) != nil {
                recuperados += 1
            }
        }
        if recuperados > 0 { gatilhoSync() }
        return recuperados
    }

    private static func duracao(de url: URL) -> Int {
        guard let f = try? AVAudioFile(forReading: url), f.processingFormat.sampleRate > 0 else { return 0 }
        return Int((Double(f.length) / f.processingFormat.sampleRate).rounded())
    }
}
