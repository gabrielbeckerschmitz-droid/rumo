import XCTest
import UIKit
@testable import Rumo

final class ThemeTests: XCTestCase {
    func testTextOnTurquoiseIsDeepBlue() {
        // texto sobre turquesa é sempre azul-profundo, com contraste AA
        XCTAssertGreaterThanOrEqual(contrastRatio(Theme.azul, Theme.turquesa), 4.5)
        // turquesa nunca é texto sobre creme ou branco
        XCTAssertLessThan(contrastRatio(Theme.turquesa, Theme.creme), 4.5)
        XCTAssertLessThan(contrastRatio(Theme.turquesa, Theme.branco), 4.5)
    }

    func testDarkPaletteValues() {
        let d = Theme.dark
        XCTAssertEqual(d.bg, RGBA(hex: 0x18354B))
        XCTAssertEqual(d.text, RGBA(hex: 0xFFFFFF))
        XCTAssertEqual(d.text2, RGBA(hex: 0xFFFFFF, alpha: 0.74))
        XCTAssertEqual(d.card, RGBA(hex: 0xFFFFFF, alpha: 0.07))
        XCTAssertEqual(d.line, RGBA(hex: 0xFFFFFF, alpha: 0.2))
        XCTAssertEqual(Theme.turquesa, RGBA(hex: 0x28C5B8))
        XCTAssertEqual(Theme.creme, RGBA(hex: 0xF2F0E9))
    }

    func testLightPaletteValues() {
        let l = Theme.light
        XCTAssertEqual(l.bg, Theme.creme)
        XCTAssertEqual(l.text, Theme.azul)
        XCTAssertEqual(l.text2, RGBA(hex: 0x18354B, alpha: 0.72))
        XCTAssertEqual(l.card, Theme.branco)
        XCTAssertEqual(l.line, RGBA(hex: 0x18354B, alpha: 0.18))
    }

    func testRadii() {
        XCTAssertEqual(Theme.Radius.bloco, 0)
        XCTAssertEqual(Theme.Radius.botao, 4)
        XCTAssertEqual(Theme.Radius.cartao, 12)
    }

    func testContrastKnownValues() {
        XCTAssertEqual(contrastRatio(RGBA(hex: 0xFFFFFF), RGBA(hex: 0x000000)), 21, accuracy: 0.01)
        XCTAssertEqual(contrastRatio(Theme.azul, Theme.azul), 1, accuracy: 0.001)
    }

    func testContrastPairsAA() {
        for p in [Theme.dark, Theme.light] {
            let card = p.card.over(p.bg)
            let pairs: [(RGBA, RGBA)] = [(p.text, p.bg), (p.text2, p.bg), (p.text, card), (p.text2, card)]
            for (fg, bg) in pairs {
                XCTAssertGreaterThanOrEqual(contrastRatio(fg, bg), 4.5)
            }
        }
    }

    func testFontsAreBundled() {
        for n in ["RedHatDisplay-Bold", "RedHatDisplay-ExtraBold", "RedHatText-Regular", "RedHatText-Medium"] {
            XCTAssertNotNil(UIFont(name: n, size: 12), n)
        }
    }
}
