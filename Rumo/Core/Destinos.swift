import Foundation

/// Cópia local da lista de cofres (config/destinos.bin), para a UI funcionar offline.
/// Só nomes de cofres; fica em Application Support, protegida até o primeiro desbloqueio.
extension Destinos {
    static var arquivoPadrao: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rumo/destinos.json")
    }

    static func salvarLocal(_ d: Destinos, em url: URL = arquivoPadrao) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(d).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        excluirDoBackup(url)
    }

    /// Fila e destinos ficam só no aparelho: fora do backup do iCloud/iTunes.
    static func excluirDoBackup(_ url: URL) {
        var u = url
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }

    static func carregarLocal(de url: URL = arquivoPadrao) -> [Cofre] {
        guard let dados = try? Data(contentsOf: url), let d = try? JSONDecoder().decode(Destinos.self, from: dados) else { return [] }
        return d.cofres
    }
}
