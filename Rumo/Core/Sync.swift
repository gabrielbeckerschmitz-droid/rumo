import CryptoKit
import Foundation
import Observation
import SwiftData

struct SyncReport: Equatable {
    var enviados = 0            // notas que chegaram à caixa
    var pedidosEnviados = 0
    var resultadosAplicados = 0
    var reenviados = 0
    var audiosApagados = 0
    var semInternet = false
    var erro: String?
}

/// Sincronização com a caixa no GitHub: envia, recebe resultados, reenvia o que sumiu e aplica a retenção.
/// Regras: nada se perde; áudio só é apagado depois de `processado`; reenvio não duplica (o PC deduplica
/// por nota_id e parte); nunca registra token nem conteúdo.
@MainActor
@Observable
final class Sync {
    static let shared = Sync()
    static let teto: TimeInterval = 3600  // teto do Backoff

    /// Quando tentar de novo: a menor `proximaTentativa` pendente, com piso de 5 s e teto de 1 h. Função pura.
    nonisolated static func proximoDespertar(_ datas: [Date], agora: Date) -> Date? {
        guard let menor = datas.filter({ $0 > agora }).min() else { return nil }  // data vencida não agenda: evita laço
        return min(menor, agora.addingTimeInterval(teto))
    }

    /// Falso quando o iPhone está bloqueado e os arquivos protegidos não podem ser lidos (ligado em SyncGatilhos).
    @ObservationIgnored var protegidosDisponiveis: () -> Bool = { true }
    /// Quando uma nova tentativa deve acontecer (nil se não há nada esperando). O app agenda `run()` para esta data.
    private(set) var proximaExecucao: Date?

    var tamanhoParte = GitHubClient.tamanhoParte
    var destinosURL = Destinos.arquivoPadrao
    /// Pasta-base dos caminhos relativos de `Item.arquivoCifrado` (Application Support do container atual).
    var baseFila = Fila.base
    var defaults = UserDefaults.standard
    /// Contexto do app (configurado em B6); usado por `run()` sem argumentos.
    var contexto: ModelContext?
    /// Aviso para a UI (hoje: token vencido). Limpo no início de cada sincronização.
    private(set) var ultimoErro: String?
    private(set) var rodando = false

    @discardableResult
    func run(store: ModelContext, client: GitHubClient, chave: SymmetricKey, now: Date = Date()) async -> SyncReport {
        var rel = SyncReport()
        guard !rodando else { return rel }  // reentrante-seguro: já tem uma rodando
        rodando = true
        ultimoErro = nil
        defer { rodando = false }
        _ = try? Fila.garantirPasta(base: baseFila)
        var tokenVencido = false
        func tratar(_ erro: Error) {
            if let e = erro as? GitHubErro {
                if e == .tokenVencido { tokenVencido = true }
                if case .semConexao = e { rel.semInternet = true; return }
                if ultimoErro == nil { ultimoErro = e.errorDescription; rel.erro = ultimoErro }
            } else if ultimoErro == nil {
                ultimoErro = "Algo deu errado ao sincronizar. A gravação continua guardada."
                rel.erro = ultimoErro
            }
        }
        var envioFalhou = false
        do { try await enviarPendentes(store, client, chave, now, &rel) } catch { envioFalhou = true; tratar(error) }
        if !tokenVencido {  // falha de envio não impede receber; token vencido para tudo
            do {
                try await receber(store, client, chave, &rel)
                try await baixarDestinos(client, chave)
                try await reenviarFaltantes(store, client, now, &rel)
                if rel.reenviados > 0 && !envioFalhou { try await enviarPendentes(store, client, chave, now, &rel) }
            } catch { tratar(error) }
        }
        rel.audiosApagados = apagarAudiosAntigos(store, now)
        proximaExecucao = tokenVencido ? nil : calcularProximaExecucao(store, now)  // token vencido: nunca por timer
        return rel
    }

    private func calcularProximaExecucao(_ store: ModelContext, _ now: Date) -> Date? {
        var datas = itens(store).filter { $0.estado == .gravado || $0.estado == .aguardandoInternet }.compactMap(\.proximaTentativa)
        datas += ((try? store.fetch(FetchDescriptor<Pedido>())) ?? []).compactMap(\.proximaTentativa)
        return Sync.proximoDespertar(datas, agora: now)
    }

    // MARK: Envio

    private func itens(_ store: ModelContext) -> [Item] {
        (try? store.fetch(FetchDescriptor<Item>(sortBy: [SortDescriptor(\.criadoEm)]))) ?? []
    }

    private func novoCaminho() -> String { "inbox/\(UUID().uuidString.lowercased()).bin" }

    private func enviarPendentes(_ store: ModelContext, _ client: GitHubClient, _ chave: SymmetricKey,
                                 _ now: Date, _ rel: inout SyncReport) async throws {
        for item in itens(store) where item.estado == .gravado || item.estado == .aguardandoInternet {
            do {
                try await enviar(item, store, client, chave, now)
                if item.estado == .enviado { rel.enviados += 1 }
            } catch let e as GitHubErro {
                registrarFalha(e, item, store, now)
                throw e
            }
        }
        let pedidos = ((try? store.fetch(FetchDescriptor<Pedido>(sortBy: [SortDescriptor(\.criadoEm)]))) ?? []).filter { !$0.enviado }
        for p in pedidos {
            do {
                try await client.put(novoCaminho(), p.blob)
                store.delete(p)  // aceito pela caixa: o blob não fica no banco (o PC deduplica por id)
                try? store.save()
                rel.pedidosEnviados += 1
            } catch let e as GitHubErro {
                if e != .tokenVencido {
                    p.proximaTentativa = now.addingTimeInterval(Backoff.proxima(tentativas: p.tentativas))
                    p.tentativas += 1
                    try? store.save()
                }
                throw e
            }
        }
    }

    private func registrarFalha(_ e: GitHubErro, _ item: Item, _ store: ModelContext, _ now: Date) {
        switch e {
        case .tokenVencido: return  // o item continua como está; a UI mostra o aviso do token
        case .semConexao: item.estado = .aguardandoInternet
        case .github: break
        }
        item.proximaTentativa = now.addingTimeInterval(Backoff.proxima(tentativas: item.tentativas))
        item.tentativas += 1
        try? store.save()
    }

    /// Envia uma nota. Retomável: `partesEnviadas` conta as partes já aceitas (201).
    private func enviar(_ item: Item, _ store: ModelContext, _ client: GitHubClient, _ chave: SymmetricKey,
                        _ now: Date) async throws {
        let nota = ID(item.notaId)
        let criado = Instante(item.criadoEm)
        if let texto = item.texto {
            let msg = Msg(id: ID(UUID()), criadoEm: criado, corpo: .notaTexto(NotaTexto(notaId: nota, cofre: item.cofre, texto: texto)))
            let caminho = try await colocar(msg, client, chave)
            item.caminhosInbox += [caminho]
            item.partesEnviadas = 1
        } else {
            // Leitura que falha agora (celular bloqueado, arquivo ainda sendo gravado...) não muda nada: tenta na próxima.
            // Caminhos de "pular" limpam proximaTentativa: dependem dos gatilhos normais (abrir, rede, fundo), não de timer.
            guard protegidosDisponiveis(), let rel = item.arquivoCifrado,
                  let blob = try? Data(contentsOf: Fila.url(rel, base: baseFila)) else { item.proximaTentativa = nil; return }
            guard let m4a = try? Crypto.open(blob, key: chave) else {  // arquivo lido, mas a chave não abre
                item.erroTexto = "Não consegui abrir esta gravação com a chave atual — ela foi feita antes de um novo pareamento?"
                item.proximaTentativa = nil
                try? store.save()
                return
            }
            guard !m4a.isEmpty else {
                item.erroTexto = "Gravação vazia."
                item.proximaTentativa = nil
                try? store.save()
                return
            }
            let total = max(1, (m4a.count + tamanhoParte - 1) / tamanhoParte)
            let inicio = total == 1 ? 1 : item.partesEnviadas + 1
            if inicio <= total {
                for parte in inicio...total {
                    let ini = (parte - 1) * tamanhoParte
                    let pedaco = m4a.subdata(in: ini..<min(ini + tamanhoParte, m4a.count))
                    let corpo: Msg.Corpo = total == 1
                        ? .notaAudio(NotaAudio(notaId: nota, cofre: item.cofre, audio: pedaco, duracaoS: item.duracaoS))
                        : .notaAudioParte(NotaAudioParte(notaId: nota, cofre: item.cofre, parte: parte, totalPartes: total,
                                                         audio: pedaco, duracaoS: parte == 1 ? item.duracaoS : nil))
                    let caminho = try await colocar(Msg(id: ID(UUID()), criadoEm: criado, corpo: corpo), client, chave)
                    item.partesEnviadas = parte
                    item.caminhosInbox += [caminho]
                    try? store.save()  // progresso guardado: se cair aqui, retoma da próxima parte
                }
            }
        }
        item.estado = .enviado
        item.enviadoEm = now
        item.tentativas = 0
        item.proximaTentativa = nil
        item.erroTexto = nil
        try? store.save()
    }

    private func colocar(_ msg: Msg, _ client: GitHubClient, _ chave: SymmetricKey) async throws -> String {
        let caminho = novoCaminho()
        try await client.put(caminho, try msg.sealed(key: chave))
        return caminho
    }

    // MARK: Recebimento

    private func receber(_ store: ModelContext, _ client: GitHubClient, _ chave: SymmetricKey, _ rel: inout SyncReport) async throws {
        let entradas = try await client.list("outbox").filter { $0.path.hasSuffix(".bin") }
        // Baixa e decodifica tudo primeiro; aplica em ordem de tempo (a lista vem em ordem de uuid).
        var recebidos: [(Entrada, Msg, Resultado)] = []
        for e in entradas {
            let blob: Data
            do { blob = try await client.get(e.path) } catch GitHubErro.github(404) { continue }
            guard let msg = try? Msg.open(blob, key: chave) else {
                try await client.delete(e.path, sha: e.sha)  // blob inválido: apaga e segue
                continue
            }
            guard case .resultado(let r) = msg.corpo else { continue }
            recebidos.append((e, msg, r))
        }
        let ordenados = recebidos.enumerated().sorted {
            ($0.element.1.criadoEm.date, $0.offset) < ($1.element.1.criadoEm.date, $1.offset)
        }.map(\.element)
        for (e, msg, r) in ordenados {
            if let item = itens(store).first(where: { $0.notaId == r.notaId.uuid }) {
                aplicar(msg, r, item)
                do { try store.save() } catch { continue }  // sem salvar, o resultado fica na caixa
            }
            try await client.delete(e.path, sha: e.sha)  // só depois de salvo
            rel.resultadosAplicados += 1
        }
    }

    /// Idempotente: repetir não muda nada, não reinicia a retenção e um erro não rebaixa uma nota processada.
    private func aplicar(_ msg: Msg, _ r: Resultado, _ item: Item) {
        if item.estado == .processado {
            guard r.status == .processado else { return }
            let quando = item.processadoEm
            Store.aplicarResultado(item, resultado: msg)
            if let quando { item.processadoEm = quando }
        } else {
            Store.aplicarResultado(item, resultado: msg)
        }
    }

    private func baixarDestinos(_ client: GitHubClient, _ chave: SymmetricKey) async throws {
        let blob: Data
        do { blob = try await client.get("config/destinos.bin") } catch GitHubErro.github(404) { return }
        guard let msg = try? Msg.open(blob, key: chave), case .destinos(let d) = msg.corpo else { return }
        try? Destinos.salvarLocal(d, em: destinosURL)
    }

    // MARK: Reenvio e retenção

    /// Enviado há mais de 24 h, sem resultado e sumido da caixa: volta para `gravado` e sai de novo.
    private func reenviarFaltantes(_ store: ModelContext, _ client: GitHubClient, _ now: Date, _ rel: inout SyncReport) async throws {
        var naCaixa: Set<String>?  // uma listagem da inbox por rodada, só se houver candidato
        for item in itens(store) where item.estado == .enviado {
            guard let enviado = item.enviadoEm, now.timeIntervalSince(enviado) > 24 * 3600 else { continue }
            if naCaixa == nil { naCaixa = Set(try await client.list("inbox").map(\.path)) }
            let existe = item.caminhosInbox.contains { naCaixa?.contains($0) == true }
            if Store.precisaReenviar(item, agora: now, existeNaCaixa: existe) {
                item.estado = .gravado
                item.partesEnviadas = 0
                item.caminhosInbox = []
                try? store.save()
                rel.reenviados += 1
            }
        }
    }

    /// Apaga só o arquivo de áudio local; o item continua no histórico.
    private func apagarAudiosAntigos(_ store: ModelContext, _ now: Date) -> Int {
        let dias = (defaults.object(forKey: "retencaoDias") as? Int) ?? 30
        var apagados = 0
        for item in itens(store) where item.arquivoCifrado != nil && Store.podeApagarAudio(item, agora: now, retencaoDias: dias) {
            if let rel = item.arquivoCifrado, case let url = Fila.url(rel, base: baseFila), FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url) } catch { continue }
            }
            item.arquivoCifrado = nil
            apagados += 1
        }
        if apagados > 0 { try? store.save() }
        return apagados
    }
}
