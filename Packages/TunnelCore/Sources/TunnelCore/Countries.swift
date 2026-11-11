import Foundation

/// Country of a server, worked out from its name only: a flag emoji, a country
/// name in English or Russian, or a leading ISO code. Never from an IP address.
public enum Countries {
    public struct Entry: Sendable {
        public let code: String
        public let name: String
        let aliases: [String]
    }

    // code|display name|other names (Russian and English), comma separated
    private static let table = """
    AD|Andorra|андорра
    AE|UAE|оаэ,эмираты,объединённые арабские эмираты,объединенные арабские эмираты,united arab emirates,emirates,dubai,дубай,abu dhabi,абу-даби
    AF|Afghanistan|афганистан
    AL|Albania|албания
    AM|Armenia|армения
    AO|Angola|ангола
    AR|Argentina|аргентина
    AT|Austria|австрия
    AU|Australia|австралия
    AZ|Azerbaijan|азербайджан
    BA|Bosnia and Herzegovina|босния,босния и герцеговина,bosnia
    BD|Bangladesh|бангладеш
    BE|Belgium|бельгия
    BG|Bulgaria|болгария
    BH|Bahrain|бахрейн
    BO|Bolivia|боливия
    BR|Brazil|бразилия
    BY|Belarus|беларусь,белоруссия
    CA|Canada|канада
    CH|Switzerland|швейцария
    CL|Chile|чили
    CN|China|китай
    CO|Colombia|колумбия
    CR|Costa Rica|коста-рика,коста рика
    CY|Cyprus|кипр
    CZ|Czechia|чехия,чешская республика,czech republic,czech
    DE|Germany|германия,deutschland
    DK|Denmark|дания
    DZ|Algeria|алжир
    EC|Ecuador|эквадор
    EE|Estonia|эстония
    EG|Egypt|египет
    ES|Spain|испания
    FI|Finland|финляндия
    FR|France|франция
    GB|United Kingdom|великобритания,британия,англия,соединённое королевство,соединенное королевство,uk,great britain,britain,england
    GE|Georgia|грузия
    GR|Greece|греция
    HK|Hong Kong|гонконг,hongkong
    HR|Croatia|хорватия
    HU|Hungary|венгрия
    ID|Indonesia|индонезия
    IE|Ireland|ирландия
    IL|Israel|израиль
    IN|India|индия
    IQ|Iraq|ирак
    IR|Iran|иран
    IS|Iceland|исландия
    IT|Italy|италия
    JO|Jordan|иордания
    JP|Japan|япония
    KE|Kenya|кения
    KG|Kyrgyzstan|киргизия,кыргызстан
    KH|Cambodia|камбоджа
    KR|South Korea|южная корея,корея,korea,republic of korea
    KW|Kuwait|кувейт
    KZ|Kazakhstan|казахстан
    LA|Laos|лаос
    LB|Lebanon|ливан
    LI|Liechtenstein|лихтенштейн
    LK|Sri Lanka|шри-ланка,шри ланка
    LT|Lithuania|литва
    LU|Luxembourg|люксембург
    LV|Latvia|латвия
    MA|Morocco|марокко
    MC|Monaco|монако
    MD|Moldova|молдова,молдавия
    ME|Montenegro|черногория
    MK|North Macedonia|северная македония,македония,macedonia
    MN|Mongolia|монголия
    MO|Macau|макао,macao
    MT|Malta|мальта
    MX|Mexico|мексика
    MY|Malaysia|малайзия
    NG|Nigeria|нигерия
    NL|Netherlands|нидерланды,голландия,the netherlands,holland
    NO|Norway|норвегия
    NP|Nepal|непал
    NZ|New Zealand|новая зеландия
    OM|Oman|оман
    PA|Panama|панама
    PE|Peru|перу
    PH|Philippines|филиппины
    PK|Pakistan|пакистан
    PL|Poland|польша
    PT|Portugal|португалия
    PY|Paraguay|парагвай
    QA|Qatar|катар
    RO|Romania|румыния
    RS|Serbia|сербия
    RU|Russia|россия,рф,российская федерация,russian federation
    SA|Saudi Arabia|саудовская аравия
    SE|Sweden|швеция
    SG|Singapore|сингапур
    SI|Slovenia|словения
    SK|Slovakia|словакия
    TH|Thailand|таиланд,тайланд
    TJ|Tajikistan|таджикистан
    TM|Turkmenistan|туркмения,туркменистан
    TN|Tunisia|тунис
    TR|Turkey|турция,türkiye,turkiye
    TW|Taiwan|тайвань
    UA|Ukraine|украина
    US|USA|сша,соединённые штаты,соединенные штаты,америка,united states,united states of america,america
    UY|Uruguay|уругвай
    UZ|Uzbekistan|узбекистан
    VE|Venezuela|венесуэла
    VN|Vietnam|вьетнам,viet nam
    ZA|South Africa|юар,южная африка
    """

    public static let entries: [Entry] = table.split(separator: "\n").compactMap { line in
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let aliases = parts.count > 2 ? parts[2].split(separator: ",").map { normalize(String($0)) } : []
        return Entry(code: parts[0], name: parts[1], aliases: aliases)
    }

    private static let byCode: [String: Entry] = Dictionary(entries.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })

    /// Every spelling → code, longest first so "south korea" wins over "korea".
    private static let phrases: [(phrase: String, code: String, cyrillic: Bool)] = {
        var result: [(String, String, Bool)] = []
        for entry in entries {
            result.append((normalize(entry.name), entry.code, false))
            for alias in entry.aliases {
                result.append((alias, entry.code, alias.unicodeScalars.contains { (0x0400 ... 0x04FF).contains($0.value) }))
            }
        }
        return result.sorted { $0.0.count > $1.0.count }
    }()

    /// Two-letter words that look like ISO codes but are not countries in server names.
    private static let notCodes: Set<String> = [
        "wi", "fi", "ws", "tv", "ip", "os", "v2", "v3", "x2", "x3", "tw", "no", "to", "in", "is", "it", "me", "my",
        "by", "at", "be", "do", "so", "us", "id", "ai", "io", "ms", "tc", "cc", "la", "ru", "de",
    ]

    public static func displayName(code: String) -> String? { byCode[code.uppercased()]?.name }

    /// The flag as emoji for a two-letter code; `nil` when the code is not letters.
    public static func flagEmoji(code: String?) -> String? {
        guard let code = code?.uppercased(), code.count == 2 else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in code.unicodeScalars {
            guard (0x41 ... 0x5A).contains(scalar.value), let indicator = Unicode.Scalar(0x1F1E6 + scalar.value - 0x41) else { return nil }
            scalars.append(indicator)
        }
        return String(scalars)
    }

    /// Lowercased text with punctuation as spaces, for matching names.
    public static func normalize(_ text: String) -> String {
        var result = ""
        var lastWasSpace = true
        for scalar in text.lowercased().unicodeScalars {
            let isWord = CharacterSet.alphanumerics.contains(scalar)
            if isWord {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }
        return result.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "ё", with: "е")
    }

    private static func isRegionalIndicator(_ scalar: Unicode.Scalar) -> Bool {
        (0x1F1E6 ... 0x1F1FF).contains(scalar.value)
    }

    /// Code of the first flag emoji in the text.
    public static func flagCode(in text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index + 1 < scalars.count {
            if isRegionalIndicator(scalars[index]), isRegionalIndicator(scalars[index + 1]) {
                let first = Unicode.Scalar(scalars[index].value - 0x1F1E6 + 0x41)!
                let second = Unicode.Scalar(scalars[index + 1].value - 0x1F1E6 + 0x41)!
                return String(Character(first)) + String(Character(second))
            }
            index += 1
        }
        return nil
    }

    /// The text without flag emoji and without the separators left around them.
    public static func strippingFlags(_ text: String) -> String {
        var view = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isRegionalIndicator(scalar) {
            view.append(scalar)
        }
        let trimmed = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|-_·•,:;"))
        return String(view).trimmingCharacters(in: trimmed)
    }

    public struct Resolution: Hashable, Sendable {
        /// ISO code, or `nil` when the name names no country.
        public var code: String?
        /// What the lists show.
        public var label: String
        /// The country name came with a number that was left out of `label`.
        public var droppedIndex: String?
    }

    /// Works out the flag and the list label of a server name.
    ///
    /// A name that is only a country (in Russian or English), optionally with a
    /// number, becomes the English country name, as it did in 1.x: «США-2» → `USA`,
    /// `Switzerland 1` stays `Switzerland 1`. Anything else keeps the provider's text.
    public static func resolve(name raw: String) -> Resolution {
        let emojiCode = flagCode(in: raw)
        let cleaned = strippingFlags(raw)
        let normalized = normalize(cleaned)
        guard !normalized.isEmpty else {
            return Resolution(code: emojiCode, label: emojiCode.flatMap(displayName(code:)) ?? raw, droppedIndex: nil)
        }
        var words = normalized.split(separator: " ").map(String.init)
        var index: String?
        if words.count > 1, let last = words.last, last.count <= 3, last.allSatisfy(\.isNumber) {
            index = last
            words.removeLast()
        }
        let phrase = words.joined(separator: " ")
        if let match = phrases.first(where: { $0.phrase == phrase }), let name = displayName(code: match.code) {
            // Only a country name: show it in English. A Cyrillic original loses its
            // number (1.x behaviour); the caller restores it when labels would collide.
            if match.cyrillic {
                return Resolution(code: emojiCode ?? match.code, label: name, droppedIndex: index)
            }
            return Resolution(code: emojiCode ?? match.code, label: index.map { "\(name) \($0)" } ?? name, droppedIndex: nil)
        }
        if let emojiCode { return Resolution(code: emojiCode, label: cleaned, droppedIndex: nil) }
        return Resolution(code: code(inNormalized: normalized), label: cleaned, droppedIndex: nil)
    }

    /// A country named somewhere in already normalized text.
    static func code(inNormalized text: String) -> String? {
        let padded = " " + text + " "
        var best: (position: Int, length: Int, code: String)?
        for item in phrases {
            guard let range = padded.range(of: " " + item.phrase + " ") else { continue }
            let position = padded.distance(from: padded.startIndex, to: range.lowerBound)
            if best == nil || position < best!.position || (position == best!.position && item.phrase.count > best!.length) {
                best = (position, item.phrase.count, item.code)
            }
        }
        if let best { return best.code }
        // A leading ISO code such as "DE Frankfurt" or "NL-1".
        if let first = text.split(separator: " ").first.map(String.init), first.count == 2, !notCodes.contains(first),
           byCode[first.uppercased()] != nil
        {
            return first.uppercased()
        }
        return nil
    }
}

/// Labels and flags of one subscription's servers, computed together so that
/// shortened country labels never collide.
public enum ServerLabels {
    public struct Label: Hashable, Sendable {
        public var text: String
        public var countryCode: String?

        public init(text: String, countryCode: String?) {
            self.text = text
            self.countryCode = countryCode
        }
    }

    public static func make(for nodes: [ServerNode]) -> [String: Label] {
        let resolved = nodes.map { ($0.id, Countries.resolve(name: $0.name)) }
        var counts: [String: Int] = [:]
        for (_, item) in resolved { counts[item.label, default: 0] += 1 }
        var result: [String: Label] = [:]
        for (id, item) in resolved {
            var text = item.label
            if let index = item.droppedIndex, (counts[item.label] ?? 0) > 1 { text = "\(item.label) \(index)" }
            result[id] = Label(text: text, countryCode: item.code)
        }
        return result
    }
}
