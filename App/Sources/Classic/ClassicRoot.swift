import TunnelCore
import UIKit

/// «Классика»: PERSONAL TUNNEL header, four numbered tabs.
final class ClassicRootViewController: UIViewController {
    private let pages: [UIViewController] = [ClassicHomeViewController(), ClassicServersViewController(), ClassicManageViewController(), ClassicSettingsViewController()]
    private let titles = ["Главная", "Серверы", "Управление", "Настройки"]
    private let counter = Classic.mono("VPN / 01", 10)
    private let container = UIView()
    private let bar = UIStackView(.horizontal, spacing: 0, alignment: .fill, [])
    private var tabs: [TapControl] = []
    private var index = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        let name = Classic.text("PERSONAL TUNNEL", 18, .heavy)
        let header = UIStackView(.horizontal, spacing: 8, alignment: .center, [
            UIStackView(.vertical, spacing: 2, alignment: .leading, [name, Classic.mono("PRIVATE NETWORK", 10)]), UIView(), counter,
        ])
        let top = Classic.rule()
        let bottom = Classic.rule()
        bar.distribution = .fillEqually
        for (offset, title) in titles.enumerated() {
            let number = Classic.mono(String(format: "%02d", offset + 1), 10)
            let label = Classic.text(title, 13)
            let stack = UIStackView(.vertical, spacing: 6, alignment: .center, [number, label])
            let tab = ClassicRow(Classic.padded(stack, UIEdgeInsets(top: 12, left: 0, bottom: 0, right: 0))) { [weak self] in self?.select(offset) }
            tabs.append(tab)
            bar.addArrangedSubview(tab)
        }
        for item in [header, top, container, bottom, bar] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20), header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            top.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12), top.leadingAnchor.constraint(equalTo: view.leadingAnchor), top.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.topAnchor.constraint(equalTo: top.bottomAnchor), container.leadingAnchor.constraint(equalTo: view.leadingAnchor), container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: view.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.topAnchor.constraint(equalTo: bottom.bottomAnchor), bar.leadingAnchor.constraint(equalTo: view.leadingAnchor), bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor), bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -46),
        ])
        for page in pages {
            addChild(page)
            page.view.frame = container.bounds
            page.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            page.view.isHidden = true
            container.addSubview(page.view)
            page.didMove(toParent: self)
        }
        select(0)
        Prefs.appearanceChanged.observe(self) { [weak self] in
            guard let self else { return }
            self.view.backgroundColor = Theme.background
            self.select(self.index)
        }
    }

    func select(_ next: Int) {
        if next != index { Haptics.selection() }
        index = next
        counter.text = String(format: "VPN / %02d", next + 1)
        for (offset, page) in pages.enumerated() { page.view.isHidden = offset != next }
        for (offset, tab) in tabs.enumerated() {
            let active = offset == next
            tab.backgroundColor = active ? Theme.accent.withAlphaComponent(0.16) : .clear
            let labels = (tab.subviews.first?.subviews.first as? UIStackView)?.arrangedSubviews.compactMap { $0 as? UILabel } ?? []
            labels.first?.textColor = active ? Theme.accent : .secondaryLabel
            labels.last?.font = Theme.font(13, active ? .bold : .regular)
        }
    }
}

/// 01 Главная.
final class ClassicHomeViewController: ClassicPage {
    private let session = UILabel(font: Theme.mono(12, .medium))
    private let traffic = UILabel(font: Theme.mono(12, .medium))
    private var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        let app = App.shared
        app.tunnel.state.observe(self, fireNow: false) { [weak self] _ in self?.rebuild() }
        app.store.library.observe(self, fireNow: false) { [weak self] _ in self?.rebuild() }
        app.latency.changed.observe(self, fireNow: false) { [weak self] _ in self?.rebuild() }
        // Only the two labels follow the clock and the counters.
        app.core.status.observe(self) { [weak self] status in
            self?.traffic.text = Format.bytes((status?.downlinkTotal ?? 0) + (status?.uplinkTotal ?? 0))
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let since = App.shared.tunnel.connectedSince.value
        session.text = Format.duration(since.map { Int(Date().timeIntervalSince($0)) } ?? 0)
    }

    override func build() {
        let app = App.shared
        let library = app.library
        let state = app.tunnel.state.value
        let subscription = library.activeSubscription
        let node = library.activeNode
        let on = state.isOn
        let stateText: String
        switch state {
        case .connected, .reasserting: stateText = "Туннель запущен"
        case .connecting: stateText = "Туннель запускается"
        case .disconnecting: stateText = "Туннель останавливается"
        case .disconnected: stateText = "Туннель остановлен"
        }
        let stateColor: UIColor = on ? Theme.connected : (state.isBusy ? .systemYellow : Theme.danger)
        let label = subscription.flatMap { s in node.map { app.store.label(of: $0, in: s) } }
        let entry = subscription.flatMap { s in node.flatMap { app.latency.entry(s.id, $0.id) } }

        // Status frame
        let frame = ClassicFrame(border: .label, width: 2)
        let short = String((subscription?.name ?? "—").prefix(6)).uppercased()
        let position = subscription.flatMap { s in node.flatMap { n in s.nodes.firstIndex { $0.id == n.id } } }.map { $0 + 1 } ?? 0
        frame.add(UIStackView(.horizontal, spacing: 6, alignment: .center, [
            Classic.mono("● " + stateText.uppercased(), 11, stateColor, weight: .bold), UIView(), Classic.mono("\(short) / \(String(format: "%02d", position))", 11, Theme.text),
        ]), insets: UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16))
        frame.stack.addArrangedSubview(Classic.rule())
        func metric(_ caption: String, _ value: UIView) -> UIView { UIStackView(.vertical, spacing: 4, alignment: .leading, [Classic.mono(caption, 9), value]) }
        let pingValue = UILabel(Classic.ping(entry, testing: false), font: Theme.mono(12, .medium))
        tick()
        let info = UIStackView(.vertical, spacing: 8, alignment: .leading, [
            Classic.text(stateText, 22, .semibold),
            UIStackView(.horizontal, spacing: 8, alignment: .center, [Classic.flag(label?.countryCode, width: 22), Classic.text(label?.text ?? "Сервер не выбран", 16)]),
            UIStackView(.horizontal, spacing: 16, alignment: .top, [metric("СЕАНС", session), metric("ТРАФИК", traffic), metric("ПИНГ", pingValue)]),
        ])
        let button = ClassicRow(UIStackView(.vertical, spacing: 8, alignment: .center, [
            { () -> UIView in
                let icon = UIImageView(image: UIImage(systemName: "record.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .regular)))
                icon.tintColor = .label
                return icon
            }(),
            Classic.text(on || state == .connecting ? "DISCONNECT" : "CONNECT", 11, .heavy),
        ]), insets: UIEdgeInsets(top: 22, left: 6, bottom: 18, right: 6)) { App.shared.toggleConnection() }
        button.layer.borderWidth = 2
        button.layer.borderColor = UIColor.label.cgColor
        button.backgroundColor = on ? Theme.accent : .clear
        button.widthAnchor.constraint(equalToConstant: 98).isActive = true
        frame.add(UIStackView(.horizontal, spacing: 12, alignment: .center, [info, UIView(), button]), insets: UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 12))
        frame.stack.addArrangedSubview(Classic.rule())
        frame.add(UIStackView(.horizontal, spacing: 6, alignment: .center, [
            Classic.mono("● " + stateText, 11, Theme.text), UIView(), Classic.mono(Prefs.autoSelect ? "PROXY · AUTO" : "PROXY · MANUAL", 11, Theme.text),
        ]), insets: UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16))
        content.addArrangedSubview(frame)

        // Location
        let all = ClassicRow(Classic.text("ВСЕ ЛОКАЦИИ →", 11, .semibold)) { [weak self] in (self?.parent as? ClassicRootViewController)?.select(1) }
        content.addArrangedSubview(UIStackView(.horizontal, spacing: 8, alignment: .lastBaseline, [Classic.text("Локация", 22, .bold), UIView(), all]))
        let list = ClassicFrame(border: Theme.line)
        let modeIcon = UIImageView(image: UIImage(systemName: "scope", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)))
        modeIcon.tintColor = Theme.panel
        modeIcon.contentMode = .center
        modeIcon.backgroundColor = Theme.accent
        modeIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([modeIcon.widthAnchor.constraint(equalToConstant: 42), modeIcon.heightAnchor.constraint(equalToConstant: 42)])
        let mode = UIStackView(.horizontal, spacing: 14, alignment: .center, [
            modeIcon,
            UIStackView(.vertical, spacing: 4, alignment: .leading, [Classic.text(Prefs.autoSelect ? "Автовыбор" : "Пользовательский", 16, .semibold, .white), Classic.mono((label?.text ?? "—").uppercased(), 9, .lightGray)]),
            UIView(),
            UIStackView(.vertical, spacing: 4, alignment: .trailing, [Classic.text(Classic.ping(entry, testing: false), 14, .semibold, Theme.accent), Classic.mono("BEST", 9, .white, weight: .bold)]),
        ])
        let modeBox = Classic.padded(mode, UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 14))
        modeBox.backgroundColor = Theme.panel
        list.stack.addArrangedSubview(modeBox)
        if let subscription {
            let labels = app.store.labels(for: subscription)
            let selected = library.selectedNodeID(in: subscription)
            // The chosen server first, then the next one in list order.
            var shown = subscription.nodes.filter { $0.id == selected }
            shown += subscription.nodes.filter { $0.id != selected }.prefix(1)
            for item in shown {
                let itemEntry = app.latency.entry(subscription.id, item.id)
                let box = UIView()
                box.layer.borderWidth = 1.5
                box.layer.borderColor = UIColor.label.cgColor
                box.backgroundColor = item.id == selected ? Theme.accent : .clear
                if item.id == selected {
                    let check = UIImageView(image: UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)))
                    check.tintColor = .label
                    check.contentMode = .center
                    box.addSubview(check)
                    check.pin(to: box)
                }
                box.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([box.widthAnchor.constraint(equalToConstant: 20), box.heightAnchor.constraint(equalToConstant: 20)])
                let row = UIStackView(.horizontal, spacing: 12, alignment: .top, [
                    Classic.flag(labels[item.id]?.countryCode),
                    UIStackView(.vertical, spacing: 5, alignment: .leading, [
                        Classic.text(labels[item.id]?.text ?? item.name, 16, .bold), Classic.text(item.facts.summary, 10, .regular, .secondaryLabel),
                        Classic.text(subscription.info.isLimited ? "ЛИМИТНЫЙ" : "ЛИМИТ НЕ УКАЗАН", 10, .medium, Theme.accent),
                    ]),
                    UIView(), Classic.text(Classic.ping(itemEntry, testing: app.latency.isTesting(subscription.id, item.id), upper: false), 14), box,
                ])
                let id = subscription.id, tag = item.id
                list.stack.addArrangedSubview(ClassicRow(row, insets: UIEdgeInsets(top: 14, left: 10, bottom: 12, right: 10)) { App.shared.select(node: tag, in: id) })
                list.stack.addArrangedSubview(Classic.rule())
            }
        }
        content.addArrangedSubview(list)

        // Subscription card
        let card = ClassicFrame(border: Theme.line)
        let folder = UIImageView(image: UIImage(systemName: "folder", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18)))
        folder.tintColor = .label
        folder.setContentHuggingPriority(.required, for: .horizontal)
        let refresh = UIButton(type: .system)
        refresh.setImage(UIImage(systemName: "arrow.clockwise", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17)), for: .normal)
        refresh.tintColor = .label
        refresh.addAction(UIAction { _ in if let id = subscription?.id { App.shared.refresh(id) } }, for: .touchUpInside)
        refresh.setContentHuggingPriority(.required, for: .horizontal)
        let nameLabel = Classic.text(subscription?.name ?? "Нет подписок", 18)
        nameLabel.lineBreakMode = .byTruncatingTail
        let head = ClassicRow(UIStackView(.horizontal, spacing: 12, alignment: .center, [folder, nameLabel])) { [weak self] in
            self?.present(ClassicSubscriptionsSheet.wrapped(), animated: true)
        }
        let delayText = entry.map { "Задержка: " + (app.tunnelSubscription != nil ? "HTTPS " : "TCP ") + Format.ago($0.date) } ?? "Задержка: не измерялась"
        let check = ClassicRow(Classic.text("Проверка соединения и журнал", 18)) { [weak self] in
            let root = DiagnosticsViewController()
            root.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak root] _ in root?.dismiss(animated: true) })
            self?.present(UINavigationController(rootViewController: root), animated: true)
        }
        let body = UIStackView(.vertical, spacing: 10, alignment: .fill, [
            UIStackView(.horizontal, spacing: 8, alignment: .center, [head, refresh]),
            Classic.text("Прокси: Не проверено · Интернет: Не проверено", 12, .regular, .secondaryLabel), check,
            Classic.text(delayText, 11, .regular, .secondaryLabel),
            Classic.text("Пинг и счётчики трафика не подтверждают доступ в интернет.", 11, .regular, .secondaryLabel, lines: 0),
        ])
        card.add(body, insets: UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12))
        content.addArrangedSubview(card)
    }
}

/// Sheet «Подписки»: saved profiles, the active one highlighted.
final class ClassicSubscriptionsSheet: ClassicPage {
    static func wrapped() -> UIViewController {
        let controller = ClassicSubscriptionsSheet()
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 0
        }
        controller.overrideUserInterfaceStyle = Theme.userInterfaceStyle
        return controller
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        App.shared.store.library.observe(self, fireNow: false) { [weak self] _ in self?.rebuild() }
    }

    override func build() {
        let library = App.shared.library
        let close = ClassicRow({ () -> UIView in
            let icon = UIImageView(image: UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)))
            icon.tintColor = Theme.accent
            icon.contentMode = .center
            return icon
        }()) { [weak self] in self?.dismiss(animated: true) }
        close.backgroundColor = Theme.panel
        close.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([close.widthAnchor.constraint(equalToConstant: 38), close.heightAnchor.constraint(equalToConstant: 38)])
        content.addArrangedSubview(UIStackView(.horizontal, spacing: 8, alignment: .bottom, [
            UIStackView(.vertical, spacing: 6, alignment: .leading, [
                Classic.mono("01 —— ПОДКЛЮЧЕНИЕ / ПОДПИСКИ", 9, Theme.accent), Classic.text("Подписки", 34, .bold),
                Classic.text("Сохранённые профили на этом устройстве", 12, .regular, .secondaryLabel),
            ]), UIView(), close,
        ]))
        content.addArrangedSubview(Classic.rule(.label))
        content.addArrangedSubview(UIStackView(.horizontal, spacing: 8, alignment: .center, [
            Classic.mono("ДОБАВЛЕННЫЕ ПОДПИСКИ", 9, Theme.text, weight: .bold), UIView(), Classic.mono(String(format: "%02d", library.subscriptions.count), 9, Theme.accent),
        ]))
        let list = UIStackView(.vertical, spacing: 0, alignment: .fill, [])
        let active = library.activeSubscription?.id
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateStyle = .medium
        for subscription in library.subscriptions {
            let isActive = subscription.id == active
            let tile = Classic.text("URL", 11, .bold, isActive ? Theme.accent : Theme.text)
            tile.textAlignment = .center
            tile.backgroundColor = isActive ? .black : UIColor.systemBackground
            tile.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([tile.widthAnchor.constraint(equalToConstant: 46), tile.heightAnchor.constraint(equalToConstant: 40)])
            var detail = (subscription.isRemote ? "Внешний провайдер" : "Добавлено вручную") + " · " + Format.plural(subscription.nodes.count, "локация", "локации", "локаций")
            if let expires = subscription.info.expiresAt { detail += " · " + formatter.string(from: expires) }
            let name = Classic.text(subscription.name, 15, .semibold)
            name.lineBreakMode = .byTruncatingTail
            var titleViews: [UIView] = [name]
            if isActive { titleViews.append(Classic.mono("АКТИВНА", 9, Theme.accent)) }
            let mark = UIImageView(image: UIImage(systemName: isActive ? "checkmark" : "arrow.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)))
            mark.tintColor = isActive ? Theme.accent : .secondaryLabel
            mark.setContentHuggingPriority(.required, for: .horizontal)
            let detailLabel = Classic.text(detail, 11, .regular, .secondaryLabel)
            detailLabel.lineBreakMode = .byTruncatingTail
            let row = UIStackView(.horizontal, spacing: 12, alignment: .center, [
                tile, UIStackView(.vertical, spacing: 5, alignment: .leading, [UIStackView(.horizontal, spacing: 8, alignment: .center, titleViews), detailLabel]), UIView(), mark,
            ])
            let id = subscription.id
            let control = ClassicRow(row, insets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 14)) {
                guard let target = App.shared.library.subscription(id), let node = App.shared.library.selectedNodeID(in: target) else { return }
                App.shared.select(node: node, in: id)
            }
            control.layer.borderWidth = 1
            control.layer.borderColor = (isActive ? Theme.accent : Theme.line).cgColor
            control.backgroundColor = isActive ? Theme.accent.withAlphaComponent(0.16) : UIColor.secondarySystemGroupedBackground
            list.addArrangedSubview(control)
        }
        content.addArrangedSubview(list)
    }
}
