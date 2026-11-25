import Foundation

/// Fila de gravações cifradas no disco. Os caminhos guardados no `Item` são RELATIVOS a Application Support,
/// porque o caminho do container muda quando o app é atualizado ou reinstalado.
enum Fila {
    struct ErroBase: Error, LocalizedError {
        var errorDescription: String? { "Não consegui acessar a pasta do app no iPhone. Reinicie o app; se continuar, libere espaço no aparelho." }
    }

    /// Application Support do container atual. Falha em voz alta (nunca cai para uma pasta temporária).
    static func baseURL() throws -> URL {
        do { return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) }
        catch { throw ErroBase() }
    }

    /// Para valores padrão que não podem lançar erro; o `Recorder` usa `baseURL()` e propaga o erro.
    static var base: URL {
        do { return try baseURL() } catch { fatalError("Application Support indisponível") }
    }

    /// Resolve um caminho relativo (ex.: "fila/<uuid>.bin") contra a base do container atual.
    static func url(_ relativo: String, base: URL = Fila.base) -> URL {
        base.appendingPathComponent(relativo)
    }

    /// Cria a pasta `fila` (protegida até o primeiro desbloqueio) e a tira do backup. Idempotente.
    @discardableResult
    static func garantirPasta(base: URL = Fila.base) throws -> URL {
        let pasta = base.appendingPathComponent("fila")
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        Destinos.excluirDoBackup(pasta)
        return pasta
    }

    static func caminhoRelativo(_ notaId: UUID) -> String { "fila/\(notaId.uuidString).bin" }
}
