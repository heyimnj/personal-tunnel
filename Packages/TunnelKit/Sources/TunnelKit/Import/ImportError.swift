import Foundation

/// Why an entry could not be imported. Messages are Russian, the app's
/// primary language; the app layer translates them for other languages.
public enum ImportError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty
    case unrecognizedFormat
    case invalidLink(String)
    case missingField(String)
    case unsupportedProtocol(String)
    case unsupportedTransport(String)
    case unsupportedOption(String)
    case invalidJSON(String)
    case invalidYAML(String)

    public var description: String {
        switch self {
        case .empty:
            return "Пустой ответ: в подписке нет серверов."
        case .unrecognizedFormat:
            return "Формат не распознан. Поддерживаются ссылки серверов, Base64-список, sing-box JSON, Xray JSON, Clash YAML и WireGuard .conf."
        case let .invalidLink(detail):
            return "Некорректная ссылка: \(detail)."
        case let .missingField(field):
            return "Не хватает параметра «\(field)»."
        case let .unsupportedProtocol(name):
            return "Протокол \(name) не входит в сборку Personal Tunnel."
        case let .unsupportedTransport(name):
            return "Транспорт \(name) не поддерживается ядром sing-box."
        case let .unsupportedOption(detail):
            return "Параметр не поддерживается: \(detail)."
        case let .invalidJSON(detail):
            return "Некорректный JSON: \(detail)."
        case let .invalidYAML(detail):
            return "Некорректный YAML: \(detail)."
        }
    }
}

/// Protocols the core is built without. Imports name them explicitly instead
/// of silently dropping the server.
enum UnsupportedProtocols {
    static let schemes: [String: String] = [
        "ssr": "ShadowsocksR",
        "shadowsocksr": "ShadowsocksR",
        "openvpn": "OpenVPN",
        "ovpn": "OpenVPN",
        "openconnect": "OpenConnect",
        "anyconnect": "OpenConnect",
        "tailscale": "Tailscale",
        "mieru": "Mieru",
        "mierus": "Mieru",
        "juicity": "Juicity",
        "brook": "Brook",
        "snell": "Snell",
        "ssh": "SSH",
        "kcp": "mKCP",
    ]
}
