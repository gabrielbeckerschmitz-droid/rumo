import AVFoundation
import SwiftUI
import UIKit

/// Raiz: escolhe a tela (pareamento, início, gravando), trava o app e cobre o conteúdo quando preciso.
struct RootView: View {
    @ObservedObject var recorder: Recorder
    @Environment(\.scenePhase) private var fase
    @Environment(\.colorScheme) private var esquema
    @AppStorage(Recorder.chaveUltimoCofre) private var ultimoCofre = ""

    private let acao = AcaoRapida.shared
    private let sync = Sync.shared

    @State private var pareado = Keychain.load() != nil
    @State private var bloqueado = true  // abertura a frio sempre pede
    @State private var saiuEm: Date?
    @State private var capturado = UIScreen.main.isCaptured
    @State private var folha: Folha?
    @State private var cofres = Destinos.carregarLocal()
    @State private var aviso: String?
    @State private var gravarAposDesbloqueio = false

    private var cobrir: Bool { fase != .active || capturado }

    var body: some View {
        let p = esquema.paleta
        ZStack {
            p.bg.color.ignoresSafeArea()
            conteudo
            if let aviso { toast(aviso, p) }
            if bloqueado { LockScreen(ativo: fase == .active, aoDesbloquear: desbloquear) }
            if cobrir { PrivacyCover() }
        }
        .sheet(item: $folha, onDismiss: recarregar) { f in
            FolhaView(folha: f)
                .overlay { if cobrir || bloqueado { PrivacyCover() } }  // a folha fica acima da raiz
        }
        .onChange(of: fase, initial: true) { _, nova in aoMudarFase(nova) }
        .onChange(of: acao.pedido, initial: true) { _, pedido in
            guard pedido else { return }
            acao.pedido = false
            Task { await acaoRapida() }
        }
        .onChange(of: sync.rodando) { _, rodando in if !rodando { recarregar() } }
        .onChange(of: recorder.ultimoErro) { _, erro in if let erro { mostrar(erro, segundos: 5) } }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            capturado = UIScreen.main.isCaptured
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            recorder.encerrarSeGravando()
        }
    }

    @ViewBuilder
    private var conteudo: some View {
        if !pareado {
            PareamentoView(aoLer: { folha = .qr })
        } else if recorder.gravando {
            RecordingView(recorder: recorder, aoParar: { Task { await parar() } })
        } else {
            HomeView(cofres: cofres,
                     aoGravar: { cofre in Task { await comecar(cofre: cofre) } },
                     aoNovoCofre: { folha = .novoCofre },
                     aoDigitar: { folha = .digitar },
                     aoDiario: { folha = .diario },
                     aoAjustes: { folha = .ajustes })
        }
    }

    private func toast(_ texto: String, _ p: Palette) -> some View {
        VStack {
            Text(texto)
                .font(.text(14, .medium, relativeTo: .callout))
                .foregroundStyle(p.text.color)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(esquema == .dark ? Theme.azul.color : Theme.branco.color,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.cartao))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.cartao).stroke(p.text.color, lineWidth: 1))
                .padding(.horizontal, 18)
                .padding(.top, 8)
            Spacer()
        }
        .transition(.opacity)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: Ciclo de vida e bloqueio

    private func aoMudarFase(_ nova: ScenePhase) {
        switch nova {
        case .background:
            if saiuEm == nil { saiuEm = Date() }
            Sync.shared.agendarFundo()
        case .active:
            if let s = saiuEm {
                if AppLock.precisaDesbloquear(saiuEm: s, agora: Date()) { bloquear() }
                saiuEm = nil
            }
            recarregar()
            Task {
                await recorder.recuperarPendentes()
                await Sync.shared.run()
            }
        default:
            break
        }
    }

    private func bloquear() {
        folha = nil
        bloqueado = true
    }

    private func desbloquear() async {
        guard await AppLock.desbloquear() else { return }
        bloqueado = false
        if gravarAposDesbloqueio {
            gravarAposDesbloqueio = false
            await comecarNoUltimoCofre()
        }
    }

    private func recarregar() {
        pareado = Keychain.load() != nil
        cofres = Destinos.carregarLocal()
    }

    // MARK: Gravação

    /// Ação rápida: desbloqueia (se preciso) e já grava no último cofre.
    private func acaoRapida() async {
        guard pareado, !recorder.gravando else { return }
        if let s = saiuEm, AppLock.precisaDesbloquear(saiuEm: s, agora: Date()) { bloquear() }
        if bloqueado { gravarAposDesbloqueio = true; return }
        await comecarNoUltimoCofre()
    }

    private func comecarNoUltimoCofre() async {
        guard let cofre = cofres.first(where: { $0.nome == ultimoCofre })?.nome ?? cofres.first?.nome else {
            mostrar("Ainda não recebi a lista de cofres do PC. Sincronize e tente de novo.", segundos: 5)
            return
        }
        await comecar(cofre: cofre)
    }

    private func comecar(cofre: String) async {
        guard !recorder.gravando else { return }
        if AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await AVAudioEngineRecorder.pedirPermissao()
        }
        if AVAudioApplication.shared.recordPermission == .denied {
            mostrar("Libere o microfone em Ajustes > Rumo para gravar.", segundos: 5)
            return
        }
        do { try recorder.start(cofre: cofre) } catch { mostrar(error.localizedDescription, segundos: 5) }
    }

    private func parar() async {
        do {
            _ = try await recorder.stop()
            mostrar("Guardada", segundos: 2.5)
        } catch {
            mostrar(error.localizedDescription, segundos: 5)
        }
    }

    private func mostrar(_ texto: String, segundos: Double) {
        withAnimation { aviso = texto }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(segundos * 1_000_000_000))
            if aviso == texto { withAnimation { aviso = nil } }
        }
    }
}
