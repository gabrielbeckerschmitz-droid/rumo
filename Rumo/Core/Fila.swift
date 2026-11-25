import Foundation

/// Fila de gravações cifradas no disco. Os caminhos guardados no `Item` são RELATIVOS a Application Support,
/// porque o caminho do container muda quando o app é atualizado ou reinstalado.
enum Fila {
    /// Application Support do container atual.
    static var base: URL {
        let fm = FileManager.default
        return (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
    }

    /// Resolve um caminho relativo (ex.: "fila/<uuid>.bin") contra a base do container atual.
    static func url(_ relativo: String, base: URL = Fila.base) -> URL {
        base.appendingPathComponent(relativo)
    }

    static func caminhoRelativo(_ notaId: UUID) -> String { "fila/\(notaId.uuidString).bin" }
}
