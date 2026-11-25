import Observation
import UIKit

/// Ação rápida "Gravar ideia" (toque longo no ícone). A UI consome `pedido` quando o app está pronto.
@MainActor
@Observable
final class AcaoRapida {
    static let shared = AcaoRapida()
    static let tipoGravar = "br.com.nortea.rumo.gravar"
    var pedido = false

    @discardableResult
    func tratar(_ item: UIApplicationShortcutItem) -> Bool {
        guard item.type == Self.tipoGravar else { return false }
        pedido = true
        return true
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// As tarefas de fundo precisam ser registradas antes do fim do lançamento.
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Sync.shared.registrarTarefasDeFundo()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem { AcaoRapida.shared.tratar(item) }  // abertura a frio
        let c = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}

@MainActor
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// App já aberto em segundo plano.
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(AcaoRapida.shared.tratar(shortcutItem))
    }
}
