import SwiftUI

/// Telas abertas em folha. B6b troca cada `Provisoria` pela tela real (QR, novo cofre, diário, nota, digitar, ajustes).
enum Folha: Identifiable, Equatable {
    case qr, novoCofre, diario, digitar, ajustes
    case nota(UUID)

    var id: String {
        switch self {
        case .qr: return "qr"
        case .novoCofre: return "novoCofre"
        case .diario: return "diario"
        case .digitar: return "digitar"
        case .ajustes: return "ajustes"
        case .nota(let u): return "nota-\(u.uuidString)"
        }
    }
}

struct FolhaView: View {
    let folha: Folha

    var body: some View {
        switch folha {
        case .qr: Provisoria(titulo: "Ler QR Code")
        case .novoCofre: Provisoria(titulo: "Novo cofre")
        case .diario: Provisoria(titulo: "Diário")
        case .digitar: Provisoria(titulo: "Digitar nota")
        case .ajustes: Provisoria(titulo: "Ajustes")
        case .nota: Provisoria(titulo: "Nota")
        }
    }
}

private struct Provisoria: View {
    @Environment(\.colorScheme) private var esquema
    let titulo: String

    var body: some View {
        let p = esquema.paleta
        ZStack {
            p.bg.color.ignoresSafeArea()
            VStack(spacing: 8) {
                Text(titulo).font(.display(24, relativeTo: .title2)).foregroundStyle(p.text.color)
                Text("Em breve.").font(.text(15, relativeTo: .body)).foregroundStyle(p.text2.color)
            }
        }
    }
}
