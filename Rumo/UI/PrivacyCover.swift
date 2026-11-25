import SwiftUI

/// Cobre o conteúdo quando o app não está ativo (seletor de apps) ou a tela está sendo gravada/espelhada.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Theme.azul.color.ignoresSafeArea()
            Text("Rumo")
                .font(.display(40, .heavy, relativeTo: .largeTitle))
                .foregroundStyle(Theme.branco.color)
        }
        .accessibilityHidden(true)
    }
}
