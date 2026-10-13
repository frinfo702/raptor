import AppKit
import Testing
@testable import Ghostty

/// The tokens reproduce Rex's chrome colours sampled from its reference frames.
struct ThemeTokensTests {
    private func hex(_ color: NSColor) -> [Int] {
        let c = color.usingColorSpace(.sRGB)!
        return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
    }

    private func expectNear(_ color: NSColor, _ rgb: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        let want = [(rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF]
        let got = hex(color)
        #expect(zip(got, want).allSatisfy { abs($0 - $1) <= 2 }, "got \(got), want \(want)", sourceLocation: sourceLocation)
    }

    private func color(_ rgb: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1)
    }

    @Test func darkCarbonfox() {
        let t = ThemeTokens(background: color(0x161616))
        #expect(!t.isLight)
        expectNear(t.chrome, 0x131313)
        expectNear(t.hairline, 0x242424)
    }

    /// v2: the divider, and the chrome that unfocused compact headers show.
    @Test func darkTeal() {
        let t = ThemeTokens(background: color(0x0F1518))
        expectNear(t.chrome, 0x0B1212)
        expectNear(t.hairline, 0x1E2226)
    }

    /// v1 islands: the gutter between cards and the cards' border.
    @Test func darkIslands() {
        let t = ThemeTokens(background: color(0x131313))
        expectNear(t.chrome, 0x111111)
        expectNear(t.islandBorder, 0x262626)
    }

    @Test func light() {
        let t = ThemeTokens(background: color(0xF8F6FB))
        #expect(t.isLight)
        expectNear(t.chrome, 0xFDFBFF)
        expectNear(t.separator, 0xCECCD1)
    }

    /// v3: the command palette and its search field.
    @Test func darkPalette() {
        let t = ThemeTokens(background: color(0x232831))
        expectNear(t.popover, 0x30343F)
        expectNear(t.field, 0x424752)
    }
}
