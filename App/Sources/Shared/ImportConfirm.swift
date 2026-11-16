import TunnelCore
import UIKit
import UniformTypeIdentifiers

/// 3.3 (PT-14): what is about to be added, before anything is fetched: a
/// subscription's host (never its path or token) and the device-data switch, or
/// the servers found in the text. Nothing goes over the network until «Добавить».
final class ImportConfirmViewController: FormViewController {
    private let text: String
    private let preview: ImportPreview
    private var sendsDeviceData = Prefs.deviceDataForNewSubscriptions
    private let onAdd: (_ text: String, _ sendsDeviceData: Bool) -> Void

    static func wrapped(_ text: String, onAdd: @escaping (_ text: String, _ sendsDeviceData: Bool) -> Void) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: ImportConfirmViewController(text, onAdd: onAdd))
        navigation.overrideUserInterfaceStyle = Theme.userInterfaceStyle
        return navigation
    }

    init(_ text: String, onAdd: @escaping (_ text: String, _ sendsDeviceData: Bool) -> Void) {
        self.text = text
        preview = ImportPreview.of(text)
        self.onAdd = onAdd
        super.init(title: L("Добавить?"))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: L("Отмена"), primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    }

    override func build() -> [FormSection] {
        switch preview {
        case let .subscription(host):
            return [
                FormSection(L("Подписка"), [
                    .value(title: L("Адрес"), detail: { host }),
                    .note(L("Приложение загрузит подписку с этого адреса. Путь и токен адреса здесь не показаны.")),
                ]),
                FormSection(footer: L("Передаются HWID (свой для этого провайдера), модель iPhone; версия iOS и язык — только если без них панель не отдаёт серверы. Без этих данных некоторые панели не отдают серверы."), [
                    .toggle(title: L("Передавать данные устройства провайдеру"), get: { [weak self] in self?.sendsDeviceData ?? false }, set: { [weak self] in self?.sendsDeviceData = $0 }),
                ]),
                FormSection([.button(title: L("Добавить"), destructive: false) { [weak self] in self?.add() }]),
            ]
        case let .servers(count, protocols, unchecked):
            var rows: [FormRow] = [
                .value(title: L("Серверов"), detail: { "\(count)" }),
                .value(title: L("Протоколы"), detail: { protocols.joined(separator: ", ") }),
            ]
            if unchecked > 0 {
                rows.append(.note(CertificateCheck.summary(count: unchecked) ?? ""))
            }
            return [
                FormSection(L("Серверы из текста"), footer: L("Серверы добавятся отдельной подпиской. По сети ничего не загружается."), rows),
                FormSection([.button(title: L("Добавить"), destructive: false) { [weak self] in self?.add() }]),
            ]
        case let .invalid(reason):
            return [FormSection(L("Нечего добавить"), [.note(reason)])]
        }
    }

    private func add() {
        let text = self.text
        let sends = sendsDeviceData
        let onAdd = self.onAdd
        dismiss(animated: true) { onAdd(text, sends) }
    }
}

/// 3.3 (PT-14): links and subscription addresses carry keys and tokens: they go
/// to the clipboard of this iPhone only (no Universal Clipboard) and leave it
/// after two minutes.
enum Clipboard {
    /// The clipboard's change count right after the app's own copy.
    private static var ownChange: Int?

    static func copySecret(_ text: String) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
        ownChange = UIPasteboard.general.changeCount
    }

    /// Empties the clipboard if it still holds what the app copied (without
    /// reading it, so iOS asks nothing).
    static func clearOwn() {
        guard let ownChange, UIPasteboard.general.changeCount == ownChange else { return }
        UIPasteboard.general.items = []
        self.ownChange = nil
    }
}
