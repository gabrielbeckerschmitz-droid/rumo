import Foundation

enum GitHubErro: Error, LocalizedError, Equatable {
    case tokenVencido
    case semConexao(String)
    case github(Int)

    static let mensagemSemConexao = "Sem internet — a gravação está guardada e sai sozinha."

    var errorDescription: String? {
        switch self {
        case .tokenVencido: return "O token do GitHub venceu — gere um novo no PC (passo a passo no guia)."
        case .semConexao(let m): return m
        case .github(let s): return "O GitHub não aceitou o pedido (código \(s)). O Rumo tenta de novo enquanto o app estiver aberto; você também pode tocar em Sincronizar agora."
        }
    }
}

struct Entrada: Equatable {
    let path: String
    let sha: String
    let size: Int
}

/// Cliente mínimo da Contents API (espelha pc/rumo_pc/github.py). Nunca registra token nem conteúdo.
final class GitHubClient {
    /// Mesmo valor do PC (TAMANHO_PARTE em github.py).
    static let tamanhoParte = 5 * 1024 * 1024

    private let token: String
    private let dono: String
    private let repo: String
    private let base: String
    private let session: URLSession

    init(token: String, dono: String, repo: String, session: URLSession = .shared,
         base: URL = URL(string: "https://api.github.com")!) {
        self.token = token
        self.dono = dono
        self.repo = repo
        self.session = session
        self.base = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
    }

    private struct ItemApi: Decodable { let path: String; let sha: String; let size: Int; let type: String }

    // MARK: API

    func put(_ path: String, _ data: Data, sha: String? = nil) async throws {
        var corpo: [String: String] = ["message": "rumo", "content": data.base64EncodedString()]
        if let sha { corpo["sha"] = sha }
        let status = try await executar("PUT", path, corpo: corpo, tempo: 120).0
        guard status == 200 || status == 201 else { throw GitHubErro.github(status) }
    }

    func list(_ pasta: String) async throws -> [Entrada] {
        let (status, dados) = try await executar("GET", pasta)
        if status == 404 { return [] }
        guard status == 200 else { throw GitHubErro.github(status) }
        let itens = (try? JSONDecoder().decode([ItemApi].self, from: dados)) ?? []
        return itens.filter { $0.type == "file" }.map { Entrada(path: $0.path, sha: $0.sha, size: $0.size) }
    }

    func get(_ path: String) async throws -> Data {
        let (status, dados) = try await executar("GET", path, raw: true, tempo: 120)
        guard status == 200 else { throw GitHubErro.github(status) }
        return dados
    }

    func delete(_ path: String, sha: String) async throws {
        let status = try await executar("DELETE", path, corpo: ["message": "rumo", "sha": sha]).0
        guard status == 200 || status == 404 else { throw GitHubErro.github(status) }
    }

    /// Confere pela listagem da pasta (só metadados, nunca baixa o conteúdo).
    func exists(_ path: String) async throws -> Bool {
        let pasta = path.split(separator: "/").dropLast().joined(separator: "/")
        return try await list(pasta).contains { $0.path == path }
    }

    // MARK: HTTP

    private func executar(_ metodo: String, _ path: String, corpo: [String: String]? = nil,
                          raw: Bool = false, tempo: TimeInterval = 60) async throws -> (Int, Data) {
        let cod = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        var req = URLRequest(url: URL(string: "\(base)/repos/\(dono)/\(repo)/contents/\(cod)")!)
        req.httpMethod = metodo
        req.timeoutInterval = tempo
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(raw ? "application/vnd.github.raw+json" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("rumo-ios", forHTTPHeaderField: "User-Agent")
        if let corpo { req.httpBody = try JSONSerialization.data(withJSONObject: corpo) }
        let resultado: (Data, URLResponse)
        do { resultado = try await session.data(for: req) }
        catch is URLError { throw GitHubErro.semConexao(GitHubErro.mensagemSemConexao) }
        guard let http = resultado.1 as? HTTPURLResponse else { throw GitHubErro.semConexao(GitHubErro.mensagemSemConexao) }
        if http.statusCode == 401 { throw GitHubErro.tokenVencido }
        return (http.statusCode, resultado.0)
    }
}
