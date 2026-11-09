import Foundation

/// A JSON value with a deterministic parser and serializer.
///
/// sing-box configurations are assembled from these values. Parsing and
/// serialization are implemented here instead of going through
/// `JSONSerialization`, so integers stay integers, booleans never turn into
/// numbers, and the output is byte-for-byte stable (sorted keys) on every
/// platform, which keeps the configuration builder testable on Linux.
public enum JSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    // MARK: Accessors

    public subscript(key: String) -> JSON? {
        get {
            if case let .object(object) = self { return object[key] }
            return nil
        }
        set {
            guard case var .object(object) = self else { return }
            object[key] = newValue
            self = .object(object)
        }
    }

    public subscript(index: Int) -> JSON? {
        if case let .array(array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    public var object: [String: JSON]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public var array: [JSON]? {
        if case let .array(value) = self { return value }
        return nil
    }

    /// The string value. Numbers and booleans are converted, which matches how
    /// loosely subscription panels type their fields.
    public var string: String? {
        switch self {
        case let .string(value): return value
        case let .int(value): return String(value)
        case let .double(value):
            if value.rounded() == value, abs(value) < 1e15 { return String(Int(value)) }
            return String(value)
        case let .bool(value): return value ? "true" : "false"
        default: return nil
        }
    }

    /// A non-empty, trimmed string value.
    public var text: String? {
        guard let value = string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    public var int: Int? {
        switch self {
        case let .int(value): return value
        case let .double(value):
            guard value.rounded() == value, abs(value) < 9e15 else { return nil }
            return Int(value)
        case let .string(value): return Int(value.trimmingCharacters(in: .whitespaces))
        case let .bool(value): return value ? 1 : 0
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case let .int(value): return Double(value)
        case let .double(value): return value
        case let .string(value): return Double(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public var bool: Bool? {
        switch self {
        case let .bool(value): return value
        case let .int(value): return value != 0
        case let .double(value): return value != 0
        case let .string(value):
            switch value.trimmingCharacters(in: .whitespaces).lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off", "": return false
            default: return nil
            }
        default: return nil
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Strings from either a JSON array or a comma separated string.
    public var stringList: [String] {
        switch self {
        case let .array(values): return values.compactMap(\.text)
        case let .string(value):
            return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default:
            return text.map { [$0] } ?? []
        }
    }

    /// Removes the keys whose values are `null`, empty strings, empty arrays or
    /// empty objects, recursively. Used to keep generated outbounds minimal.
    public func pruned() -> JSON {
        switch self {
        case let .object(object):
            var result: [String: JSON] = [:]
            for (key, value) in object {
                let child = value.pruned()
                switch child {
                case .null: continue
                case let .string(text) where text.isEmpty: continue
                case let .array(items) where items.isEmpty: continue
                case let .object(items) where items.isEmpty: continue
                default: result[key] = child
                }
            }
            return .object(result)
        case let .array(items):
            return .array(items.map { $0.pruned() })
        default:
            return self
        }
    }
}

// MARK: - Literals

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        var object: [String: JSON] = [:]
        for (key, value) in elements { object[key] = value }
        self = .object(object)
    }

    public init(nilLiteral _: ()) { self = .null }
}

public extension JSON {
    static func strings(_ values: [String]) -> JSON { .array(values.map { .string($0) }) }
}

// MARK: - Codable (stored as serialized text)

extension JSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        self = try JSON.parse(text)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(serialized())
    }
}

// MARK: - Serialization

public extension JSON {
    func serialized(pretty: Bool = false) -> String {
        var output = ""
        output.reserveCapacity(256)
        write(into: &output, pretty: pretty, indent: 0)
        return output
    }

    private func write(into output: inout String, pretty: Bool, indent: Int) {
        switch self {
        case .null:
            output += "null"
        case let .bool(value):
            output += value ? "true" : "false"
        case let .int(value):
            output += String(value)
        case let .double(value):
            if value.isNaN || value.isInfinite {
                output += "null"
            } else if value.rounded() == value, abs(value) < 1e15 {
                output += String(Int(value))
            } else {
                output += String(value)
            }
        case let .string(value):
            JSON.writeString(value, into: &output)
        case let .array(values):
            if values.isEmpty {
                output += "[]"
                return
            }
            output += "["
            for (index, value) in values.enumerated() {
                if index > 0 { output += "," }
                if pretty { output += "\n" + String(repeating: "  ", count: indent + 1) }
                value.write(into: &output, pretty: pretty, indent: indent + 1)
            }
            if pretty { output += "\n" + String(repeating: "  ", count: indent) }
            output += "]"
        case let .object(object):
            if object.isEmpty {
                output += "{}"
                return
            }
            output += "{"
            for (index, key) in object.keys.sorted().enumerated() {
                if index > 0 { output += "," }
                if pretty { output += "\n" + String(repeating: "  ", count: indent + 1) }
                JSON.writeString(key, into: &output)
                output += pretty ? ": " : ":"
                object[key]!.write(into: &output, pretty: pretty, indent: indent + 1)
            }
            if pretty { output += "\n" + String(repeating: "  ", count: indent) }
            output += "}"
        }
    }

    private static func writeString(_ value: String, into output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible, Equatable {
    public let offset: Int
    public let reason: String
    public var description: String { "JSON: \(reason) at byte \(offset)" }
}

public extension JSON {
    static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }

    static func parse(_ data: Data) throws -> JSON {
        var parser = Parser(bytes: [UInt8](data))
        return try parser.parseDocument()
    }

    /// Parses a value, returning `nil` for anything that is not valid JSON.
    static func tryParse(_ text: String) -> JSON? {
        try? parse(text)
    }
}

private struct Parser {
    let bytes: [UInt8]
    var index = 0
    var depth = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        // Skip a UTF-8 byte order mark.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { index = 3 }
    }

    mutating func parseDocument() throws -> JSON {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw fail("unexpected trailing characters") }
        return value
    }

    func fail(_ reason: String) -> JSONParseError {
        JSONParseError(offset: index, reason: reason)
    }

    mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x0A, 0x0D, 0x09: index += 1
            default: return
            }
        }
    }

    mutating func parseValue() throws -> JSON {
        guard index < bytes.count else { throw fail("unexpected end of input") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    mutating func expect(_ literal: String) throws {
        for byte in literal.utf8 {
            guard index < bytes.count, bytes[index] == byte else { throw fail("invalid literal") }
            index += 1
        }
    }

    mutating func parseObject() throws -> JSON {
        depth += 1
        guard depth < 512 else { throw fail("nesting too deep") }
        defer { depth -= 1 }
        index += 1
        var object: [String: JSON] = [:]
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail("expected key") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw fail("expected ':'") }
            index += 1
            skipWhitespace()
            object[key] = try parseValue()
            skipWhitespace()
            guard index < bytes.count else { throw fail("unterminated object") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(object)
            }
            throw fail("expected ',' or '}'")
        }
    }

    mutating func parseArray() throws -> JSON {
        depth += 1
        guard depth < 512 else { throw fail("nesting too deep") }
        defer { depth -= 1 }
        index += 1
        var array: [JSON] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(array)
        }
        while true {
            skipWhitespace()
            array.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw fail("unterminated array") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(array)
            }
            throw fail("expected ',' or ']'")
        }
    }

    mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw fail("truncated escape") }
        var value: UInt32 = 0
        for _ in 0 ..< 4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a") ... UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A") ... UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: throw fail("invalid hex digit")
            }
            value = value * 16 + digit
            index += 1
        }
        return value
    }

    mutating func parseString() throws -> String {
        index += 1
        var buffer: [UInt8] = []
        while true {
            guard index < bytes.count else { throw fail("unterminated string") }
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                break
            }
            if byte == UInt8(ascii: "\\") {
                index += 1
                guard index < bytes.count else { throw fail("unterminated escape") }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): buffer.append(0x22)
                case UInt8(ascii: "\\"): buffer.append(0x5C)
                case UInt8(ascii: "/"): buffer.append(0x2F)
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try parseHex4()
                    if (0xD800 ... 0xDBFF).contains(scalar) {
                        // Surrogate pair.
                        if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                            index += 2
                            let low = try parseHex4()
                            if (0xDC00 ... 0xDFFF).contains(low) {
                                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                scalar = 0xFFFD
                            }
                        } else {
                            scalar = 0xFFFD
                        }
                    } else if (0xDC00 ... 0xDFFF).contains(scalar) {
                        scalar = 0xFFFD
                    }
                    let character = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                    buffer.append(contentsOf: Array(String(Character(character)).utf8))
                default:
                    throw fail("invalid escape")
                }
                continue
            }
            buffer.append(byte)
            index += 1
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    mutating func parseNumber() throws -> JSON {
        let start = index
        var isFloat = false
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        var sawDigit = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                sawDigit = true
                index += 1
            } else if byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                isFloat = true
                index += 1
            } else if (byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-")) && isFloat {
                index += 1
            } else {
                break
            }
        }
        guard sawDigit else { throw fail("invalid value") }
        let text = String(decoding: bytes[start ..< index], as: UTF8.self)
        if !isFloat, let value = Int(text) { return .int(value) }
        guard let value = Double(text) else { throw fail("invalid number") }
        return .double(value)
    }
}
