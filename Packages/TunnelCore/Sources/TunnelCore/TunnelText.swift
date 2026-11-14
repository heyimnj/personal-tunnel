import Foundation

/// The lines the packet tunnel writes in Russian — its short log, its lines in
/// the core's log, its errors — shown in the interface language (3.0.6).
///
/// The extension does not know the app's language (it is chosen inside the app)
/// and has no translations of its own, so it keeps writing Russian and the app
/// translates when it shows or copies a line. Lines written by an older build
/// read the same way. `TunnelTextTests` checks that every Russian text in
/// `PacketTunnel` is listed here and translated.
public enum TunnelText {
    /// Whole messages; `%@` stands for a value (a reason, an error, a name).
    public static let formats: [String] = [
        "запуск, ядро %@",
        "ядро расширения: %@",
        "запуск не удался: %@",
        "остановка, причина %@",
        "перезагрузка конфигурации",
        "перезагрузка не удалась: %@",
        "Нет доступа к общей группе приложения (%@). Проверьте подпись приложения и расширения.",
        "Ядро не инициализировалось: %@",
        "Командный сервер не создан: %@",
        "Командный сервер не создан.",
        "Командный сервер не запущен.",
        "Xray-core не запустился: %@",
        "Xray-core запущен, интерфейс %@",
        "в подписке есть серверы Xray, но расширение собрано без Xray-core",
        "сеть сменилась (%@): перезапуск Xray-core",
        "Туннель не запущен.",
        "закрытие службы: %@",
        "Нет сохранённой конфигурации. Откройте Personal Tunnel и выберите сервер.",
        "[mem] занято %@ МиБ, пик %@ МиБ, доступно %@ МиБ",
        "[mem] занято %@ МиБ, пик %@ МиБ",
    ]

    /// Texts that come back inside other lines: the platform's errors, which the
    /// core wraps in its own English message, and the redactor's placeholders.
    public static let fragments: [String] = [
        "ядро не передало параметры TUN",
        "не найден файловый дескриптор TUN",
        "система не применила настройки туннеля за 20 с",
        "монитор сети не запущен",
        "владелец соединения на iOS недоступен",
        "оболочка недоступна",
        "пользователи недоступны",
        "SFTP недоступен",
        "SSH-агент недоступен",
        "SSH недоступен",
        "мосты недоступны",
        "недоступно",
        "<адрес>",
        "<сервер>",
    ]

    /// Every text listed here, for the check that each one is translated.
    public static var all: [String] { formats + fragments }

    /// `line` in the interface language. Lines without Russian (the core's own)
    /// and a Russian interface are returned as they are.
    public static func localize(_ line: String) -> String {
        guard !CoreText.russian, containsCyrillic(line) else { return line }
        return localize(line, depth: 0)
    }

    private static func localize(_ line: String, depth: Int) -> String {
        guard containsCyrillic(line) else { return line }
        for (format, pattern) in patterns {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = pattern.firstMatch(in: line, range: range) else { continue }
            func group(_ index: Int) -> String {
                Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
            }
            let prefix = group(1)
            let values = (2 ..< match.numberOfRanges).map { index -> String in
                let value = group(index)
                return depth < 2 ? localize(value, depth: depth + 1) : value
            }
            // What comes before may hold a message of its own («запуск не удался:»
            // before an error that matched first).
            let head = depth < 2 ? localize(prefix, depth: depth + 1) : replaceFragments(prefix)
            return head + CoreText.fill(CoreText.t(format), values)
        }
        return replaceFragments(line)
    }

    private static func replaceFragments(_ text: String) -> String {
        guard containsCyrillic(text) else { return text }
        var result = text
        for fragment in orderedFragments where result.contains(fragment) {
            result = result.replacingOccurrences(of: fragment, with: CoreText.t(fragment))
        }
        return result
    }

    /// Longest first, so «SSH-агент недоступен» is not read as «… недоступен».
    private static let orderedFragments = fragments.sorted { $0.count > $1.count }

    /// A format as a pattern: `(anything before)` then the format with each `%@`
    /// a value, to the end of the line. Longest formats are tried first, so the
    /// memory line with «доступно» is not taken for the shorter one.
    private static let patterns: [(String, NSRegularExpression)] = formats
        .sorted { $0.count > $1.count }
        .compactMap { format in
            let parts = format.components(separatedBy: "%@").map(NSRegularExpression.escapedPattern(for:))
            let body = parts.joined(separator: "(.*?)")
            guard let expression = try? NSRegularExpression(pattern: "^(.*?)" + body + "$", options: [.dotMatchesLineSeparators]) else { return nil }
            return (format, expression)
        }

    private static func containsCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x400 ... 0x4FF).contains($0.value) }
    }
}
