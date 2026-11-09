import Foundation

/// A small YAML reader covering what Clash / Mihomo subscriptions use: block
/// mappings and sequences, flow collections (`{a: 1}` / `[a, b]`, also over
/// several lines), quoted and plain scalars, block scalars and comments.
/// Anchors, tags and multi-document streams are not supported.
public enum YAML {
    public static func parse(_ text: String) throws -> JSON {
        var reader = Reader(text: text)
        return try reader.parseDocument()
    }
}

private struct Line {
    var indent: Int
    var text: String
    var raw: String
}

private struct Reader {
    var lines: [Line] = []
    var index = 0

    init(text: String) {
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "  ").components(separatedBy: "\n") {
            let indent = rawLine.prefix { $0 == " " }.count
            let content = Reader.stripComment(String(rawLine.dropFirst(indent)))
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." { continue }
            lines.append(Line(indent: indent, text: trimmed, raw: rawLine))
        }
    }

    /// Removes a `#` comment that is not inside quotes.
    static func stripComment(_ text: String) -> String {
        var inSingle = false
        var inDouble = false
        var previous: Character = " "
        var escaped = false
        for (offset, character) in text.enumerated() {
            if inDouble {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inDouble = false }
            } else if inSingle {
                if character == "'" { inSingle = false }
            } else if character == "\"" {
                inDouble = true
            } else if character == "'" {
                inSingle = true
            } else if character == "#", previous == " " || offset == 0 {
                return String(text.prefix(offset))
            }
            previous = character
        }
        return text
    }

    mutating func skipBlank() {
        while index < lines.count, lines[index].text.isEmpty { index += 1 }
    }

    mutating func parseDocument() throws -> JSON {
        skipBlank()
        guard index < lines.count else { return .null }
        return try parseBlock(indent: lines[index].indent)
    }

    static func isSequenceItem(_ text: String) -> Bool {
        text == "-" || text.hasPrefix("- ")
    }

    mutating func parseBlock(indent: Int) throws -> JSON {
        skipBlank()
        guard index < lines.count else { return .null }
        let line = lines[index]
        if Reader.isSequenceItem(line.text) { return try parseSequence(indent: line.indent) }
        if Reader.splitKey(line.text) != nil { return try parseMapping(indent: line.indent) }
        index += 1
        return try parseInline(line.text, continuationIndent: indent)
    }

    mutating func parseSequence(indent: Int) throws -> JSON {
        var items: [JSON] = []
        while true {
            skipBlank()
            guard index < lines.count, lines[index].indent == indent, Reader.isSequenceItem(lines[index].text) else { break }
            let text = lines[index].text
            let afterDash = text.dropFirst()
            let spaces = afterDash.prefix { $0 == " " }.count
            let content = afterDash.trimmingCharacters(in: .whitespaces)
            if content.isEmpty {
                index += 1
                skipBlank()
                if index < lines.count, lines[index].indent > indent {
                    items.append(try parseBlock(indent: lines[index].indent))
                } else {
                    items.append(.null)
                }
            } else {
                // Re-read the item content as if it started on its own line.
                lines[index] = Line(indent: indent + 1 + spaces, text: content, raw: lines[index].raw)
                items.append(try parseBlock(indent: indent + 1 + spaces))
            }
        }
        return .array(items)
    }

    mutating func parseMapping(indent: Int) throws -> JSON {
        var object: [String: JSON] = [:]
        while true {
            skipBlank()
            guard index < lines.count, lines[index].indent == indent, let (key, rest) = Reader.splitKey(lines[index].text) else { break }
            index += 1
            if rest.isEmpty {
                skipBlank()
                if index < lines.count, lines[index].indent > indent || (lines[index].indent == indent && Reader.isSequenceItem(lines[index].text)) {
                    object[key] = try parseBlock(indent: lines[index].indent)
                } else {
                    object[key] = .null
                }
            } else if rest.hasPrefix("|") || rest.hasPrefix(">") {
                object[key] = .string(readBlockScalar(parentIndent: indent, folded: rest.hasPrefix(">"), chomp: rest.dropFirst().first))
            } else {
                object[key] = try parseInline(rest, continuationIndent: indent)
            }
        }
        return .object(object)
    }

    mutating func readBlockScalar(parentIndent: Int, folded: Bool, chomp: Character?) -> String {
        var collected: [String] = []
        var blockIndent: Int?
        while index < lines.count {
            let line = lines[index]
            if line.raw.trimmingCharacters(in: .whitespaces).isEmpty {
                collected.append("")
                index += 1
                continue
            }
            let indent = line.raw.prefix { $0 == " " }.count
            guard indent > parentIndent else { break }
            if blockIndent == nil { blockIndent = indent }
            collected.append(String(line.raw.dropFirst(min(indent, blockIndent ?? indent))))
            index += 1
        }
        while collected.last == "" { collected.removeLast() }
        var text = folded ? collected.joined(separator: " ") : collected.joined(separator: "\n")
        if chomp != "-" { text += "\n" }
        return text
    }

    /// Parses a value written on the current line. Flow collections that are
    /// not closed on this line continue on the following lines.
    mutating func parseInline(_ text: String, continuationIndent: Int) throws -> JSON {
        var source = text
        if source.hasPrefix("{") || source.hasPrefix("[") {
            while !Reader.isBalanced(source), index < lines.count {
                source += " " + lines[index].text
                index += 1
            }
            var flow = FlowParser(characters: Array(source))
            return try flow.parse()
        }
        return Reader.scalar(source)
    }

    static func isBalanced(_ text: String) -> Bool {
        var depth = 0
        var inSingle = false
        var inDouble = false
        var escaped = false
        for character in text {
            if inDouble {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inDouble = false }
                continue
            }
            if inSingle {
                if character == "'" { inSingle = false }
                continue
            }
            switch character {
            case "\"": inDouble = true
            case "'": inSingle = true
            case "{", "[": depth += 1
            case "}", "]": depth -= 1
            default: break
            }
        }
        return depth <= 0
    }

    /// Splits `key: value`. Returns `nil` for lines that are not mapping entries.
    static func splitKey(_ text: String) -> (String, String)? {
        guard let first = text.first, first != "{", first != "[", !isSequenceItem(text) else {
            return nil
        }
        let characters = Array(text)
        var position = 0
        var key: String
        if first == "\"" || first == "'" {
            guard let (value, end) = readQuoted(characters, from: 0) else { return nil }
            key = value
            position = end
            while position < characters.count, characters[position] == " " { position += 1 }
            guard position < characters.count, characters[position] == ":" else { return nil }
            let rest = String(characters[(position + 1)...]).trimmingCharacters(in: .whitespaces)
            return (key, rest)
        }
        while position < characters.count {
            if characters[position] == ":", position + 1 == characters.count || characters[position + 1] == " " {
                key = String(characters[0 ..< position]).trimmingCharacters(in: .whitespaces)
                let rest = position + 1 < characters.count ? String(characters[(position + 1)...]).trimmingCharacters(in: .whitespaces) : ""
                return key.isEmpty ? nil : (key, rest)
            }
            position += 1
        }
        return nil
    }

    static func readQuoted(_ characters: [Character], from start: Int) -> (String, Int)? {
        let quote = characters[start]
        var result = ""
        var position = start + 1
        while position < characters.count {
            let character = characters[position]
            if quote == "'" {
                if character == "'" {
                    if position + 1 < characters.count, characters[position + 1] == "'" {
                        result.append("'")
                        position += 2
                        continue
                    }
                    return (result, position + 1)
                }
                result.append(character)
            } else {
                if character == "\\", position + 1 < characters.count {
                    let next = characters[position + 1]
                    switch next {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "/": result.append("/")
                    case "0": result.append("\0")
                    case "u":
                        let hexStart = position + 2
                        if hexStart + 4 <= characters.count, let code = UInt32(String(characters[hexStart ..< hexStart + 4]), radix: 16), let scalar = Unicode.Scalar(code) {
                            result.unicodeScalars.append(scalar)
                            position += 6
                            continue
                        }
                        result.append(next)
                    default: result.append(next)
                    }
                    position += 2
                    continue
                }
                if character == "\"" { return (result, position + 1) }
                result.append(character)
            }
            position += 1
        }
        return nil
    }

    /// Resolves a plain or quoted scalar to a JSON value.
    static func scalar(_ text: String) -> JSON {
        let value = text.trimmingCharacters(in: .whitespaces)
        if let first = value.first, first == "\"" || first == "'" {
            if let (string, _) = readQuoted(Array(value), from: 0) { return .string(string) }
            return .string(value)
        }
        switch value {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        default: break
        }
        if let integer = Int(value), !(value.hasPrefix("0") && value.count > 1) || value == "0" {
            return .int(integer)
        }
        if value.hasPrefix("0x"), let integer = Int(value.dropFirst(2), radix: 16) { return .int(integer) }
        if value.contains("."), value.first?.isNumber == true || value.first == "-", value.filter({ $0 == "." }).count == 1, let double = Double(value) {
            return .double(double)
        }
        return .string(value)
    }
}

private struct FlowParser {
    let characters: [Character]
    var position = 0

    mutating func parse() throws -> JSON {
        skipSpaces()
        return try parseValue()
    }

    mutating func skipSpaces() {
        while position < characters.count, characters[position] == " " || characters[position] == "\n" { position += 1 }
    }

    mutating func parseValue() throws -> JSON {
        skipSpaces()
        guard position < characters.count else { return .null }
        switch characters[position] {
        case "{": return try parseMap()
        case "[": return try parseList()
        case "\"", "'":
            guard let (value, end) = Reader.readQuoted(characters, from: position) else {
                throw ImportError.invalidYAML("незакрытая кавычка")
            }
            position = end
            return .string(value)
        default:
            return Reader.scalar(readPlain())
        }
    }

    mutating func readPlain() -> String {
        var result = ""
        while position < characters.count {
            let character = characters[position]
            if character == "," || character == "}" || character == "]" { break }
            if character == ":", position + 1 >= characters.count || [" ", ",", "}", "]"].contains(characters[position + 1]) { break }
            result.append(character)
            position += 1
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    mutating func parseKey() throws -> String {
        skipSpaces()
        guard position < characters.count else { throw ImportError.invalidYAML("незакрытая скобка") }
        if characters[position] == "\"" || characters[position] == "'" {
            guard let (value, end) = Reader.readQuoted(characters, from: position) else { throw ImportError.invalidYAML("незакрытая кавычка") }
            position = end
            return value
        }
        return readPlain()
    }

    mutating func parseMap() throws -> JSON {
        position += 1
        var object: [String: JSON] = [:]
        while true {
            skipSpaces()
            guard position < characters.count else { throw ImportError.invalidYAML("незакрытая скобка {") }
            if characters[position] == "}" {
                position += 1
                return .object(object)
            }
            if characters[position] == "," {
                position += 1
                continue
            }
            let key = try parseKey()
            skipSpaces()
            var value: JSON = .null
            if position < characters.count, characters[position] == ":" {
                position += 1
                skipSpaces()
                if position < characters.count, characters[position] != ",", characters[position] != "}" {
                    value = try parseValue()
                }
            }
            if !key.isEmpty { object[key] = value }
        }
    }

    mutating func parseList() throws -> JSON {
        position += 1
        var items: [JSON] = []
        while true {
            skipSpaces()
            guard position < characters.count else { throw ImportError.invalidYAML("незакрытая скобка [") }
            if characters[position] == "]" {
                position += 1
                return .array(items)
            }
            if characters[position] == "," {
                position += 1
                continue
            }
            items.append(try parseValue())
        }
    }
}
