import SwiftUI

@main
struct RumoApp: App {
    var body: some Scene {
        WindowGroup {
            PlaceholderView()
        }
    }
}

/// Tela provisória; as telas reais chegam na tarefa B6.
struct PlaceholderView: View {
    private let p = Theme.dark

    var body: some View {
        ZStack {
            p.bg.color.ignoresSafeArea()
            Text("Rumo")
                .font(.display(34, .heavy))
                .foregroundStyle(p.text.color)
        }
    }
}
