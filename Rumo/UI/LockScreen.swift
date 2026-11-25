import SwiftUI

struct LockScreen: View {
    /// Cena ativa: só então tenta o Face ID sozinho (uma vez por bloqueio).
    let ativo: Bool
    let aoDesbloquear: () async -> Void
    @State private var tentou = false

    var body: some View {
        ZStack {
            Theme.azul.color.ignoresSafeArea()
            VStack(spacing: 28) {
                Text("Rumo")
                    .font(.display(40, .heavy, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.branco.color)
                Text("Suas ideias ficam protegidas.")
                    .font(.text(15, relativeTo: .body))
                    .foregroundStyle(Theme.dark.text2.color)
                Button {
                    Task { await aoDesbloquear() }
                } label: {
                    Text("Desbloquear")
                        .font(.display(16, relativeTo: .body))
                        .foregroundStyle(Theme.azul.color)
                        .padding(.horizontal, 28)
                        .frame(minHeight: 48)
                        .background(Theme.turquesa.color, in: RoundedRectangle(cornerRadius: Theme.Radius.botao))
                }
            }
        }
        .task(id: ativo) {
            guard ativo, !tentou else { return }
            tentou = true
            await aoDesbloquear()
        }
    }
}
