import AVFoundation
import SwiftData
import SwiftUI

@main
@MainActor
struct RumoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("tema") private var tema = "escuro"  // escuro | claro | sistema
    private let container: ModelContainer
    @StateObject private var recorder: Recorder

    init() {
        let c = Self.abrirContainer()
        container = c
        Sync.shared.contexto = c.mainContext
        Sync.shared.iniciarMonitorDeRede()
        _recorder = StateObject(wrappedValue: Recorder(engine: AVAudioEngineRecorder(), contexto: c.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView(recorder: recorder)
                .modelContainer(container)
                .preferredColorScheme(tema == "claro" ? .light : tema == "sistema" ? nil : .dark)
        }
    }

    /// Banco em Application Support/Rumo, fora do backup do iCloud/iTunes.
    private static func abrirContainer() -> ModelContainer {
        do {
            let pasta = try Fila.baseURL().appendingPathComponent("Rumo")
            try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
            Destinos.excluirDoBackup(pasta)
            let config = ModelConfiguration(url: pasta.appendingPathComponent("rumo.store"), cloudKitDatabase: .none)
            return try ModelContainer(for: Item.self, Pedido.self, configurations: config)
        } catch {
            // Sem banco o app não tem como guardar nada com segurança.
            fatalError("Não consegui abrir o banco do Rumo: \(error)")
        }
    }
}
