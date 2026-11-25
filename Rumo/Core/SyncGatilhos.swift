import BackgroundTasks
import CryptoKit
import Foundation
import Network
import UIKit

/// Gatilhos da sincronização (só a API; o B6 liga à UI e ao App):
/// abrir o app, parar uma gravação e "Sincronizar agora" chamam `Sync.shared.run()`;
/// a rede voltando e as tarefas de fundo são ligadas aqui.
extension Sync {
    static let idAtualizacao = "br.com.nortea.rumo.sync"
    static let idProcessamento = "br.com.nortea.rumo.process"

    private final class TarefaDeFundo { var id = UIBackgroundTaskIdentifier.invalid }
    private static var monitor: NWPathMonitor?

    /// Sincroniza com o pareamento do Keychain e o contexto configurado. Sem pareamento ou contexto, não faz nada.
    /// Se o app for para segundo plano no meio do envio, pede tempo ao sistema para terminar o envio atual.
    func run() async {
        guard !rodando, let contexto, let p = Keychain.load() else { return }
        let tarefa = TarefaDeFundo()
        tarefa.id = UIApplication.shared.beginBackgroundTask(withName: "rumo.sync") {
            UIApplication.shared.endBackgroundTask(tarefa.id)
            tarefa.id = .invalid
        }
        await run(store: contexto, client: GitHubClient(token: p.token, dono: p.dono, repo: p.repo),
                  chave: SymmetricKey(data: p.chave))
        if tarefa.id != .invalid { UIApplication.shared.endBackgroundTask(tarefa.id) }
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
                Task { @MainActor in
                    Sync.shared.agendarFundo()  // já marca a próxima janela
                    let trabalho = Task { @MainActor in await Sync.shared.run() }
                    tarefa.expirationHandler = { trabalho.cancel() }
                    await trabalho.value
                    tarefa.setTaskCompleted(success: true)
                }
            }
        }
    }

    func agendarFundo() {
        let atualizacao = BGAppRefreshTaskRequest(identifier: Sync.idAtualizacao)
        atualizacao.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        let processamento = BGProcessingTaskRequest(identifier: Sync.idProcessamento)
        processamento.requiresNetworkConnectivity = true
        processamento.requiresExternalPower = false
        processamento.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(atualizacao)
        try? BGTaskScheduler.shared.submit(processamento)
    }
}
