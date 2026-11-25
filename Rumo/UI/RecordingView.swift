import SwiftUI

/// Tela de gravação.
struct RecordingView: View {
    @Environment(\.colorScheme) private var esquema
    @ObservedObject var recorder: Recorder
    @AppStorage(Recorder.chaveUltimoCofre) private var cofre = ""
    let aoParar: () -> Void
    @State private var historico: [Float] = []

    private let barras = 47

    var body: some View {
        let p = esquema.paleta
        VStack(spacing: 0) {
            HStack {
                Rotulo("Gravando para")
                Spacer()
                Text("● REC").font(.display(10, relativeTo: .caption2)).tracking(1.2)
                    .foregroundStyle(Theme.azul.color)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(Theme.turquesa.color, in: RoundedRectangle(cornerRadius: Theme.Radius.botao))
            }
            .padding(.horizontal, 18).padding(.top, 8)
            Text(cofre).font(.display(28, relativeTo: .title)).foregroundStyle(p.text.color)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.top, 6)
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(Stats.cronometro(recorder.decorrido))
                    .font(.display(92, .heavy, relativeTo: .largeTitle))
                    .foregroundStyle(esquema.destaque).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .accessibilityLabel("Gravando há \(Stats.duracao(Int(recorder.decorrido)))")
                voz(p).padding(.top, 26)
                HStack(spacing: 10) {
                    mini("Tamanho", Self.tamanho(recorder.decorrido), p)
                    mini("Tela", "Livre", p)
                    mini("Cofre", "Seguro", p)
                }
                .padding(.top, 22)
                Text("Pode bloquear a tela. O áudio fica criptografado no celular assim que você parar.")
                    .font(.text(13, .medium, relativeTo: .footnote)).foregroundStyle(p.text2.color).padding(.top, 12)
            }
            .padding(.horizontal, 18)
            Spacer(minLength: 8)
            FaixaPrincipal("Parar e guardar", acao: aoParar) {
                Rectangle().frame(width: 18, height: 18).frame(width: 44, height: 44)
            }
        }
        .onChange(of: recorder.decorrido) { _, _ in
            historico.append(recorder.nivel)
            if historico.count > barras { historico.removeFirst(historico.count - barras) }
        }
    }

    private func voz(_ p: Palette) -> some View {
        let vazias = barras - historico.count
        return HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barras, id: \.self) { i in
                let n: Float? = i >= vazias ? historico[i - vazias] : nil
                let recente = i >= barras - 7
                Rectangle()
                    .fill(n == nil ? p.line.color : (recente ? esquema.destaque : p.text2.color))
                    .frame(height: 6 + CGFloat(n ?? 0) * 110)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 130)
        .accessibilityHidden(true)
    }

    private func mini(_ rotulo: String, _ valor: String, _ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Rotulo(rotulo)
            Text(valor).font(.display(18, .heavy, relativeTo: .headline)).foregroundStyle(p.text.color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cartao(p, padding: 12)
    }

    /// Estimativa: AAC a 24 kbps ≈ 3 KB por segundo.
    static func tamanho(_ segundos: TimeInterval) -> String {
        let mb = max(0, segundos) * 3000 / 1_000_000
        return String(format: "%.1f MB", mb).replacingOccurrences(of: ".", with: ",")
    }
}
