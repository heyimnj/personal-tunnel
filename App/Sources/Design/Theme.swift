import SwiftUI
import UIKit

/// Colours and shapes of the current appearance.
///
/// Connection colours (connected, connecting, failed) are semantic and do not
/// follow the accent.
struct Palette {
    let appearance: Appearance
    let scheme: ColorScheme
    let accent: Color
    let onAccent: Color
    /// Screen background.
    let background: Color
    /// Cards and collapsed subscriptions.
    let surface: Color
    /// An expanded subscription: almost the background tone.
    let container: Color
    /// Server cards inside an expanded subscription.
    let inner: Color
    let accentContainer: Color
    let onAccentContainer: Color
    let primaryText: Color
    let secondaryText: Color
    let separator: Color

    let connected = Color(red: 0.20, green: 0.78, blue: 0.35)
    let connecting = Color(red: 1.00, green: 0.62, blue: 0.04)
    let failed = Color(red: 1.00, green: 0.23, blue: 0.19)

    var cardRadius: CGFloat { appearance == .material ? 28 : 22 }
    var innerRadius: CGFloat { appearance == .material ? 20 : 14 }
    var collapsedRadius: CGFloat { appearance == .material ? 28 : 24 }
    var usesRoundedFont: Bool { appearance == .material }

    static func make(settings: AppSettings, scheme: ColorScheme) -> Palette {
        let seed = UIColor(hex: settings.accentHex) ?? UIColor(hex: settings.appearance.defaultAccentHex)!
        let dark = scheme == .dark
        let black = dark && settings.amoled
        switch settings.appearance {
        case .material:
            let tones = TonalScheme(seed: seed)
            return Palette(
                appearance: .material,
                scheme: scheme,
                accent: Color(tones.primary.tone(dark ? 80 : 40)),
                onAccent: Color(tones.primary.tone(dark ? 20 : 100)),
                background: black ? .black : Color(tones.neutral.tone(dark ? 6 : 98)),
                surface: Color(tones.neutral.tone(dark ? 17 : 92)),
                container: Color(tones.neutral.tone(dark ? 12 : 94)),
                inner: Color(tones.neutral.tone(dark ? 22 : 99)),
                accentContainer: Color(tones.secondary.tone(dark ? 30 : 90)),
                onAccentContainer: Color(tones.secondary.tone(dark ? 90 : 10)),
                primaryText: Color(tones.neutral.tone(dark ? 92 : 10)),
                secondaryText: Color(tones.neutralVariant.tone(dark ? 80 : 30)),
                separator: Color(tones.neutralVariant.tone(dark ? 30 : 80))
            )
        case .modern, .classic:
            let accent = Color(seed)
            let background: Color = black ? .black : Color(uiColor: .systemGroupedBackground)
            let surface: Color = black ? Color(white: 0.09) : Color(uiColor: .secondarySystemGroupedBackground)
            let container: Color = black ? Color(white: 0.05) : Color(uiColor: dark ? UIColor(white: 0.08, alpha: 1) : UIColor(white: 0.965, alpha: 1))
            let inner: Color = black ? Color(white: 0.12) : Color(uiColor: .secondarySystemGroupedBackground)
            return Palette(
                appearance: settings.appearance,
                scheme: scheme,
                accent: accent,
                onAccent: .white,
                background: background,
                surface: surface,
                container: container,
                inner: inner,
                accentContainer: accent.opacity(dark ? 0.28 : 0.14),
                onAccentContainer: accent,
                primaryText: .primary,
                secondaryText: .secondary,
                separator: Color(uiColor: .separator)
            )
        }
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.make(settings: .shared, scheme: .light)
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: - Colour utilities

extension UIColor {
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let red = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    var hexString: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

extension Color {
    var hexString: String { UIColor(self).hexString }
}

/// A Material 3 style tonal scheme from one seed colour, computed in OKLCH
/// (tone ≈ perceptual lightness × 100).
struct TonalScheme {
    struct Palette {
        let hue: Double
        let chroma: Double

        func tone(_ tone: Double) -> UIColor {
            let lightness = tone / 100
            // Very light and very dark tones cannot hold much chroma.
            let limit = chroma * min(1, 4 * lightness * (1 - lightness) + 0.05)
            return OKLCH(l: lightness, c: limit, h: hue).color
        }
    }

    let primary: Palette
    let secondary: Palette
    let neutral: Palette
    let neutralVariant: Palette

    init(seed: UIColor) {
        let source = OKLCH(seed)
        let chroma = max(source.c, 0.06)
        primary = Palette(hue: source.h, chroma: min(chroma, 0.19))
        secondary = Palette(hue: source.h, chroma: min(chroma / 3, 0.06))
        neutral = Palette(hue: source.h, chroma: 0.008)
        neutralVariant = Palette(hue: source.h, chroma: 0.018)
    }
}

struct OKLCH {
    var l: Double
    var c: Double
    var h: Double

    init(l: Double, c: Double, h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }

    init(_ color: UIColor) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = linear(red)
        let g = linear(green)
        let b = linear(blue)
        let lms = (
            cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b),
            cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b),
            cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        )
        let okL = 0.2104542553 * lms.0 + 0.7936177850 * lms.1 - 0.0040720468 * lms.2
        let okA = 1.9779984951 * lms.0 - 2.4285922050 * lms.1 + 0.4505937099 * lms.2
        let okB = 0.0259040371 * lms.0 + 0.7827717662 * lms.1 - 0.8086757660 * lms.2
        l = okL
        c = (okA * okA + okB * okB).squareRoot()
        h = atan2(okB, okA)
    }

    var color: UIColor {
        let a = c * cos(h)
        let b = c * sin(h)
        let l1 = l + 0.3963377774 * a + 0.2158037573 * b
        let m1 = l - 0.1055613458 * a - 0.0638541728 * b
        let s1 = l - 0.0894841775 * a - 1.2914855480 * b
        let lc = l1 * l1 * l1
        let mc = m1 * m1 * m1
        let sc = s1 * s1 * s1
        let r = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
        let g = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
        let bl = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc
        func gamma(_ value: Double) -> CGFloat {
            let v = min(max(value, 0), 1)
            return CGFloat(v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055)
        }
        return UIColor(red: gamma(r), green: gamma(g), blue: gamma(bl), alpha: 1)
    }
}
