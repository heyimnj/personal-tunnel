import Foundation

/// Text the core shows to people (errors, reasons, time and counts). The Russian
/// text is the key; the app installs a translator for other languages. Tests and
/// the fixtures tool keep the Russian text as it is.
public enum CoreText {
    /// Russian text → text in the interface language.
    nonisolated(unsafe) public static var translate: (String) -> String = { $0 }
    /// Russian counts have three forms (1 сервер, 2 сервера, 5 серверов); others two.
    nonisolated(unsafe) public static var russianPlurals = true
    /// The interface is Russian: nothing to translate (3.0.6, see `TunnelText`).
    nonisolated(unsafe) public static var russian = true

    public static func t(_ text: String) -> String { translate(text) }

    /// A translated format whose `%@` take the arguments in order (`%%` is a percent sign).
    public static func f(_ format: String, _ arguments: String...) -> String {
        fill(translate(format), arguments)
    }

    public static func fill(_ format: String, _ arguments: [String]) -> String {
        var result = ""
        var rest = arguments[...]
        var index = format.startIndex
        while index < format.endIndex {
            let character = format[index]
            let next = format.index(after: index)
            if character == "%", next < format.endIndex {
                if format[next] == "@" {
                    result += rest.popFirst() ?? ""
                    index = format.index(after: next)
                    continue
                }
                if format[next] == "%" {
                    result.append("%")
                    index = format.index(after: next)
                    continue
                }
            }
            result.append(character)
            index = next
        }
        return result
    }
}
