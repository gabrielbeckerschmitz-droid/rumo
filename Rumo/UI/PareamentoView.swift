import SwiftUI

/// Primeira tela, antes do pareamento com o PC.
struct PareamentoView: View {
    @Environment(\.colorScheme) private var esquema
    let aoLer: () -> Void

    var body: some View {
        let p = esquema.paleta
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            Text("Leia o QR Code no PC")
                .font(.display(28, relativeTo: .title))
                .foregroundStyle(p.text.color)
            Text("Abra o programa do Rumo no PC e escaneie o código para ligar os dois aparelhos.")
                .font(.text(15, relativeTo: .body))
                .foregroundStyle(p.text2.color)
            Spacer()
            FaixaPrincipal("Ler QR Code", acao: aoLer) { Icone("qrcode.viewfinder") }
        }
        .padding(.top, 24)
        .padding(.horizontal, 18)
    }
}
