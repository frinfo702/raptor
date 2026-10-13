import AppKit

/// Chrome colours derived from the terminal background: each one is the background moved
/// in OKLab lightness, keeping its chroma and hue, so the chrome is tinted by the theme.
/// Shifts go toward the far end from the background: lighter on dark themes, darker on light.
struct ThemeTokens {
    /// The title bar.
    let chrome: NSColor
    /// The active tab's pill.
    let tabActive: NSColor
    /// Hairlines and split dividers.
    let hairline: NSColor
    /// Separators between inactive tabs on light themes.
    let separator: NSColor
    /// The border around island cards.
    let islandBorder: NSColor
    let isLight: Bool

    // Popover and field tokens come with the UI that uses them.
    init(background: NSColor) {
        isLight = background.isLightColor
        let lab = OKLab(background)
        let s = isLight ? -1.0 : 1.0
        chrome = lab.shifted(-0.016 * s)
        tabActive = lab.shifted(0.03 * s)
        hairline = lab.shifted(0.06 * s)
        separator = lab.shifted(0.13 * s)
        islandBorder = lab.shifted(0.08 * s)
    }
}

/// A colour in OKLab (Björn Ottosson's), for lightness shifts that keep the hue.
private struct OKLab {
    let lightness: Double
    let a: Double
    let b: Double

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        let r = Self.linear(c.redComponent), g = Self.linear(c.greenComponent), bl = Self.linear(c.blueComponent)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
        lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    /// This colour with lightness moved by `dL`, back in sRGB.
    func shifted(_ dL: Double) -> NSColor {
        let lit = lightness + dL
        let l = pow(lit + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lit - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lit - 0.0894841775 * a - 1.2914855480 * b, 3)
        return NSColor(
            srgbRed: Self.gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            green: Self.gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            blue: Self.gamma(-0.0042119520 * l - 0.7034186147 * m + 1.7076147010 * s),
            alpha: 1)
    }

    private static func linear(_ c: CGFloat) -> Double {
        let c = Double(c)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func gamma(_ c: Double) -> CGFloat {
        let c = min(max(c, 0), 1)
        return CGFloat(c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055)
    }
}
