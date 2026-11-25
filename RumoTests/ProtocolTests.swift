import XCTest
import CryptoKit
@testable import Rumo

final class ProtocolTests: XCTestCase {
    private func messages() throws -> [[String: String]] {
        try XCTUnwrap(Vectors.load()["messages"] as? [[String: String]])
    }

    private let head = #""v":1,"id":"00000000-0000-4000-8000-000000000001","criado_em":"2026-01-15T10:30:00-03:00""#
    private let n2 = "00000000-0000-4000-8000-000000000002"

    func testDecodesAllPythonMessages() throws {
        var tipos = Set<String>()
        for r in try messages() {
            let key = SymmetricKey(data: Data(base64Encoded: r["key_b64"]!)!)
            let msg = try Msg.open(Data(base64Encoded: r["blob_b64"]!)!, key: key)
            let obj = try JSONSerialization.jsonObject(with: Data(r["json"]!.utf8)) as! [String: Any]
            tipos.insert(obj["tipo_msg"] as! String)
            XCTAssertEqual(msg.tipo, obj["tipo_msg"] as? String)
            XCTAssertEqual(msg.id.uuid.uuidString.lowercased(), obj["id"] as? String)
        }
        XCTAssertEqual(tipos.count, 8)
    }

    func testEncodeRoundTrip() throws {
        for r in try messages() {
            let key = SymmetricKey(data: Data(base64Encoded: r["key_b64"]!)!)
            let msg = try Msg.open(Data(base64Encoded: r["blob_b64"]!)!, key: key)
            // o JSON re-codificado é igual ao JSON do Python (inclui null explícito e offset)
            let again = try JSONSerialization.jsonObject(with: msg.json()) as! NSDictionary
            let orig = try JSONSerialization.jsonObject(with: Data(r["json"]!.utf8)) as! NSDictionary
            XCTAssertEqual(again, orig)
            XCTAssertEqual(try Msg.open(msg.sealed(key: key), key: key), msg)
        }
    }

    func testDecodesFractionalSecondsAndUTC() throws {
        let m = try Msg.decode(Data(#"{"v":1,"id":"00000000-0000-4000-8000-000000000001","criado_em":"2026-01-15T13:30:00.123456+00:00","tipo_msg":"mover","nota_id":"\#(n2)","destino":"Cofre A"}"#.utf8))
        guard case .mover(let p) = m.corpo else { return XCTFail("tipo") }
        XCTAssertEqual(p.destino, "Cofre A")
        XCTAssertEqual(m.criadoEm.date.timeIntervalSince1970, 1768483800.123456, accuracy: 0.001)
        let z = try Msg.decode(Data(#"{"v":1,"id":"00000000-0000-4000-8000-000000000001","criado_em":"2026-01-15T13:30:00Z","tipo_msg":"mover","nota_id":"\#(n2)","destino":"X"}"#.utf8))
        XCTAssertEqual(z.criadoEm.date.timeIntervalSince1970, 1768483800)
    }

    func testRejectsInvalid() {
        func bad(_ json: String) { XCTAssertThrowsError(try Msg.decode(Data(json.utf8)), json) }
        bad(#"{\#(head),"tipo_msg":"desconhecido"}"#)
        bad(#"{"v":2,"id":"00000000-0000-4000-8000-000000000001","criado_em":"2026-01-15T10:30:00-03:00","tipo_msg":"novo_cofre","nome":"X","cliente":true}"#)
        bad(#"{\#(head),"tipo_msg":"novo_cofre","nome":"X"}"#)
        bad(#"{"v":1,"id":"00000000-0000-4000-8000-000000000001","criado_em":"2026-01-15T10:30:00","tipo_msg":"novo_cofre","nome":"X","cliente":true}"#)
        bad(#"{\#(head),"tipo_msg":"nota_audio_parte","nota_id":"\#(n2)","cofre":"A","parte":3,"total_partes":2,"audio":"YQ=="}"#)
        bad(#"{\#(head),"tipo_msg":"complemento","nota_id":"\#(n2)","complemento_id":"00000000-0000-4000-8000-000000000003"}"#)
        bad(#"{\#(head),"tipo_msg":"resultado","nota_id":"\#(n2)","status":"talvez","titulo":"t","tipo":"i","resumo":"r","cofre":"A","cliente_sugerido":null,"pontos":1,"em_aberto":0,"erro":null}"#)
    }

    func testEncodedDateHasOffsetForPython() throws {
        let m = Msg(id: ID(UUID()), criadoEm: Instante(Date(timeIntervalSince1970: 1768483800), offset: -10800),
                    corpo: .novoCofre(NovoCofre(nome: "Cofre A", cliente: false)))
        let obj = try JSONSerialization.jsonObject(with: m.json()) as! [String: Any]
        XCTAssertEqual(obj["criado_em"] as? String, "2026-01-15T10:30:00-03:00")
        XCTAssertEqual(obj["v"] as? Int, 1)
    }

    func testPareamentoFromQR() throws {
        let k = Data((0..<32).map { UInt8($0) }).base64EncodedString()
        let p = try Pareamento.fromQR(#"{"v":1,"chave":"\#(k)","token":"tok-sintetico","dono":"dono-x","repo":"caixa-x"}"#)
        XCTAssertEqual(p.chave.count, 32)
        XCTAssertEqual(p.token, "tok-sintetico")
        XCTAssertEqual(p.dono, "dono-x")
        XCTAssertEqual(p.repo, "caixa-x")
        let short = Data(count: 16).base64EncodedString()
        XCTAssertThrowsError(try Pareamento.fromQR(#"{"v":1,"chave":"\#(short)","token":"t","dono":"d","repo":"r"}"#))
        XCTAssertThrowsError(try Pareamento.fromQR(#"{"v":2,"chave":"\#(k)","token":"t","dono":"d","repo":"r"}"#))
        XCTAssertThrowsError(try Pareamento.fromQR("não é json"))
    }
}
