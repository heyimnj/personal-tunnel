import TunnelCore
import UIKit

/// «Создать вручную» and «Редактировать»: a server's fields by protocol (both styles).
final class ServerEditorViewController: FormViewController {
    private var draft: ServerDraft
    private let onSave: (JSONValue, String) -> Void

    static func wrapped(_ draft: ServerDraft = ServerDraft(), title: String, onSave: @escaping (JSONValue, String) -> Void) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: ServerEditorViewController(draft, title: title, onSave: onSave))
        navigation.overrideUserInterfaceStyle = Theme.userInterfaceStyle
        return navigation
    }

    init(_ draft: ServerDraft, title: String, onSave: @escaping (JSONValue, String) -> Void) {
        self.draft = draft
        self.onSave = onSave
        super.init(title: title)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .save, primaryAction: UIAction { [weak self] _ in self?.save() })
        tableView.keyboardDismissMode = .interactive
    }

    private func save() {
        view.endEditing(true)
        do {
            let outbound = try draft.outbound()
            let name = draft.name.trimmingCharacters(in: .whitespaces)
            onSave(outbound, name.isEmpty ? draft.host : name)
            Haptics.result(true)
            dismiss(animated: true)
        } catch {
            Haptics.result(false)
            App.shared.notice.value = (error as? ImportError)?.message ?? error.localizedDescription
        }
    }

    private func field(_ title: String, _ placeholder: String = "", _ keyPath: WritableKeyPath<ServerDraft, String>, keyboard: UIKeyboardType = .asciiCapable) -> FormRow {
        .field(title: title, placeholder: placeholder, get: { [weak self] in self?.draft[keyPath: keyPath] ?? "" },
               set: { [weak self] in self?.draft[keyPath: keyPath] = $0 }, keyboard: keyboard)
    }

    override func build() -> [FormSection] {
        var sections = [
            FormSection([
                .field(title: L("Название"), placeholder: L("Необязательно"), get: { [weak self] in self?.draft.name ?? "" },
                       set: { [weak self] in self?.draft.name = $0 }, keyboard: .default),
                .picker(title: L("Протокол"), options: ServerDraft.Proto.allCases.map { ($0.rawValue, $0.title) },
                        get: { [weak self] in self?.draft.proto.rawValue ?? "" },
                        set: { [weak self] in self?.draft.proto = ServerDraft.Proto(rawValue: $0) ?? .vless }),
            ]),
        ]
        let proto = draft.proto
        var server: [FormRow] = [field(L("Адрес"), "example.com", \.host, keyboard: .URL), field(L("Порт"), "443", \.port, keyboard: .numberPad)]
        switch proto {
        case .vless, .vmess:
            server.append(field("UUID", "xxxxxxxx-xxxx-…", \.secret))
        case .trojan, .hysteria2:
            server.append(field(L("Пароль"), "", \.secret))
        case .shadowsocks:
            server.append(.picker(title: L("Шифрование"), options: ServerDraft.shadowsocksMethods.map { ($0, $0) },
                                  get: { [weak self] in self?.draft.method ?? "" }, set: { [weak self] in self?.draft.method = $0 }))
            server.append(field(L("Пароль"), "", \.secret))
        case .tuic:
            server.append(field("UUID", "xxxxxxxx-xxxx-…", \.secret))
            server.append(field(L("Пароль"), "", \.password))
            server.append(.picker(title: L("Управление перегрузкой"), options: [("bbr", "BBR"), ("cubic", "CUBIC"), ("new_reno", "NewReno")],
                                  get: { [weak self] in self?.draft.congestion ?? "bbr" }, set: { [weak self] in self?.draft.congestion = $0 }))
        case .wireguard:
            server.append(field(L("Закрытый ключ"), "", \.privateKey))
            server.append(field(L("Ключ сервера"), "", \.peerPublicKey))
            server.append(field(L("Общий ключ"), L("Необязательно"), \.preSharedKey))
            server.append(field(L("Адрес интерфейса"), "10.7.0.2", \.localAddress))
            server.append(field("MTU", "1280", \.mtu, keyboard: .numberPad))
        }
        if proto == .hysteria2 {
            server.append(field(L("Обфускация"), L("Пароль salamander"), \.obfsPassword))
            server.append(field(L("Порты"), "20000-30000", \.hopPorts))
        }
        sections.append(FormSection(L("Сервер"), server))
        guard proto != .wireguard else { return sections }

        if proto.hasTransport {
            var transport: [FormRow] = [
                .picker(title: L("Транспорт"), options: [("tcp", "TCP"), ("ws", "WebSocket"), ("grpc", "gRPC"), ("httpupgrade", "HTTPUpgrade"), ("xhttp", "XHTTP")],
                        get: { [weak self] in self?.draft.transport.rawValue ?? "tcp" },
                        set: { [weak self] in self?.draft.transport = ServerDraft.Transport(rawValue: $0) ?? .tcp }),
            ]
            switch draft.transport {
            case .tcp:
                if proto == .vless {
                    transport.append(.toggle(title: "Vision (xtls-rprx-vision)", get: { [weak self] in self?.draft.vision ?? false },
                                             set: { [weak self] in self?.draft.vision = $0 }))
                }
            case .grpc:
                transport.append(field(L("Имя сервиса"), "", \.serviceName))
            case .ws, .httpupgrade, .xhttp:
                transport.append(field(L("Путь"), "/", \.path))
                transport.append(field("Host", L("Необязательно"), \.hostHeader, keyboard: .URL))
            }
            sections.append(FormSection(L("Транспорт"), transport))
        }

        var tls: [FormRow] = []
        if proto.hasTransport {
            tls.append(.picker(title: L("Защита"), options: [("none", L("Нет")), ("tls", "TLS"), ("reality", "Reality")],
                               get: { [weak self] in self?.draft.security.rawValue ?? "tls" },
                               set: { [weak self] in self?.draft.security = ServerDraft.Security(rawValue: $0) ?? .tls }))
        }
        if proto.isQUIC || draft.security != .none {
            tls.append(field("SNI", L("По адресу сервера"), \.sni, keyboard: .URL))
            if proto.hasTransport {
                tls.append(.picker(title: L("Отпечаток"), options: ServerDraft.fingerprints.map { ($0, $0) },
                                   get: { [weak self] in self?.draft.fingerprint ?? "chrome" }, set: { [weak self] in self?.draft.fingerprint = $0 }))
            }
            if draft.security == .reality, proto.hasTransport {
                tls.append(field(L("Публичный ключ"), "", \.publicKey))
                tls.append(field("Short ID", L("Необязательно"), \.shortID))
            } else {
                tls.append(field("ALPN", "h2,http/1.1", \.alpn))
                tls.append(.toggle(title: L("Не проверять сертификат"), get: { [weak self] in self?.draft.insecure ?? false },
                                   set: { [weak self] in self?.draft.insecure = $0 }))
            }
        }
        if !tls.isEmpty { sections.append(FormSection("TLS", tls)) }
        return sections
    }
}
