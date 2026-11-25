import SwiftData
import SwiftUI

/// Início (painel de bordo).
struct HomeView: View {
    @Environment(\.colorScheme) private var esquema
    @Query(sort: \Item.criadoEm, order: .reverse) private var itens: [Item]
    @AppStorage("nomeUsuario") private var nome = ""
    @AppStorage(Recorder.chaveUltimoCofre) private var ultimoCofre = ""
    private let sync = Sync.shared

    let cofres: [Cofre]
    let aoGravar: (String) -> Void
    let aoNovoCofre: () -> Void
    let aoDigitar: () -> Void
    let aoDiario: () -> Void
    let aoAjustes: () -> Void

    private var cofreAtual: String? {
        cofres.first { $0.nome == ultimoCofre }?.nome ?? cofres.first?.nome
    }

    var body: some View {
        let p = esquema.paleta
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let erro = sync.ultimoErro { aviso(erro, p) }
                    cabecalho(p)
                    cartoes(p)
                    ideiasPorCofre(p)
                    ultimaNota(p)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
            }
            .refreshable { await Sync.shared.run() }
            rodape(p)
        }
    }

    // MARK: Partes

    private func aviso(_ texto: String, _ p: Palette) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Icone("exclamationmark.triangle")
            Text(texto).font(.text(14, relativeTo: .callout))
        }
        .foregroundStyle(p.text.color)
        .padding(12)
        .etiqueta(borda: p.text.color)
        .padding(.top, 8)
    }

    private func cabecalho(_ p: Palette) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let pc = Stats.pc(ultimoResultado: itens.compactMap(\.processadoEm).max(), agora: ctx.date)
            let hora = Calendar.current.component(.hour, from: ctx.date)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(Self.dataExtenso(ctx.date)).font(.text(13, .medium, relativeTo: .footnote)).foregroundStyle(p.text2.color)
                    Spacer()
                    HStack(spacing: 6) {
                        Rectangle().fill(pc.online ? esquema.destaque : p.text2.color).frame(width: 7, height: 7)
                        Text(pc.texto).font(.text(12, .medium, relativeTo: .caption)).foregroundStyle(p.text2.color)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(Stats.saudacao(hora: hora, nome: nome))
                        .font(.display(28, relativeTo: .title)).foregroundStyle(p.text.color)
                        .minimumScaleFactor(0.7).lineLimit(2)
                    Spacer()
                    Button(action: aoDiario) { Icone("book").frame(width: 44, height: 44) }
                        .accessibilityLabel("Diário")
                    Button(action: aoAjustes) { Icone("gearshape").frame(width: 44, height: 44) }
                        .accessibilityLabel("Ajustes")
                }
                .foregroundStyle(p.text.color)
            }
            .padding(.top, 8)
        }
    }

    private func cartoes(_ p: Palette) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let s = Stats.semana(itens: itens, hoje: ctx.date)
            let hoje = Stats.indiceDoDia(ctx.date)
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 8) {
                    Rotulo("Na semana")
                    HStack(alignment: .bottom, spacing: 12) {
                        Text("\(s.total)").font(.display(44, .heavy, relativeTo: .largeTitle))
                            .foregroundStyle(esquema.destaque).monospacedDigit()
                        miniGrafico(s.porDia, hoje: hoje, p)
                    }
                    Text(Self.delta(s.deltaSemanaPassada)).font(.text(12, .medium, relativeTo: .caption))
                        .foregroundStyle(p.text2.color).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .cartao(p)
                .layoutPriority(1)
                VStack(spacing: 10) {
                    numero("Na fila", s.fila, p)
                    numero("Minutos", s.minutos, p)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 16)
        }
    }

    private func numero(_ rotulo: String, _ valor: Int, _ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Rotulo(rotulo)
            Text("\(valor)").font(.display(30, .heavy, relativeTo: .title)).foregroundStyle(p.text.color).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cartao(p)
    }

    private func miniGrafico(_ porDia: [Int], hoje: Int, _ p: Palette) -> some View {
        let maior = CGFloat(max(1, porDia.max() ?? 1))
        let barra = esquema == .dark ? Color.white.opacity(0.28) : Theme.azul.color.opacity(0.22)
        return VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<7, id: \.self) { i in
                    Rectangle().fill(i == hoje ? esquema.destaque : barra)
                        .frame(height: max(3, 46 * CGFloat(porDia[i]) / maior))
                }
            }
            .frame(width: 62, height: 46, alignment: .bottom)
            HStack(spacing: 3) {
                ForEach(Array("STQQSSD".enumerated()), id: \.offset) { _, d in
                    Text(String(d)).font(.display(9, relativeTo: .caption2)).foregroundStyle(p.text2.color).frame(maxWidth: .infinity)
                }
            }
            .frame(width: 62)
        }
        .accessibilityHidden(true)
    }

    private func ideiasPorCofre(_ p: Palette) -> some View {
        let s = Stats.semana(itens: itens, hoje: Date())
        let maior = CGFloat(max(1, s.porCofre.map(\.1).max() ?? 1))
        return VStack(alignment: .leading, spacing: 9) {
            Rotulo("Ideias por cofre")
            if s.porCofre.isEmpty {
                Text("Nenhuma ideia nesta semana.").font(.text(14, relativeTo: .callout)).foregroundStyle(p.text2.color)
            }
            ForEach(Array(s.porCofre.prefix(5).enumerated()), id: \.offset) { _, linha in
                HStack(spacing: 10) {
                    Text(linha.0).font(.text(14, .medium, relativeTo: .callout)).foregroundStyle(p.text.color)
                        .lineLimit(1).frame(width: 92, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(p.line.color)
                            Rectangle().fill(p.text.color).frame(width: g.size.width * CGFloat(linha.1) / maior)
                        }
                    }
                    .frame(height: 6)
                    Text("\(linha.1)").font(.display(14, .heavy, relativeTo: .callout)).foregroundStyle(p.text.color)
                        .frame(width: 24, alignment: .trailing)
                }
            }
        }
        .padding(.top, 16)
    }

    @ViewBuilder
    private func ultimaNota(_ p: Palette) -> some View {
        if let i = itens.first {
            VStack(alignment: .leading, spacing: 8) {
                Rotulo("Última nota")
                VStack(alignment: .leading, spacing: 3) {
                    Text(i.titulo ?? "Gravação de \(Stats.duracao(i.duracaoS))")
                        .font(.display(16, relativeTo: .headline)).foregroundStyle(p.text.color)
                    Text("\(Self.hora(i.criadoEm)) · \(i.cofre) · \(Stats.duracao(i.duracaoS)) · \(i.estado.rotulo)")
                        .font(.text(12, relativeTo: .caption)).foregroundStyle(p.text2.color)
                    if let r = i.resumo, !r.isEmpty {
                        Text(r).font(.text(14, relativeTo: .callout)).foregroundStyle(p.text.color).lineLimit(3).padding(.top, 3)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(esquema.destaque).frame(width: 2) }
            }
            .padding(.top, 16)
        }
    }

    private func rodape(_ p: Palette) -> some View {
        VStack(spacing: 0) {
            HStack {
                Rotulo("Cofre")
                Spacer()
                Button("Digitar nota", action: aoDigitar)
                    .font(.text(12, .medium, relativeTo: .caption)).foregroundStyle(p.text2.color)
            }
            .padding(.horizontal, 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(cofres, id: \.nome) { c in
                        let ativo = c.nome == cofreAtual
                        Button { ultimoCofre = c.nome } label: {
                            Text(c.nome).font(.display(12, relativeTo: .caption))
                                .foregroundStyle(ativo ? p.text.color : p.text2.color)
                                .padding(.horizontal, 9).frame(minHeight: 32)
                                .etiqueta(borda: ativo ? p.text.color : p.line.color)
                        }
                    }
                    Button(action: aoNovoCofre) {
                        Text("+ Novo cofre").font(.display(12, relativeTo: .caption)).foregroundStyle(p.text2.color)
                            .padding(.horizontal, 9).frame(minHeight: 32)
                            .etiqueta(borda: p.line.color)
                    }
                }
                .padding(.horizontal, 18)
            }
            .padding(.vertical, 10)
            if cofres.isEmpty {
                Text("Ainda não recebi a lista de cofres do PC. Puxe a tela para baixo para sincronizar.")
                    .font(.text(12, relativeTo: .caption)).foregroundStyle(p.text2.color)
                    .padding(.horizontal, 18).padding(.bottom, 8)
            }
            FaixaPrincipal("Gravar ideia", acao: { if let c = cofreAtual { aoGravar(c) } }) { Icone("mic") }
                .opacity(cofreAtual == nil ? 0.5 : 1)
                .disabled(cofreAtual == nil)
        }
    }

    // MARK: Formatação

    static func delta(_ d: Int) -> String {
        d > 0 ? "+\(d) que na semana passada" : d < 0 ? "\(d) que na semana passada" : "igual à semana passada"
    }

    static func hora(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func dataExtenso(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "EEEE, d 'de' MMMM"
        let t = f.string(from: d)
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}
