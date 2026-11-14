import CoreImage.CIFilterBuiltins
import TunnelCore
import UIKit

/// «Ссылка, QR и JSON» (1.5.0's server page): protocol facts, the server's own
/// link and its QR code, the configuration without secrets. Both styles open it.
final class ServerInspectorViewController: FormViewController {
    private let subscriptionID: Int64
    private let tag: String

    init(node: ServerNode, subscription: Subscription) {
        subscriptionID = subscription.id
        tag = node.id
        super.init(title: L("Ссылка, QR и JSON"))
    }

    private var current: (Subscription, ServerNode)? {
        guard let subscription = App.shared.library.subscription(subscriptionID), let node = subscription.node(tag) else { return nil }
        return (subscription, node)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        App.shared.latency.changed.observe(self, fireNow: false) { [weak self] keys in
            guard let self, keys.contains(LatencyService.key(self.subscriptionID, self.tag)) else { return }
            self.rebuild()
        }
        App.shared.store.library.observe(self, fireNow: false) { [weak self] _ in self?.rebuild() }
    }

    override func build() -> [FormSection] {
        guard let pair = current else { return [FormSection([.note(L("Сервер не найден."))])] }
        let (subscription, node) = pair
        let name = App.shared.store.label(of: node, in: subscription).text
        var facts: [FormRow] = [.value(title: L("Протокол"), detail: { node.facts.summary })]
        for (title, value) in ServerInspection.details(node) { facts.append(.value(title: title, detail: { value })) }
        facts.append(.value(title: L("Задержка"), detail: { [subscriptionID, tag] in
            if App.shared.latency.isTesting(subscriptionID, tag) { return L("проверяется…") }
            switch App.shared.latency.entry(subscriptionID, tag)?.result {
            case let .delay(value)?: return "\(value) ms"
            case let .failed(reason)?: return reason.title
            case nil: return "—"
            }
        }))
        facts.append(.value(title: L("Сертификат"), detail: { ServerInspection.certificateCheck(node) }))
        let link = node.link
        // 3.1.2: the core's own words for the last failed test, so a «certificate»
        // or a «timeout» says what exactly went wrong.
        var failure: [FormSection] = []
        if case .failed? = App.shared.latency.entry(subscriptionID, tag)?.result,
           let note = FailureNotes.shared.note(LatencyService.key(subscriptionID, tag)) {
            failure = [FormSection(L("Ошибка последней проверки"), [.note(note)])]
        }
        var jsonRows: [FormRow] = [
            .button(title: L("Показать JSON без секретов"), destructive: false) { [weak self] in self?.showJSON(ServerInspection.safeJSON(node)) },
        ]
        // 3.1.2: what the provider gave (its Xray JSON or link), secrets and
        // addresses hidden, to compare with what the app made of it.
        if let source = ServerInspection.safeSource(node) {
            jsonRows.append(.button(title: L("Как сервер пришёл от провайдера"), destructive: false) { [weak self] in self?.showJSON(source) })
        }
        jsonRows.append(.button(title: L("Скопировать JSON без секретов"), destructive: false) { [weak self] in
            self?.copy(ServerInspection.safeJSON(node), done: L("JSON скопирован."))
        })
        return [
            FormSection(name, facts + [
                .button(title: L("Проверить пинг этого узла"), destructive: false) { App.shared.ping(node: node, in: subscription) },
            ]),
        ] + failure + [
            FormSection(L("Ссылка"), footer: link == nil ? L("У этого сервера нет исходной ссылки: он добавлен из файла или из подписки в формате JSON.") : nil, [
                .button(title: L("Скопировать ссылку на сервер"), destructive: false) { [weak self] in self?.copy(link, done: L("Ссылка скопирована.")) },
                .button(title: L("QR-код сервера"), destructive: false) { [weak self] in self?.showQR(link, name: name) },
            ]),
            FormSection("JSON", footer: L("Пароли, UUID и ключи заменены на ***."), jsonRows),
        ]
    }

    private func copy(_ text: String?, done: String) {
        guard let text, !text.isEmpty else {
            App.shared.notice.value = L("У этого сервера нет исходной ссылки: он добавлен из файла или из подписки в формате JSON.")
            return
        }
        UIPasteboard.general.string = text
        Haptics.result(true)
        App.shared.notice.value = done
    }

    private func showJSON(_ text: String) {
        let page = UIViewController()
        page.title = "JSON"
        page.view.backgroundColor = Theme.background
        let view = UITextView()
        view.isEditable = false
        view.backgroundColor = .clear
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.text = text
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        page.view.addSubview(view)
        view.pin(to: page.view)
        navigationController?.pushViewController(page, animated: true)
    }

    private func showQR(_ link: String?, name: String) {
        guard let link, !link.isEmpty, let image = Self.qr(link) else {
            App.shared.notice.value = L("У этого сервера нет исходной ссылки: он добавлен из файла или из подписки в формате JSON.")
            return
        }
        let page = UIViewController()
        page.title = name
        page.view.backgroundColor = Theme.background
        let code = UIImageView(image: image)
        code.contentMode = .scaleAspectFit
        code.layer.magnificationFilter = .nearest
        // The quiet zone a scanner needs: white around the code.
        let picture = UIView()
        picture.backgroundColor = .white
        picture.layer.cornerRadius = 20
        picture.layer.cornerCurve = .continuous
        picture.addSubview(code)
        code.pin(to: picture, insets: UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20))
        let note = UILabel(L("Отсканируйте в другом клиенте. В коде — полная ссылка с ключом: не показывайте его посторонним."),
                           font: Theme.font(.footnote), color: .secondaryLabel, lines: 0)
        note.textAlignment = .center
        let stack = UIStackView(.vertical, spacing: 20, alignment: .center, [picture, note])
        page.view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: page.view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: page.view.trailingAnchor, constant: -32),
            picture.widthAnchor.constraint(equalTo: stack.widthAnchor),
            picture.heightAnchor.constraint(equalTo: picture.widthAnchor),
        ])
        navigationController?.pushViewController(page, animated: true)
    }

    private static func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
