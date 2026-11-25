import CryptoKit
import Foundation

// Espelha pc/rumo_pc/protocol.py: JSON UTF-8 em snake_case, v == 1, cifrado com Crypto.

/// UUID que sai sempre em minúsculas (o PC compara strings).
struct ID: Codable, Hashable {
    let uuid: UUID
    init(_ uuid: UUID) { self.uuid = uuid }
    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let u = UUID(uuidString: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "UUID inválido."))
        }
        uuid = u
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(uuid.uuidString.lowercased())
    }
}

/// ISO-8601 com offset ("2026-01-15T10:30:00-03:00"), como o Python `datetime.fromisoformat` exige.
/// Guarda o offset para o JSON reemitido ser idêntico ao lido.
struct Instante: Codable, Equatable {
    let date: Date
    let offset: Int

    init(_ date: Date, offset: Int? = nil) {
        self.date = date
        self.offset = offset ?? TimeZone.current.secondsFromGMT(for: date)
    }

    private static func formatter(_ offset: Int) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(secondsFromGMT: offset)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxxxx"
        return f
    }

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        // aceita segundos fracionários (o Python emite microssegundos) e "Z" ou ±HH:MM
        let re = try NSRegularExpression(pattern: #"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)$"#)
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let base = Range(m.range(at: 1), in: s), let zone = Range(m.range(at: 3), in: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Data sem fuso horário."))
        }
        let z = String(s[zone])
        var off = 0
        if z != "Z" {
            off = (Int(z.dropFirst().prefix(2))! * 3600 + Int(z.suffix(2))! * 60) * (z.hasPrefix("-") ? -1 : 1)
        }
        guard var d = Self.formatter(off).date(from: String(s[base]) + (z == "Z" ? "+00:00" : z)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Data inválida."))
        }
        if let fr = Range(m.range(at: 2), in: s), let frac = Double("0" + s[fr]) { d.addTimeInterval(frac) }
        self.date = d
        self.offset = off
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(Self.formatter(offset).string(from: date))
    }
}

struct Cofre: Codable, Equatable { var nome: String; var cliente: Bool }

struct NotaAudio: Codable, Equatable {
    var notaId: ID, cofre: String, audio: Data, duracaoS: Int
    enum CodingKeys: String, CodingKey { case notaId = "nota_id", cofre, audio, duracaoS = "duracao_s" }
}
struct NotaAudioParte: Codable, Equatable {
    var notaId: ID, cofre: String, parte: Int, totalPartes: Int, audio: Data, duracaoS: Int?  // duracao_s obrigatório na parte 1
    enum CodingKeys: String, CodingKey {
        case notaId = "nota_id", cofre, parte, totalPartes = "total_partes", audio, duracaoS = "duracao_s"
    }
}
struct NotaTexto: Codable, Equatable {
    var notaId: ID, cofre: String, texto: String
    enum CodingKeys: String, CodingKey { case notaId = "nota_id", cofre, texto }
}
struct Complemento: Codable, Equatable {  // ou texto, ou audio com duracao_s
    var notaId: ID, complementoId: ID, audio: Data?, duracaoS: Int?, texto: String?
    enum CodingKeys: String, CodingKey {
        case notaId = "nota_id", complementoId = "complemento_id", audio, duracaoS = "duracao_s", texto
    }
}
struct NovoCofre: Codable, Equatable { var nome: String; var cliente: Bool }
struct Mover: Codable, Equatable {
    var notaId: ID, destino: String
    enum CodingKeys: String, CodingKey { case notaId = "nota_id", destino }
}
struct Resultado: Codable, Equatable {
    enum Status: String, Codable { case processado, erro }
    var notaId: ID, status: Status, titulo: String, tipo: String, resumo: String, cofre: String
    var clienteSugerido: String?, pontos: Int, emAberto: Int, erro: String?
    enum CodingKeys: String, CodingKey {
        case notaId = "nota_id", status, titulo, tipo, resumo, cofre
        case clienteSugerido = "cliente_sugerido", pontos, emAberto = "em_aberto", erro
    }
    // o Python exige as chaves cliente_sugerido e erro presentes (null explícito)
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(notaId, forKey: .notaId); try c.encode(status, forKey: .status)
        try c.encode(titulo, forKey: .titulo); try c.encode(tipo, forKey: .tipo)
        try c.encode(resumo, forKey: .resumo); try c.encode(cofre, forKey: .cofre)
        try c.encode(clienteSugerido, forKey: .clienteSugerido)
        try c.encode(pontos, forKey: .pontos); try c.encode(emAberto, forKey: .emAberto)
        try c.encode(erro, forKey: .erro)
    }
}
struct Destinos: Codable, Equatable {
    var cofres: [Cofre], atualizadoEm: Instante
    enum CodingKeys: String, CodingKey { case cofres, atualizadoEm = "atualizado_em" }
}

struct Msg: Equatable {
    enum Corpo: Equatable {
        case notaAudio(NotaAudio), notaAudioParte(NotaAudioParte), notaTexto(NotaTexto), complemento(Complemento)
        case novoCofre(NovoCofre), mover(Mover), resultado(Resultado), destinos(Destinos)
    }
    var id: ID
    var criadoEm: Instante
    var corpo: Corpo

    var tipo: String {
        switch corpo {
        case .notaAudio: return "nota_audio"
        case .notaAudioParte: return "nota_audio_parte"
        case .notaTexto: return "nota_texto"
        case .complemento: return "complemento"
        case .novoCofre: return "novo_cofre"
        case .mover: return "mover"
        case .resultado: return "resultado"
        case .destinos: return "destinos"
        }
    }

    func json() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return try e.encode(self)
    }
    static func decode(_ json: Data) throws -> Msg { try JSONDecoder().decode(Msg.self, from: json) }
    func sealed(key: SymmetricKey) throws -> Data { try Crypto.seal(json(), key: key) }
    static func open(_ blob: Data, key: SymmetricKey) throws -> Msg { try decode(Crypto.open(blob, key: key)) }
}

extension Msg: Codable {
    private enum K: String, CodingKey { case v, id, criadoEm = "criado_em", tipoMsg = "tipo_msg" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        func invalido(_ k: K, _ msg: String) -> DecodingError { .dataCorruptedError(forKey: k, in: c, debugDescription: msg) }
        guard try c.decode(Int.self, forKey: .v) == 1 else { throw invalido(.v, "Versão do protocolo não suportada.") }
        id = try c.decode(ID.self, forKey: .id)
        criadoEm = try c.decode(Instante.self, forKey: .criadoEm)
        switch try c.decode(String.self, forKey: .tipoMsg) {
        case "nota_audio": corpo = .notaAudio(try NotaAudio(from: decoder))
        case "nota_audio_parte":
            let p = try NotaAudioParte(from: decoder)
            guard p.parte >= 1, p.parte <= p.totalPartes, p.parte != 1 || p.duracaoS != nil else {
                throw invalido(.tipoMsg, "Parte fora do intervalo ou sem duração.")
            }
            corpo = .notaAudioParte(p)
        case "nota_texto": corpo = .notaTexto(try NotaTexto(from: decoder))
        case "complemento":
            let p = try Complemento(from: decoder)
            guard p.texto != nil || (p.audio != nil && p.duracaoS != nil) else {
                throw invalido(.tipoMsg, "Complemento precisa de texto ou de áudio com duração.")
            }
            corpo = .complemento(p)
        case "novo_cofre": corpo = .novoCofre(try NovoCofre(from: decoder))
        case "mover": corpo = .mover(try Mover(from: decoder))
        case "resultado": corpo = .resultado(try Resultado(from: decoder))
        case "destinos": corpo = .destinos(try Destinos(from: decoder))
        default: throw invalido(.tipoMsg, "tipo_msg desconhecido.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(1, forKey: .v)
        try c.encode(id, forKey: .id)
        try c.encode(criadoEm, forKey: .criadoEm)
        try c.encode(tipo, forKey: .tipoMsg)
        switch corpo {  // campos do corpo ficam no mesmo nível (JSON plano)
        case .notaAudio(let p): try p.encode(to: encoder)
        case .notaAudioParte(let p): try p.encode(to: encoder)
        case .notaTexto(let p): try p.encode(to: encoder)
        case .complemento(let p): try p.encode(to: encoder)
        case .novoCofre(let p): try p.encode(to: encoder)
        case .mover(let p): try p.encode(to: encoder)
        case .resultado(let p): try p.encode(to: encoder)
        case .destinos(let p): try p.encode(to: encoder)
        }
    }
}
