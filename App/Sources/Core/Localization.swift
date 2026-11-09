import Foundation

/// Interface text. Russian is the source language; `English.table` holds the
/// translations. The language can be switched inside the app without a
/// restart, which `Localizable.strings` lookups do not allow.
func L(_ russian: String) -> String {
    guard AppSettings.shared.effectiveLanguage == .en else { return russian }
    return English.table[russian] ?? russian
}

/// `L` with `%@` / `%d` placeholders.
func L(_ russian: String, _ arguments: CVarArg...) -> String {
    String(format: L(russian), arguments: arguments)
}

/// Translates messages produced by TunnelKit (importers, fetcher), which are
/// Russian, by matching their fixed prefixes.
func localizedMessage(_ message: String) -> String {
    guard AppSettings.shared.effectiveLanguage == .en else { return message }
    return English.translate(message) ?? message
}

/// Plural forms for Russian counts: 1 сервер, 2 сервера, 5 серверов.
func plural(_ count: Int, _ one: String, _ few: String, _ many: String, english: (String, String)) -> String {
    if AppSettings.shared.effectiveLanguage == .en {
        return "\(count) " + (count == 1 ? english.0 : english.1)
    }
    let mod10 = count % 10
    let mod100 = count % 100
    let word: String
    if mod10 == 1, mod100 != 11 {
        word = one
    } else if (2 ... 4).contains(mod10), !(12 ... 14).contains(mod100) {
        word = few
    } else {
        word = many
    }
    return "\(count) \(word)"
}

func serversCount(_ count: Int) -> String {
    plural(count, "сервер", "сервера", "серверов", english: ("server", "servers"))
}
