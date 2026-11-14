import Foundation
import TunnelCore

/// The interface language. Russian text is the key everywhere; other languages
/// come from `<code>.lproj/Localizable.strings`. Chosen in Settings → Язык
/// (`personal.language`, as 1.x stored it): `system`, `ru` or `en`.
enum Language {
    static let supported = ["ru", "en"]
    private(set) static var code = "ru"
    private static var table: Bundle?

    /// The language the interface uses for the stored choice.
    static func resolve(_ choice: String) -> String {
        if supported.contains(choice) { return choice }
        // System: Russian on a Russian device, otherwise English.
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "ru"
        return preferred.hasPrefix("ru") ? "ru" : "en"
    }

    /// Reads the choice and points the app and the core at its texts.
    static func apply() {
        code = resolve(Prefs.language)
        table = code == "ru" ? nil : Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
        CoreText.translate = { L($0) }
        CoreText.russianPlurals = code == "ru"
        CoreText.russian = code == "ru"
    }

    /// Dates and numbers in the interface language.
    static var locale: Locale { Locale(identifier: code == "ru" ? "ru_RU" : "en_US") }

    static func text(_ key: String) -> String {
        table?.localizedString(forKey: key, value: key, table: nil) ?? key
    }
}

/// Interface text in the chosen language; the Russian text is the key.
func L(_ text: String) -> String { Language.text(text) }

/// A translated format whose `%@` take the arguments in order.
func Lf(_ format: String, _ arguments: String...) -> String { CoreText.fill(Language.text(format), arguments) }
