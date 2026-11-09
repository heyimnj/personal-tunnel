import Foundation

/// A country recognised from a server name, either by its flag emoji or by
/// its name in English or Russian.
public struct Country: Hashable, Sendable {
    /// ISO 3166-1 alpha-2, upper case.
    public let code: String

    public init(code: String) {
        self.code = code.uppercased()
    }

    /// The flag emoji built from regional indicator symbols.
    public var flag: String {
        var scalars = String.UnicodeScalarView()
        for scalar in code.unicodeScalars {
            guard let indicator = Unicode.Scalar(0x1F1E6 + scalar.value - 0x41) else { return "🏳️" }
            scalars.append(indicator)
        }
        return String(scalars)
    }

    public static func detect(in name: String) -> Country? {
        if let flag = flagCode(in: name) { return Country(code: flag) }
        let lowered = name.lowercased()
        for (code, words) in names {
            for word in words where containsWord(lowered, word) {
                return Country(code: code)
            }
        }
        // Two-letter codes as separate tokens: "DE 1", "nl-ams", "[US]".
        let tokens = lowered.split(whereSeparator: { !$0.isLetter }).map(String.init)
        for token in tokens where token.count == 2 {
            let upper = token.uppercased()
            if codeOnly.contains(upper) { return Country(code: upper == "UK" ? "GB" : upper) }
        }
        return nil
    }

    /// Removes flag emoji and the separator that usually follows it.
    public static func stripFlags(from name: String) -> String {
        var scalars = String.UnicodeScalarView()
        var skippedSeparator = false
        var previousWasFlag = false
        for scalar in name.unicodeScalars {
            if (0x1F1E6 ... 0x1F1FF).contains(scalar.value) || scalar.value == 0x1F3F4 || (0xE0020 ... 0xE007F).contains(scalar.value) {
                previousWasFlag = true
                continue
            }
            if previousWasFlag, !skippedSeparator, scalar == " " || scalar == "|" || scalar == "-" {
                continue
            }
            if previousWasFlag { skippedSeparator = true }
            previousWasFlag = false
            scalars.append(scalar)
        }
        let result = String(scalars).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? name : result
    }

    static func flagCode(in name: String) -> String? {
        var letters: [Character] = []
        for scalar in name.unicodeScalars {
            if (0x1F1E6 ... 0x1F1FF).contains(scalar.value) {
                letters.append(Character(Unicode.Scalar(scalar.value - 0x1F1E6 + 0x41)!))
                if letters.count == 2 { return String(letters) }
            } else if !letters.isEmpty {
                letters.removeAll()
            }
        }
        return nil
    }

    private static func containsWord(_ text: String, _ word: String) -> Bool {
        var searchRange = text.startIndex ..< text.endIndex
        while let range = text.range(of: word, range: searchRange) {
            let beforeOK = range.lowerBound == text.startIndex || !text[text.index(before: range.lowerBound)].isLetter
            let afterOK = range.upperBound == text.endIndex || !text[range.upperBound].isLetter
            if beforeOK, afterOK { return true }
            searchRange = range.upperBound ..< text.endIndex
        }
        return false
    }

    /// Codes that are only matched as standalone tokens (they are too short for
    /// substring matching).
    private static let codeOnly: Set<String> = [
        "DE", "NL", "US", "GB", "UK", "FR", "FI", "SE", "NO", "PL", "TR", "JP", "KR", "SG", "HK", "TW", "CA",
        "AU", "CH", "AT", "CZ", "LV", "LT", "EE", "KZ", "UA", "RU", "AE", "IL", "IN", "BR", "ES", "IT", "RO",
        "BG", "HU", "MD", "RS", "GE", "AM", "AZ", "IS", "IE", "PT", "DK", "BE", "LU", "CY", "GR",
    ]

    private static let names: [(String, [String])] = [
        ("RU", ["russia", "россия", "рф", "moscow", "москва", "saint petersburg", "санкт-петербург"]),
        ("DE", ["germany", "германия", "frankfurt", "франкфурт", "berlin", "берлин", "deutschland"]),
        ("NL", ["netherlands", "нидерланды", "голландия", "holland", "amsterdam", "амстердам"]),
        ("US", ["united states", "usa", "сша", "америка", "new york", "нью-йорк", "los angeles", "лос-анджелес", "dallas", "miami", "chicago", "seattle"]),
        ("GB", ["united kingdom", "великобритания", "англия", "england", "london", "лондон", "britain"]),
        ("FR", ["france", "франция", "paris", "париж"]),
        ("FI", ["finland", "финляндия", "helsinki", "хельсинки"]),
        ("SE", ["sweden", "швеция", "stockholm", "стокгольм"]),
        ("NO", ["norway", "норвегия", "oslo"]),
        ("DK", ["denmark", "дания", "copenhagen"]),
        ("PL", ["poland", "польша", "warsaw", "варшава"]),
        ("CZ", ["czech", "чехия", "prague", "прага"]),
        ("AT", ["austria", "австрия", "vienna", "вена"]),
        ("CH", ["switzerland", "швейцария", "zurich", "цюрих"]),
        ("IT", ["italy", "италия", "milan", "милан", "rome"]),
        ("ES", ["spain", "испания", "madrid", "мадрид"]),
        ("PT", ["portugal", "португалия", "lisbon"]),
        ("IE", ["ireland", "ирландия", "dublin"]),
        ("BE", ["belgium", "бельгия", "brussels"]),
        ("LU", ["luxembourg", "люксембург"]),
        ("LV", ["latvia", "латвия", "riga", "рига"]),
        ("LT", ["lithuania", "литва", "vilnius", "вильнюс"]),
        ("EE", ["estonia", "эстония", "tallinn", "таллин"]),
        ("UA", ["ukraine", "украина", "kyiv", "киев"]),
        ("BY", ["belarus", "беларусь", "минск", "minsk"]),
        ("KZ", ["kazakhstan", "казахстан", "almaty", "алматы", "astana", "астана"]),
        ("UZ", ["uzbekistan", "узбекистан", "tashkent", "ташкент"]),
        ("KG", ["kyrgyzstan", "киргизия", "кыргызстан", "bishkek"]),
        ("GE", ["georgia", "грузия", "tbilisi", "тбилиси"]),
        ("AM", ["armenia", "армения", "yerevan", "ереван"]),
        ("AZ", ["azerbaijan", "азербайджан", "baku", "баку"]),
        ("MD", ["moldova", "молдова", "chisinau"]),
        ("RO", ["romania", "румыния", "bucharest"]),
        ("BG", ["bulgaria", "болгария", "sofia"]),
        ("HU", ["hungary", "венгрия", "budapest"]),
        ("RS", ["serbia", "сербия", "belgrade", "белград"]),
        ("GR", ["greece", "греция", "athens"]),
        ("CY", ["cyprus", "кипр"]),
        ("TR", ["turkey", "türkiye", "турция", "istanbul", "стамбул"]),
        ("IL", ["israel", "израиль", "tel aviv"]),
        ("AE", ["emirates", "uae", "оаэ", "эмираты", "dubai", "дубай"]),
        ("IN", ["india", "индия", "mumbai"]),
        ("SG", ["singapore", "сингапур"]),
        ("HK", ["hong kong", "гонконг"]),
        ("TW", ["taiwan", "тайвань"]),
        ("JP", ["japan", "япония", "tokyo", "токио", "osaka"]),
        ("KR", ["korea", "корея", "seoul", "сеул"]),
        ("CN", ["china", "китай"]),
        ("VN", ["vietnam", "вьетнам"]),
        ("TH", ["thailand", "таиланд"]),
        ("ID", ["indonesia", "индонезия", "jakarta"]),
        ("MY", ["malaysia", "малайзия"]),
        ("AU", ["australia", "австралия", "sydney", "сидней"]),
        ("NZ", ["new zealand", "новая зеландия"]),
        ("CA", ["canada", "канада", "toronto", "торонто", "montreal"]),
        ("MX", ["mexico", "мексика"]),
        ("BR", ["brazil", "бразилия", "sao paulo"]),
        ("AR", ["argentina", "аргентина"]),
        ("ZA", ["south africa", "юар"]),
        ("IS", ["iceland", "исландия"]),
    ]
}
