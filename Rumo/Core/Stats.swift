import Foundation

/// Números do painel. Funções puras (a UI só desenha).
enum Stats {
    struct Semana {
        var total = 0
        var porDia = [Int](repeating: 0, count: 7)  // segunda → domingo
        var minutos = 0
        var fila = 0
        var porCofre: [(String, Int)] = []  // pelo cofre de DESTINO (Item.cofre), mais ideias primeiro
        var deltaSemanaPassada = 0
    }

    static var calendarioPadrao: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.locale = Locale(identifier: "pt_BR")
        return c
    }

    /// Semana (segunda a domingo) que contém `hoje`. `fila` = todos os itens ainda não processados.
    static func semana(itens: [Item], hoje: Date, calendario: Calendar = Stats.calendarioPadrao) -> Semana {
        var s = Semana()
        s.fila = itens.filter { $0.estado != .processado }.count
        guard let inicio = calendario.dateInterval(of: .weekOfYear, for: hoje)?.start,
              let fim = calendario.date(byAdding: .day, value: 7, to: inicio),
              let anterior = calendario.date(byAdding: .day, value: -7, to: inicio) else { return s }
        var segundos = 0
        var cofres: [String: Int] = [:]
        var passada = 0
        for i in itens {
            if i.criadoEm >= anterior && i.criadoEm < inicio { passada += 1 }
            guard i.criadoEm >= inicio && i.criadoEm < fim else { continue }
            let dia = calendario.dateComponents([.day], from: inicio, to: calendario.startOfDay(for: i.criadoEm)).day ?? 0
            s.porDia[min(max(dia, 0), 6)] += 1
            segundos += i.duracaoS
            cofres[i.cofre, default: 0] += 1
        }
        s.total = s.porDia.reduce(0, +)
        s.minutos = Int((Double(segundos) / 60).rounded())
        s.porCofre = cofres.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { ($0.key, $0.value) }
        s.deltaSemanaPassada = s.total - passada
        return s
    }

    /// 0 = segunda … 6 = domingo.
    static func indiceDoDia(_ data: Date, calendario: Calendar = Stats.calendarioPadrao) -> Int {
        (calendario.component(.weekday, from: data) + 5) % 7
    }

    /// "PC online" se o último resultado chegou há menos de 15 min; senão diz há quanto tempo.
    static func pc(ultimoResultado: Date?, agora: Date) -> (online: Bool, texto: String) {
        guard let u = ultimoResultado else { return (false, "PC sem resposta") }
        let seg = agora.timeIntervalSince(u)
        if seg < 15 * 60 { return (true, "PC online") }
        let tempo: String
        switch seg {
        case ..<3600: tempo = "\(Int(seg / 60)) min"
        case ..<86_400: tempo = "\(Int(seg / 3600)) h"
        default:
            let d = Int(seg / 86_400)
            tempo = d == 1 ? "1 dia" : "\(d) dias"
        }
        return (false, "PC sem resposta há \(tempo)")
    }

    static func saudacao(hora: Int, nome: String) -> String {
        let base = hora >= 5 && hora < 12 ? "Bom dia" : hora >= 12 && hora < 18 ? "Boa tarde" : "Boa noite"
        let n = nome.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? base : "\(base), \(n)"
    }
}

extension Stats {
    /// "45s", "2min", "3min12s".
    static func duracao(_ s: Int) -> String {
        let s = max(0, s)
        if s < 60 { return "\(s)s" }
        return s % 60 == 0 ? "\(s / 60)min" : "\(s / 60)min\(s % 60)s"
    }

    /// Cronômetro "03:12" (ou "1:03:12" a partir de 1 h).
    static func cronometro(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        let h = s / 3600, m = (s / 60) % 60, seg = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, seg) : String(format: "%02d:%02d", m, seg)
    }
}
