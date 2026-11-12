import TunnelCore
import UIKit

/// «Создать вручную» and «Редактировать»: a server's fields by protocol (both styles).
/// Every row carries its symbol; long values (UUID, keys, address) sit under their
/// title and wrap, so they are seen whole. Editing writes the fields over the server
/// as it was (`ServerDraft.outbound(updating:)`): settings the form does not show
/// stay as they were.
final class ServerEditorViewController: FormViewController {
    private var draft: ServerDraft
    private let original: JSONValue?
    private let onSave: (JSONValue, String) -> Void

    static func wrapped(_ draft: ServerDraft = ServerDraft(), original: JSONValue? = nil, title: String,
                        onSave: @escaping (JSONValue, String) -> Void) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: ServerEditorViewController(draft, original: original, title: title, onSave: onSave))
        navigation.overrideUserInterfaceStyle = Theme.userInterfaceStyle
        return navigation
    }

    init(_ draft: ServerDraft, original: JSONValue? = nil, title: String, onSave: @escaping (JSONValue, String) -> Void) {
        self.draft = draft
        self.original = original
        self.onSave = onSave
        super.init(title: title)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let close = UIBarButtonItem(image: UIImage(systemName: "xmark"), primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        close.accessibilityLabel = L("Отмена")
        close.tintColor = .label
        let save = UIBarButtonItem(image: UIImage(systemName: "checkmark"), primaryAction: UIAction { [weak self] _ in self?.save() })
        save.accessibilityLabel = L("Сохранить")
        if #available(iOS 26.0, *) {
            save.style = .prominent
            save.tintColor = Theme.accent
        }
        navigationItem.leftBarButtonItem = close
        navigationItem.rightBarButtonItem = save
        tableView.keyboardDismissMode = .interactive
    }

    private func save() {
        view.endEditing(true)
        do {
            let outbound = try original.map { try draft.outbound(updating: $0) } ?? draft.outbound()
            let name = draft.name.trimmingCharacters(in: .whitespaces)
            onSave(outbound, name.isEmpty ? draft.host : name)
            Haptics.result(true)
            dismiss(animated: true)
        } catch {
            Haptics.result(false)
            App.shared.notice.value = (error as? ImportError)?.message ?? error.localizedDescription
        }
    }

    private func field(_ symbol: String, _ title: String, _ placeholder: String = "", _ keyPath: WritableKeyPath<ServerDraft, String>,
                       keyboard: UIKeyboardType = .asciiCapable, long: Bool = false) -> FormRow {
        let get: () -> String = { [weak self] in self?.draft[keyPath: keyPath] ?? "" }
        let set: (String) -> Void = { [weak self] in self?.draft[keyPath: keyPath] = $0 }
        return .symbol(symbol, long ? .text(title: title, placeholder: placeholder, get: get, set: set, keyboard: keyboard)
            : .field(title: title, placeholder: placeholder, get: get, set: set, keyboard: keyboard))
    }

    private func picker(_ symbol: String, _ title: String, _ options: [(value: String, title: String)],
                        get: @escaping (ServerDraft) -> String, set: @escaping (inout ServerDraft, String) -> Void) -> FormRow {
        .symbol(symbol, .picker(title: title, options: options, get: { [weak self] in self.map { get($0.draft) } ?? "" },
                                set: { [weak self] value in
                                    guard let self else { return }
                                    set(&self.draft, value)
                                }))
    }

    private func toggle(_ symbol: String, _ title: String, _ keyPath: WritableKeyPath<ServerDraft, Bool>) -> FormRow {
        .symbol(symbol, .toggle(title: title, get: { [weak self] in self?.draft[keyPath: keyPath] ?? false },
                                set: { [weak self] in self?.draft[keyPath: keyPath] = $0 }))
    }

    override func build() -> [FormSection] {
        let proto = draft.proto
        var sections = [
            FormSection([
                .symbol("tag", .field(title: L("Название"), placeholder: L("Необязательно"), get: { [weak self] in self?.draft.name ?? "" },
                                      set: { [weak self] in self?.draft.name = $0 }, keyboard: .default)),
            ]),
            FormSection([
                picker("arrow.triangle.swap", L("Протокол"), ServerDraft.Proto.allCases.map { ($0.rawValue, $0.title) },
                       get: { $0.proto.rawValue }, set: { $0.proto = ServerDraft.Proto(rawValue: $1) ?? .vless }),
            ]),
        ]
        var server: [FormRow] = [field("globe", L("Адрес"), "example.com", \.host, keyboard: .URL, long: true),
                                 field("number", L("Порт"), "443", \.port, keyboard: .numberPad)]
        switch proto {
        case .vless, .vmess:
            server.append(field("key", "UUID", "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", \.secret, long: true))
        case .trojan, .hysteria2:
            server.append(field("lock", L("Пароль"), "", \.secret, long: true))
        case .shadowsocks:
            server.append(picker("lock.shield", L("Шифрование"), ServerDraft.shadowsocksMethods.map { ($0, $0) },
                                 get: { $0.method }, set: { $0.method = $1 }))
            server.append(field("lock", L("Пароль"), "", \.secret, long: true))
        case .tuic:
            server.append(field("key", "UUID", "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", \.secret, long: true))
            server.append(field("lock", L("Пароль"), "", \.password, long: true))
            server.append(picker("speedometer", L("Управление перегрузкой"), [("bbr", "BBR"), ("cubic", "CUBIC"), ("new_reno", "NewReno")],
                                 get: { $0.congestion }, set: { $0.congestion = $1 }))
        case .wireguard:
            server.append(field("key.fill", L("Закрытый ключ"), "", \.privateKey, long: true))
            server.append(field("key", L("Ключ сервера"), "", \.peerPublicKey, long: true))
            server.append(field("key.horizontal", L("Общий ключ"), L("Необязательно"), \.preSharedKey, long: true))
            server.append(field("network", L("Адрес интерфейса"), "10.7.0.2", \.localAddress, long: true))
            server.append(field("ruler", "MTU", "1280", \.mtu, keyboard: .numberPad))
        }
        if proto == .hysteria2 {
            server.append(field("eye.slash", L("Обфускация"), L("Пароль salamander"), \.obfsPassword, long: true))
            server.append(field("arrow.left.and.right", L("Порты"), "20000-30000", \.hopPorts))
        }
        sections.append(FormSection(L("Сервер"), server))
        guard proto != .wireguard else { return sections }

        // Vision exists only over TCP with TLS or Reality: offered only there.
        if proto == .vless, draft.transport == .tcp, draft.security != .none {
            sections.append(FormSection([
                picker("arrow.left.arrow.right", "Flow", [("", L("Нет")), ("vision", "Vision")],
                       get: { $0.vision ? "vision" : "" }, set: { $0.vision = $1 == "vision" }),
            ]))
        }

        if proto.hasTransport {
            var transport: [FormRow] = [
                picker("arrow.up.arrow.down", L("Транспорт"), [("tcp", "TCP"), ("ws", "WebSocket"), ("grpc", "gRPC"), ("httpupgrade", "HTTPUpgrade"), ("xhttp", "XHTTP")],
                       get: { $0.transport.rawValue }, set: { $0.transport = ServerDraft.Transport(rawValue: $1) ?? .tcp }),
            ]
            switch draft.transport {
            case .tcp: break
            case .grpc:
                transport.append(field("square.stack.3d.up", L("Имя сервиса"), "", \.serviceName))
            case .ws, .httpupgrade, .xhttp:
                transport.append(field("signpost.right", L("Путь"), "/", \.path, long: true))
                transport.append(field("server.rack", "Host", L("Необязательно"), \.hostHeader, keyboard: .URL, long: true))
            }
            sections.append(FormSection(L("Транспорт"), transport))
        }

        var tls: [FormRow] = []
        if proto.hasTransport {
            tls.append(picker("shield.lefthalf.filled", L("Защита"), [("none", L("Нет")), ("tls", "TLS"), ("reality", "Reality")],
                              get: { $0.security.rawValue }, set: { $0.security = ServerDraft.Security(rawValue: $1) ?? .tls }))
        }
        if proto.isQUIC || draft.security != .none {
            tls.append(field("network", "SNI", L("По адресу сервера"), \.sni, keyboard: .URL, long: true))
            if draft.security == .reality, proto.hasTransport {
                tls.append(field("key.horizontal", L("Публичный ключ"), "", \.publicKey, long: true))
                tls.append(field("person.text.rectangle", "Short ID", L("Необязательно"), \.shortID))
            }
            if proto.hasTransport {
                // Reality needs a uTLS fingerprint; TLS can go without one.
                let none: [(value: String, title: String)] = draft.security == .reality ? [] : [("", L("Нет"))]
                tls.append(picker("hand.raised", L("Отпечаток"), none + ServerDraft.fingerprints.map { ($0, Self.fingerprintTitle($0)) },
                                  get: { $0.fingerprint.isEmpty && $0.security == .reality ? "chrome" : $0.fingerprint }, set: { $0.fingerprint = $1 }))
            }
            if draft.security != .reality {
                tls.append(field("list.bullet", "ALPN", "h2,http/1.1", \.alpn))
                tls.append(toggle("exclamationmark.shield", L("Не проверять сертификат"), \.insecure))
            }
        }
        if !tls.isEmpty { sections.append(FormSection("TLS", tls)) }
        return sections
    }

    private static func fingerprintTitle(_ value: String) -> String {
        switch value {
        case "ios": return "iOS"
        case "qq": return "QQ"
        case "random": return L("Случайный")
        case "randomized": return L("Случайный (каждый раз)")
        default: return value.prefix(1).uppercased() + value.dropFirst()
        }
    }
}
