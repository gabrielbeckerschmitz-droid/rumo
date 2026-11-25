import SwiftUI

extension ColorScheme {
    var paleta: Palette { self == .dark ? Theme.dark : Theme.light }
    /// Destaque: turquesa no escuro; no claro, azul (turquesa nunca é texto nem marca sobre creme).
    var destaque: Color { self == .dark ? Theme.turquesa.color : Theme.azul.color }
}

/// Rótulo pequeno em caixa-alta.
struct Rotulo: View {
    @Environment(\.colorScheme) private var esquema
    let texto: String
    init(_ texto: String) { self.texto = texto }

    var body: some View {
        Text(texto.uppercased())
            .font(.display(11, relativeTo: .caption))
            .tracking(1.8)
            .foregroundStyle(esquema.paleta.text2.color)
    }
}

extension View {
    /// Cartão (raio 12).
    func cartao(_ p: Palette, padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(p.card.color, in: RoundedRectangle(cornerRadius: Theme.Radius.cartao))
    }

    /// Etiqueta/chip (raio 4, borda fina).
    func etiqueta(borda: Color) -> some View {
        self.overlay(RoundedRectangle(cornerRadius: Theme.Radius.botao).stroke(borda, lineWidth: 1))
    }
}

/// O único botão principal da tela: faixa turquesa de 72 pt, texto azul-profundo, raio 0.
struct FaixaPrincipal<Simbolo: View>: View {
    let titulo: String
    let acao: () -> Void
    let icone: Simbolo

    init(_ titulo: String, acao: @escaping () -> Void, @ViewBuilder icone: () -> Simbolo) {
        self.titulo = titulo
        self.acao = acao
        self.icone = icone()
    }

    var body: some View {
        Button(action: acao) {
            HStack {
                Text(titulo).font(.display(20, .heavy, relativeTo: .title3))
                Spacer()
                icone
                    .frame(width: 44, height: 44)
                    .background(Theme.azul.color)
                    .foregroundStyle(Theme.turquesa.color)
            }
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(Theme.turquesa.color)
            .foregroundStyle(Theme.azul.color)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(titulo)
    }
}

/// Ícone SF Symbol: traço regular, sem preenchimento, 24 pt.
struct Icone: View {
    let nome: String
    init(_ nome: String) { self.nome = nome }
    var body: some View { Image(systemName: nome).font(.system(size: 24, weight: .regular)) }
}
