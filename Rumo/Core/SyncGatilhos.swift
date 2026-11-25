import BackgroundTasks
import CryptoKit
import Foundation
import Network
import UIKit

/// Gatilhos da sincronização (só a API; o B6 liga à UI e ao App):
/// abrir o app, parar uma gravação e "Sincronizar agora" chamam `Sync.shared.run()`;
/// a rede voltando, o backoff e as tarefas de fundo são ligados aqui.
extension Sync {
    static let idAtualizacao = "br.com.nortea.rumo.sync"
    static let idProcessamento = "br.com.nortea.rumo.process"

    private final class Caixinha {
        var fundo = UIBackgroundTaskIdentifier.invalid
        var trabalho: Task<Void, Never>?
    }
    private static var monitor: NWPathMonitor?
    private static var reexecucao: Task<Void, Never>?

    /// Sincroniza com o pareamento do Keychain e o contexto configurado. Sem pareamento ou contexto, não faz nada.
    /// Se o app for para segundo plano no meio do envio, pede tempo ao sistema para terminar o envio atual.
    /// Se sobrar algo para tentar de novo, agenda uma única nova tentativa (backoff crescente).
    func run() async {
        guard !rodando, let contexto, let p = Keychain.load() else { return }
        protegidosDisponiveis = { UIApplication.shared.isProtectedDataAvailable }
        let caixa = Caixinha()
        caixa.fundo = UIApplication.shared.beginBackgroundTask(withName: "rumo.sync") {
            UIApplication.shared.endBackgroundTask(caixa.fundo)
            caixa.fundo = .invalid
        }
        await run(store: contexto, client: GitHubClient(token: p.token, dono: p.dono, repo: p.repo),
                  chave: SymmetricKey(data: p.chave))
        if caixa.fundo != .invalid { UIApplication.shared.endBackgroundTask(caixa.fundo) }
        agendarReexecucao()
    }

    /// Uma só espera pendente: dorme até `proximaExecucao` (já limitada ao teto do backoff) e roda de novo.
    private func agendarReexecucao() {
        Sync.reexecucao?.cancel()
        Sync.reexecucao = nil
        guard let quando = proximaExecucao else { return }
        Sync.reexecucao = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(quando.timeIntervalSinceNow, 1) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await Sync.shared.run()
        }
    }

    /// Quando a internet volta (`.satisfied`), sincroniza.
    func iniciarMonitorDeRede() {
        guard Sync.monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await Sync.shared.run() }
        }
        m.start(queue: DispatchQueue(label: "br.com.nortea.rumo.rede"))
        Sync.monitor = m
    }

    /// Chamar uma vez, cedo, ao abrir o app (antes de terminar o lançamento).
    func registrarTarefasDeFundo() {
        for id in [Sync.idAtualizacao, Sync.idProcessamento] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { tarefa in
                let caixa = Caixinha()
                tarefa.expirationHandler = { caixa.trabalho?.cancel() }  // antes de iniciar o trabalho
                caixa.trabalho = Task { @MainActor in
                    Sync.shared.agendarFundo()  // já marca a próxima janela
                    await Sync.shared.run()
                    tarefa.setTaskCompleted(success: !Task.isCancelled)
                }
            }
        }
    }

    /// A janela do sistema nunca começa antes da próxima tentativa do backoff (o sistema decide o momento real).
    func agendarFundo() {
        let minimo = proximaExecucao ?? Date(timeIntervalSinceNow: 15 * 60)
        let atualizacao = BGAppRefreshTaskRequest(identifier: Sync.idAtualizacao)
        atualizacao.earliestBeginDate = max(minimo, Date(timeIntervalSinceNow: 15 * 60))
        let processamento = BGProcessingTaskRequest(identifier: Sync.idProcessamento)
        processamento.requiresNetworkConnectivity = true
        processamento.requiresExternalPower = false
        processamento.earliestBeginDate = max(minimo, Date(timeIntervalSinceNow: 30 * 60))
        try? BGTaskScheduler.shared.submit(atualizacao)
        try? BGTaskScheduler.shared.submit(processamento)
    }
}
