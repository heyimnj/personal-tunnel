import Foundation

/// A JSON document that keeps integers exact and never confuses `1` with `true`.
///
/// sing-box rejects `1.0` where it expects an integer and `1` where it expects a
/// boolean, so configurations are built and read through this type rather than
/// through `JSONSerialization`.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Reading

public extension JSONValue {
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case let .int(value): return Int(exactly: value)
        case let .double(value):
            guard value.isFinite, value == value.rounded(), abs(value) < 9.0e15 else { return nil }
            return Int(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case let .int(value): return Double(value)
        case let .double(value): return value
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// A string, or a number or boolean written as text. Panels are careless about
    /// quoting ports and flags.
    var text: String? {
        switch self {
        case let .string(value): return value
        case let .int(value): return String(value)
        case let .double(value): return JSONValue.format(value)
        case let .bool(value): return value ? "true" : "false"
        default: return nil
        }
    }

    /// An integer given as a number or as digits in a string.
    var looseInt: Int? {
        if let value = intValue { return value }
        if let value = stringValue?.trimmingCharacters(in: .whitespaces) { return Int(value) }
        return nil
    }

    /// A boolean given as `true`, `1`, `"true"` or `"1"`.
    var looseBool: Bool? {
        switch self {
        case let .bool(value): return value
        case let .int(value): return value != 0
        case let .string(value):
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        default: return nil
        }
    }

    subscript(key: String) -> JSONValue? {
        get {
            if case let .object(value) = self { return value[key] }
            return nil
        }
        set {
            guard case var .object(value) = self else {
                if let newValue { self = .object([key: newValue]) }
                return
            }
            value[key] = newValue
            self = .object(value)
        }
    }

    subscript(index: Int) -> JSONValue? {
        guard case let .array(value) = self, value.indices.contains(index) else { return nil }
        return value[index]
    }

    /// Follows object keys; `nil` as soon as one is missing.
    func at(_ path: String...) -> JSONValue? {
        var current = self
        for key in path {
            guard let next = current[key] else { return nil }
            current = next
        }
        return current
    }

    /// A list given either as an array or as a single value.
    var listValue: [JSONValue] {
        switch self {
        case let .array(value): return value
        case .null: return []
        default: return [self]
        }
    }

    /// Strings of an array, or a comma-separated string split into its parts.
    var stringList: [String] {
        switch self {
        case let .array(values): return values.compactMap(\.text)
        case let .string(value):
            return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default: return []
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }

    public init(nilLiteral: ()) { self = .null }

    public init(_ value: String) { self = .string(value) }
    public init(_ value: Int) { self = .int(Int64(value)) }
    public init(_ value: Bool) { self = .bool(value) }
    public init(_ values: [String]) { self = .array(values.map(JSONValue.string)) }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public let offset: Int
    public var description: String { CoreText.f("JSON: %@ (байт %@)", "\(message)", "\(offset)") }
}

public extension JSONValue {
    /// Parses strict JSON and also tolerates what real files contain: a BOM,
    /// `//` and `/* */` comments and trailing commas.
    static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(bytes: Array(text.utf8))
        return try parser.parseDocument()
    }

    static func parse(_ data: Data) throws -> JSONValue {
        var parser = Parser(bytes: Array(data))
        return try parser.parseDocument()
    }
}

private struct Parser {
    let bytes: [UInt8]
    var index = 0
    var depth = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { index = 3 }
    }

    mutating func parseDocument() throws -> JSONValue {
        let value = try parseValue()
        skipTrivia()
        guard index == bytes.count else { throw error(CoreText.t("лишние данные после документа")) }
        return value
    }

    func error(_ message: String) -> JSONParseError {
        JSONParseError(message: message, offset: index)
    }

    mutating func skipTrivia() {
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
                index += 1
            } else if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2F {
                index += 2
                while index < bytes.count, bytes[index] != 0x0A { index += 1 }
            } else if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2A {
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == 0x2A && bytes[index + 1] == 0x2F) { index += 1 }
                index = min(bytes.count, index + 2)
            } else {
                break
            }
        }
    }

    mutating func parseValue() throws -> JSONValue {
        skipTrivia()
        guard index < bytes.count else { throw error(CoreText.t("неожиданный конец")) }
        switch bytes[index] {
        case 0x7B: return try parseObject()
        case 0x5B: return try parseArray()
        case 0x22: return .string(try parseString())
        case 0x74: try expect("true"); return .bool(true)
        case 0x66: try expect("false"); return .bool(false)
        case 0x6E: try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    mutating func expect(_ word: String) throws {
        let expected = Array(word.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index ..< index + expected.count]) == expected else {
            throw error(CoreText.f("ожидалось %@", "\(word)"))
        }
        index += expected.count
    }

    mutating func parseObject() throws -> JSONValue {
        depth += 1
        defer { depth -= 1 }
        guard depth < 200 else { throw error(CoreText.t("слишком глубокая вложенность")) }
        index += 1
        var result: [String: JSONValue] = [:]
        while true {
            skipTrivia()
            guard index < bytes.count else { throw error(CoreText.t("объект не закрыт")) }
            if bytes[index] == 0x7D { index += 1; return .object(result) }
            guard bytes[index] == 0x22 else { throw error(CoreText.t("ожидался ключ")) }
            let key = try parseString()
            skipTrivia()
            guard index < bytes.count, bytes[index] == 0x3A else { throw error(CoreText.t("ожидалось двоеточие")) }
            index += 1
            result[key] = try parseValue()
            skipTrivia()
            guard index < bytes.count else { throw error(CoreText.t("объект не закрыт")) }
            if bytes[index] == 0x2C { index += 1; continue }
            if bytes[index] == 0x7D { index += 1; return .object(result) }
            throw error(CoreText.t("ожидалась запятая"))
        }
    }

    mutating func parseArray() throws -> JSONValue {
        depth += 1
        defer { depth -= 1 }
        guard depth < 200 else { throw error(CoreText.t("слишком глубокая вложенность")) }
        index += 1
        var result: [JSONValue] = []
        while true {
            skipTrivia()
            guard index < bytes.count else { throw error(CoreText.t("массив не закрыт")) }
            if bytes[index] == 0x5D { index += 1; return .array(result) }
            result.append(try parseValue())
            skipTrivia()
            guard index < bytes.count else { throw error(CoreText.t("массив не закрыт")) }
            if bytes[index] == 0x2C { index += 1; continue }
            if bytes[index] == 0x5D { index += 1; return .array(result) }
            throw error(CoreText.t("ожидалась запятая"))
        }
    }

    mutating func parseString() throws -> String {
        index += 1
        var buffer: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                return String(decoding: buffer, as: UTF8.self)
            }
            if byte == 0x5C {
                index += 1
                guard index < bytes.count else { break }
                let escape = bytes[index]
                index += 1
                switch escape {
                case 0x22: buffer.append(0x22)
                case 0x5C: buffer.append(0x5C)
                case 0x2F: buffer.append(0x2F)
                case 0x62: buffer.append(0x08)
                case 0x66: buffer.append(0x0C)
                case 0x6E: buffer.append(0x0A)
                case 0x72: buffer.append(0x0D)
                case 0x74: buffer.append(0x09)
                case 0x75:
                    var unit = try parseHex4()
                    if (0xD800 ... 0xDBFF).contains(unit), index + 1 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 {
                        let saved = index
                        index += 2
                        let low = try parseHex4()
                        if (0xDC00 ... 0xDFFF).contains(low) {
                            unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            index = saved
                        }
                    }
                    let scalar = Unicode.Scalar(unit) ?? Unicode.Scalar(0xFFFD)!
                    buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    throw error(CoreText.t("неизвестная экранирующая последовательность"))
                }
                continue
            }
            buffer.append(byte)
            index += 1
        }
        throw error(CoreText.t("строка не закрыта"))
    }

    mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw error(CoreText.t("обрыв в \\u")) }
        var value: UInt32 = 0
        for _ in 0 ..< 4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case 0x30 ... 0x39: digit = UInt32(byte - 0x30)
            case 0x41 ... 0x46: digit = UInt32(byte - 0x41 + 10)
            case 0x61 ... 0x66: digit = UInt32(byte - 0x61 + 10)
            default: throw error(CoreText.t("неверная цифра в \\u"))
            }
            value = value * 16 + digit
            index += 1
        }
        return value
    }

    mutating func parseNumber() throws -> JSONValue {
        let start = index
        var isInteger = true
        if index < bytes.count, bytes[index] == 0x2D || bytes[index] == 0x2B { index += 1 }
        while index < bytes.count {
            let byte = bytes[index]
            if byte >= 0x30, byte <= 0x39 {
                index += 1
            } else if byte == 0x2E || byte == 0x65 || byte == 0x45 || byte == 0x2D || byte == 0x2B {
                isInteger = false
                index += 1
            } else {
                break
            }
        }
        guard index > start else { throw error(CoreText.t("неожиданный символ")) }
        let literal = String(decoding: bytes[start ..< index], as: UTF8.self)
        if isInteger, let value = Int64(literal) { return .int(value) }
        guard let value = Double(literal), value.isFinite else { throw error(CoreText.t("неверное число")) }
        return .double(value)
    }
}

// MARK: - Writing

public extension JSONValue {
    /// Compact or indented JSON with keys in a stable (sorted) order.
    func serialized(pretty: Bool = false) -> String {
        var output = [UInt8]()
        output.reserveCapacity(1024)
        write(into: &output, pretty: pretty, indent: 0)
        return String(decoding: output, as: UTF8.self)
    }

    func serializedData(pretty: Bool = false) -> Data {
        Data(serialized(pretty: pretty).utf8)
    }

    fileprivate static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 9.0e15 { return String(Int64(value)) }
        return "\(value)"
    }

    private func write(into output: inout [UInt8], pretty: Bool, indent: Int) {
        switch self {
        case .null: output.append(contentsOf: Array("null".utf8))
        case let .bool(value): output.append(contentsOf: Array((value ? "true" : "false").utf8))
        case let .int(value): output.append(contentsOf: Array(String(value).utf8))
        case let .double(value): output.append(contentsOf: Array(JSONValue.format(value).utf8))
        case let .string(value): JSONValue.writeString(value, into: &output)
        case let .array(values):
            if values.isEmpty { output.append(contentsOf: [0x5B, 0x5D]); return }
            output.append(0x5B)
            for (offset, value) in values.enumerated() {
                if offset > 0 { output.append(0x2C) }
                if pretty { JSONValue.newline(&output, indent + 1) }
                value.write(into: &output, pretty: pretty, indent: indent + 1)
            }
            if pretty { JSONValue.newline(&output, indent) }
            output.append(0x5D)
        case let .object(values):
            if values.isEmpty { output.append(contentsOf: [0x7B, 0x7D]); return }
            output.append(0x7B)
            for (offset, key) in values.keys.sorted().enumerated() {
                if offset > 0 { output.append(0x2C) }
                if pretty { JSONValue.newline(&output, indent + 1) }
                JSONValue.writeString(key, into: &output)
                output.append(0x3A)
                if pretty { output.append(0x20) }
                values[key]!.write(into: &output, pretty: pretty, indent: indent + 1)
            }
            if pretty { JSONValue.newline(&output, indent) }
            output.append(0x7D)
        }
    }

    private static func newline(_ output: inout [UInt8], _ indent: Int) {
        output.append(0x0A)
        output.append(contentsOf: [UInt8](repeating: 0x20, count: indent * 2))
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    private static func writeString(_ value: String, into output: inout [UInt8]) {
        output.append(0x22)
        for byte in value.utf8 {
            switch byte {
            case 0x22: output.append(contentsOf: [0x5C, 0x22])
            case 0x5C: output.append(contentsOf: [0x5C, 0x5C])
            case 0x0A: output.append(contentsOf: [0x5C, 0x6E])
            case 0x0D: output.append(contentsOf: [0x5C, 0x72])
            case 0x09: output.append(contentsOf: [0x5C, 0x74])
            case 0x00 ... 0x1F:
                output.append(contentsOf: [0x5C, 0x75, 0x30, 0x30, hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0x0F)]])
            default: output.append(byte)
            }
        }
        output.append(0x22)
    }
}
