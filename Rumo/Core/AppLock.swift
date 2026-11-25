import Foundation
import LocalAuthentication

enum AppLock {
    /// Tempo fora do app a partir do qual pede o desbloqueio.
    static let limite: TimeInterval = 300

    /// `saiuEm == nil` = abertura a frio: sempre pede.
    static func precisaDesbloquear(saiuEm: Date?, agora: Date) -> Bool {
        guard let saiuEm else { return true }
        return agora.timeIntervalSince(saiuEm) >= limite
    }

    /// Face ID / Touch ID com o código do aparelho como alternativa.
    /// Aparelho sem código: não há o que pedir, então libera (o iOS não oferece outra forma de travar).
    static func desbloquear() async -> Bool {
        let ctx = LAContext()
        var erro: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &erro) else {
            return (erro as? LAError)?.code == .passcodeNotSet
        }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Desbloqueie para abrir o Rumo")) ?? false
    }
}
