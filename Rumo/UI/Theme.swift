import SwiftUI

/// Cor sRGB com alfa; valores exatos, sem arredondar.
struct RGBA: Equatable {
    var r: Double, g: Double, b: Double, a: Double

    init(hex: UInt32, alpha: Double = 1) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        a = alpha
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    /// Composição desta cor (com alfa) sobre um fundo opaco.
    func over(_ bg: RGBA) -> RGBA {
        RGBA(r: r * a + bg.r * (1 - a), g: g * a + bg.g * (1 - a), b: b * a + bg.b * (1 - a), a: 1)
    }

    private init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

struct Palette {
    let bg, text, text2, card, line: RGBA
}

enum Theme {
    static let azul = RGBA(hex: 0x18354B)
    static let turquesa = RGBA(hex: 0x28C5B8)
    static let creme = RGBA(hex: 0xF2F0E9)
    static let branco = RGBA(hex: 0xFFFFFF)

    static let dark = Palette(
        bg: azul, text: branco,
        text2: RGBA(hex: 0xFFFFFF, alpha: 0.74),
        card: RGBA(hex: 0xFFFFFF, alpha: 0.07),
        line: RGBA(hex: 0xFFFFFF, alpha: 0.2))

    static let light = Palette(
        bg: creme, text: azul,
        text2: RGBA(hex: 0x18354B, alpha: 0.72),
        card: branco,
        line: RGBA(hex: 0x18354B, alpha: 0.18))

    enum Radius {
        static let bloco: CGFloat = 0
        static let botao: CGFloat = 4
        static let cartao: CGFloat = 12
    }
}

extension Font {
    /// Red Hat Display: 700 (bold) ou 800 (heavy e acima).
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        let heavy = weight == .heavy || weight == .black
        return .custom(heavy ? "RedHatDisplay-ExtraBold" : "RedHatDisplay-Bold", size: size)
    }

    /// Red Hat Text: 400 (regular) ou 500 (medium e acima).
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let medium = weight == .medium || weight == .semibold || weight == .bold || weight == .heavy || weight == .black
        return .custom(medium ? "RedHatText-Medium" : "RedHatText-Regular", size: size)
    }
}

/// Razão de contraste WCAG 2.x. `fg` com alfa é composto sobre `bg` (que deve ser opaco).
func contrastRatio(_ fg: RGBA, _ bg: RGBA) -> Double {
    func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    func lum(_ c: RGBA) -> Double { 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b) }
    let l1 = lum(fg.over(bg)), l2 = lum(bg)
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
}
