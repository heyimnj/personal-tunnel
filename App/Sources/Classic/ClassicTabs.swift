import TunnelCore
import UIKit

/// 02 Серверы — «Все локации».
final class ClassicServersViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    private let table = UITableView(frame: .zero, style: .plain)
    private let heading = Classic.micro("ЛОКАЦИИ / 00")
    private let pingButton = TapControl()
    private let pingIcon = UIImageView()
    private let pingLabel = Classic.mono("ПИНГ", 12, .white, weight: .bold)
    private let pingSpinner = UIActivityIndicatorView(style: .medium)
    private let search = UITextField()
    private let filters = UIStackView(.horizontal, spacing: 22, alignment: .center, [])
    private let groupTitle = UILabel("Доступные серверы", font: Classic.rounded(14, .semibold))
    private let groupKicker = Classic.micro("")
    private let groupCount = Classic.mono("00", 18, Theme.text, weight: .semibold)
    private let groupProgress = Classic.micro("")
    private var filter = 0
    private var rows: [ServerNode] = []
    private var subscription: Subscription?
    private var labels: [String: ServerLabels.Label] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        // 1.5.0 `SheetScaffold`: kicker, 24 pt title, a 36 pt dark close square.
        let close = UIImageView(image: UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)))
        close.tintColor = Theme.accent
        close.contentMode = .center
        let closeBox = ClassicRow(close) { [weak self] in (self?.parent as? ClassicRootViewController)?.select(0) }
        closeBox.backgroundColor = Theme.panel
        closeBox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([closeBox.widthAnchor.constraint(equalToConstant: 36), closeBox.heightAnchor.constraint(equalToConstant: 36)])
        let title = UIStackView(.horizontal, spacing: 12, alignment: .top, [
            UIStackView(.vertical, spacing: 6, alignment: .leading, [heading, Classic.text("Все локации", 24, .semibold)]), UIView(), closeBox,
        ])
        pingIcon.tintColor = .white
        pingSpinner.color = .white
        pingSpinner.hidesWhenStopped = true
        let pingRow = UIStackView(.horizontal, spacing: 10, alignment: .center, [pingIcon, pingLabel])
        pingRow.isUserInteractionEnabled = false
        pingButton.pressScale = 1
        pingButton.backgroundColor = Theme.panel
        for item in [pingRow, pingSpinner] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            pingButton.addSubview(item)
        }
        NSLayoutConstraint.activate([
            pingButton.heightAnchor.constraint(equalToConstant: 46),
            pingRow.centerXAnchor.constraint(equalTo: pingButton.centerXAnchor), pingRow.centerYAnchor.constraint(equalTo: pingButton.centerYAnchor),
            pingSpinner.trailingAnchor.constraint(equalTo: pingButton.trailingAnchor, constant: -14), pingSpinner.centerYAnchor.constraint(equalTo: pingButton.centerYAnchor),
        ])
        pingButton.onTap = { [weak self] in
            Haptics.tap()
            if App.shared.latency.progress.value.running { App.shared.latency.cancel() } else if let subscription = self?.subscription { App.shared.ping([subscription]) }
        }
        search.attributedPlaceholder = NSAttributedString(string: "Страна или город", attributes: [.foregroundColor: Theme.text.withAlphaComponent(0.7)])
        search.font = Theme.fixed(13, .medium)
        search.autocapitalizationType = .none
        search.autocorrectionType = .no
        search.leftView = { () -> UIView in
            let glass = UIImageView(image: UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
            glass.tintColor = Theme.accent
            glass.contentMode = .center
            glass.frame = CGRect(x: 0, y: 0, width: 34, height: 44)
            return glass
        }()
        search.leftViewMode = .always
        search.layer.borderWidth = 1
        search.layer.borderColor = Theme.line.cgColor
        search.clearButtonMode = .whileEditing
        search.returnKeyType = .done
        search.addAction(UIAction { [weak self] _ in self?.reload() }, for: .editingChanged)
        search.addAction(UIAction { [weak self] _ in self?.search.resignFirstResponder() }, for: .editingDidEndOnExit)
        search.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let filterScroll = UIScrollView()
        filterScroll.showsHorizontalScrollIndicator = false
        filterScroll.addSubview(filters)
        filters.pin(to: filterScroll, insets: UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20))
        filters.heightAnchor.constraint(equalTo: filterScroll.heightAnchor).isActive = true
        filterScroll.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let groupHeader = UIStackView(.horizontal, spacing: 8, alignment: .center, [
            UIStackView(.vertical, spacing: 2, alignment: .leading, [groupKicker, groupTitle, groupProgress]), UIView(),
            UIStackView(.vertical, spacing: 2, alignment: .trailing, [groupCount, Classic.micro("ЛОКАЦИЙ")]),
        ])
        let groupBox = UIStackView(.vertical, spacing: 0, alignment: .fill, [Classic.padded(groupHeader, UIEdgeInsets(top: 11, left: 20, bottom: 11, right: 20)), Classic.rule()])
        groupBox.backgroundColor = Theme.text.withAlphaComponent(0.045)
        let header = UIStackView(.vertical, spacing: 0, alignment: .fill, [Classic.padded(title, UIEdgeInsets(top: 28, left: 20, bottom: 14, right: 20)), Classic.rule()])
        let controls = UIStackView(.vertical, spacing: 10, alignment: .fill, [pingButton, search])
        controls.isLayoutMarginsRelativeArrangement = true
        controls.layoutMargins = UIEdgeInsets(top: 14, left: 20, bottom: 0, right: 20)
        filters.spacing = 0
        let filterBox = Classic.padded(filterScroll, UIEdgeInsets(top: 5, left: 0, bottom: 0, right: 0))
        let top = UIStackView(.vertical, spacing: 0, alignment: .fill, [header, controls, filterBox])
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 61
        table.separatorInset = .zero
        table.keyboardDismissMode = .onDrag
        let stack = UIStackView(.vertical, spacing: 0, alignment: .fill, [top, groupBox, table])
        view.addSubview(stack)
        stack.pin(to: view)

        let app = App.shared
        app.store.library.observe(self) { [weak self] _ in self?.reload() }
        app.latency.progress.observe(self) { [weak self] in self?.show($0) }
        app.latency.changed.observe(self, fireNow: false) { [weak self] _ in self?.reload() }
        Prefs.appearanceChanged.observe(self) { [weak self] in self?.view.backgroundColor = Theme.background; self?.reload() }
    }

    private func show(_ progress: LatencyProgress) {
        pingLabel.text = progress.running ? "СТОП" : "ПИНГ"
        pingIcon.image = UIImage(systemName: progress.running ? "stop.fill" : "antenna.radiowaves.left.and.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        if progress.running { pingSpinner.startAnimating() } else { pingSpinner.stopAnimating() }
        groupProgress.text = progress.total > 0 ? "ПРОВЕРЕНО \(progress.done) ИЗ \(progress.total)" : ""
    }

    private func reload() {
        let library = App.shared.library
        subscription = library.activeSubscription
        guard let subscription else {
            rows = []
            table.reloadData()
            return
        }
        labels = App.shared.store.labels(for: subscription)
        let favorites = Prefs.favorites
        let recent = Prefs.arrangement.recent
        let limited = subscription.info.isLimited
        let all = Prefs.arrangement.sorted(subscription.nodes, key: { Arrangement.server(subscription.id, $0.id) }, name: { self.labels[$0.id]?.text ?? $0.name })
        let favoriteNodes = all.filter { favorites.contains($0.id) }
        let recentNodes = recent.compactMap { key in all.first { Arrangement.server(subscription.id, $0.id) == key } }
        let sets: [(String, [ServerNode], String)] = [
            ("Все", all, "Доступные серверы"), ("Безлимитные", limited ? [] : all, "Безлимитные"), ("Лимитные", limited ? all : [], "Лимитные"),
            ("Избранное", favoriteNodes, "Избранное"), ("Недавние", recentNodes, "Недавние"),
        ]
        filters.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (offset, set) in sets.enumerated() {
            let active = offset == filter
            var views: [UIView] = [Classic.text(set.0, 10, active ? .semibold : .medium)]
            // 1.5.0 counted the unlimited, limited and favourite servers only.
            if (1 ... 3).contains(offset) { views.append(Classic.micro(String(format: "%02d", set.1.count), active ? Theme.accent : .secondaryLabel)) }
            let label = UIStackView(.horizontal, spacing: 5, alignment: .center, views)
            let line = UIView()
            line.backgroundColor = active ? Theme.text : Theme.line.withAlphaComponent(0.55)
            let item = UIView()
            for view in [label, line] {
                view.translatesAutoresizingMaskIntoConstraints = false
                item.addSubview(view)
            }
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: item.leadingAnchor, constant: 12), label.trailingAnchor.constraint(equalTo: item.trailingAnchor, constant: -12),
                label.centerYAnchor.constraint(equalTo: item.centerYAnchor),
                line.bottomAnchor.constraint(equalTo: item.bottomAnchor), line.heightAnchor.constraint(equalToConstant: active ? 2 : 1),
                line.leadingAnchor.constraint(equalTo: item.leadingAnchor, constant: active ? 8 : 0), line.trailingAnchor.constraint(equalTo: item.trailingAnchor, constant: active ? -8 : 0),
            ])
            filters.addArrangedSubview(ClassicRow(item) { [weak self] in
                self?.filter = offset
                Haptics.selection()
                self?.reload()
            })
        }
        let needle = (search.text ?? "").lowercased()
        rows = sets[filter].1.filter { needle.isEmpty || (labels[$0.id]?.text ?? $0.name).lowercased().contains(needle) || $0.name.lowercased().contains(needle) }
        heading.text = "ЛОКАЦИИ / \(subscription.nodes.count)"
        groupKicker.text = "02 / " + subscription.name.uppercased()
        groupKicker.textColor = Theme.accent
        groupTitle.text = sets[filter].2
        groupCount.text = String(format: "%02d", rows.count)
        table.reloadData()
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { rows.count }

    func tableView(_: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        guard let subscription else { return cell }
        let node = rows[indexPath.row]
        let selected = App.shared.library.selectedNodeID(in: subscription) == node.id
        cell.selectionStyle = .none
        let entry = App.shared.latency.entry(subscription.id, node.id)
        let failed: Bool
        if case .failed? = entry?.result { failed = true } else { failed = false }
        // 1.5.0 `DirectServerRow`: number, flag, name, protocols, limit, ping dot, star, mark.
        let high = (entry?.result.milliseconds ?? 0) > 100 || failed
        let dot = UIView()
        dot.backgroundColor = high ? Theme.danger : Theme.accent
        dot.layer.cornerRadius = 2.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 5), dot.heightAnchor.constraint(equalToConstant: 5)])
        let ping = UIStackView(.horizontal, spacing: 4, alignment: .center, [
            dot, Classic.micro(Classic.ping(entry, testing: App.shared.latency.isTesting(subscription.id, node.id)), high ? Theme.danger : Theme.text),
        ])
        ping.setContentHuggingPriority(.required, for: .horizontal)
        ping.setContentCompressionResistancePriority(.required, for: .horizontal)
        let favorite = Prefs.favorites.contains(node.id)
        let star = UIButton(type: .system)
        star.setImage(UIImage(systemName: favorite ? "star.fill" : "star", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)), for: .normal)
        star.tintColor = favorite ? Theme.accent : .secondaryLabel
        let tag = node.id
        star.addAction(UIAction { [weak self] _ in
            var next = Prefs.favorites
            if next.contains(tag) { next.remove(tag) } else { next.insert(tag) }
            Prefs.favorites = next
            Haptics.tap()
            self?.reload()
        }, for: .touchUpInside)
        NSLayoutConstraint.activate([star.widthAnchor.constraint(equalToConstant: 34), star.heightAnchor.constraint(equalToConstant: 34)])
        let mark = UIImageView(image: UIImage(systemName: selected ? "checkmark" : "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)))
        mark.tintColor = selected ? Theme.accent : .secondaryLabel
        mark.contentMode = .center
        mark.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let name = UILabel(labels[node.id]?.text ?? node.name, font: Classic.rounded(13, .semibold))
        name.adjustsFontSizeToFitWidth = true
        name.minimumScaleFactor = 0.7
        let text = UIStackView(.vertical, spacing: 3, alignment: .leading, [
            name, Classic.text(node.facts.summary, 10, .regular, .secondaryLabel),
            Classic.micro((subscription.info.isLimited ? "Лимитный" : "Безлимитный").uppercased(), selected ? Theme.accent : .secondaryLabel),
        ])
        let number = Classic.micro(String(format: "%02d", indexPath.row + 1), selected ? Theme.accent : .secondaryLabel)
        number.widthAnchor.constraint(equalToConstant: 21).isActive = true
        let main = UIStackView(.horizontal, spacing: 10, alignment: .center, [number, Classic.flag(labels[node.id]?.countryCode, width: 31, height: 21), text, UIView(), ping])
        main.heightAnchor.constraint(greaterThanOrEqualToConstant: 61).isActive = true
        let row = UIStackView(.horizontal, spacing: 0, alignment: .center, [main, star, mark])
        cell.contentView.addSubview(row)
        row.pin(to: cell.contentView, insets: UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20))
        cell.backgroundColor = selected ? Theme.accent.withAlphaComponent(0.10) : .clear
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let subscription else { return }
        App.shared.select(node: rows[indexPath.row].id, in: subscription.id)
    }
}

/// 03 Управление.
final class ClassicManageViewController: ClassicPage {
    private var expanded: Set<Int64> = []
    private var query = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        App.shared.store.library.observe(self, fireNow: false) { [weak self] _ in self?.rebuild() }
        App.shared.refreshing.observe(self, fireNow: false) { [weak self] _ in self?.rebuild() }
    }

    override func build() {
        content.spacing = 22
        content.addArrangedSubview(ClassicRow(Classic.body("Добавить сервер или подписку", 17)) { [weak self] in
            if let self { AddServerFlow.present(from: self) }
        })
        let field = UITextField()
        field.placeholder = "Поиск подписок"
        field.font = Theme.font(17)
        field.text = query
        field.returnKeyType = .done
        field.addAction(UIAction { [weak self, weak field] _ in
            self?.query = field?.text ?? ""
            field?.resignFirstResponder()
            self?.rebuild()
        }, for: .editingDidEndOnExit)
        content.addArrangedSubview(field)
        let toggle = UISwitch()
        toggle.isOn = Prefs.arrangement.byName
        toggle.onTintColor = Theme.accent
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            var next = Prefs.arrangement
            next.byName = toggle?.isOn ?? false
            Prefs.arrangement = next
            self?.rebuild()
        }, for: .valueChanged)
        content.addArrangedSubview(UIStackView(.horizontal, spacing: 8, alignment: .center, [Classic.body("Сортировать по имени", 17), UIView(), toggle]))

        let frame = ClassicFrame(caption: "ДОСТУПНЫЕ")
        let library = App.shared.library
        let needle = query.lowercased()
        let subscriptions = Prefs.arrangement.sorted(library.subscriptions.filter { !$0.nodes.isEmpty }, key: { Arrangement.subscription($0.id) }, name: { $0.name })
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
        if subscriptions.isEmpty {
            frame.add(Classic.body("Подписок нет. Добавьте сервер или подписку.", 14, .regular, .secondaryLabel, lines: 0), insets: UIEdgeInsets(top: 18, left: 18, bottom: 18, right: 18))
        }
        for subscription in subscriptions {
            let id = subscription.id
            let open = expanded.contains(id)
            let chevron = UIImageView(image: UIImage(systemName: open ? "chevron.up" : "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)))
            chevron.tintColor = .secondaryLabel
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            let name = Classic.body(subscription.name, 17)
            name.lineBreakMode = .byTruncatingTail
            let head = ClassicRow(UIStackView(.horizontal, spacing: 10, alignment: .center, [name, chevron, UIView()])) { [weak self] in
                guard let self else { return }
                if self.expanded.contains(id) { self.expanded.remove(id) } else { self.expanded.insert(id) }
                Haptics.soft(0.5)
                self.rebuild()
            }
            let more = UIButton(type: .system)
            more.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)), for: .normal)
            more.tintColor = .label
            more.showsMenuAsPrimaryAction = true
            var actions: [UIMenuElement] = [UIAction(title: subscription.name, attributes: .disabled) { _ in }]
            if subscription.isRemote {
                actions.append(UIAction(title: "Обновить", image: UIImage(systemName: "arrow.clockwise")) { _ in App.shared.refresh(id) })
                actions.append(UIAction(title: "Скопировать ссылку", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = subscription.url })
            }
            actions.append(UIAction(title: "Проверить пинг", image: UIImage(systemName: "waveform.path.ecg")) { _ in App.shared.ping([subscription]) })
            actions.append(UIAction(title: "На главный экран", image: UIImage(systemName: "house")) { _ in
                if let node = App.shared.library.selectedNodeID(in: subscription) { App.shared.select(node: node, in: id) }
            })
            actions.append(UIAction(title: "Удалить", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                let alert = UIAlertController(title: nil, message: "Удалить «\(subscription.name)»?", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
                alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { _ in App.shared.delete(subscription: id) })
                self?.present(alert, animated: true)
            })
            more.menu = UIMenu(children: actions)
            more.widthAnchor.constraint(equalToConstant: 44).isActive = true
            frame.add(UIStackView(.horizontal, spacing: 8, alignment: .center, [head, more]), insets: UIEdgeInsets(top: 22, left: 18, bottom: 22, right: 8))
            guard open else { continue }
            let labels = App.shared.store.labels(for: subscription)
            var lines: [UIView] = [Classic.body(Format.plural(subscription.nodes.count, "сервер", "сервера", "серверов") + " · обновлена " + Format.ago(subscription.updatedAt), 13, .regular, .secondaryLabel)]
            if library.activeSubscription?.id == id { lines.append(Classic.body("На главном экране", 13, .regular, Theme.accent)) }
            for node in subscription.nodes {
                lines.append(UIStackView(.vertical, spacing: 3, alignment: .leading, [
                    Classic.body(labels[node.id]?.text ?? node.name, 13), Classic.body(node.facts.summary, 12, .regular, .secondaryLabel),
                ]))
            }
            let list = UIStackView(.vertical, spacing: 10, alignment: .leading, lines)
            list.setCustomSpacing(2, after: lines[0])
            frame.add(list, insets: UIEdgeInsets(top: 0, left: 18, bottom: 18, right: 18))
        }
        content.addArrangedSubview(frame)
    }
}

/// 04 Настройки.
final class ClassicSettingsViewController: ClassicPage {
    private func option(_ title: String, selected: Bool, boxed: Bool = true, action: @escaping () -> Void) -> UIView {
        let mark = UIImageView(image: UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)))
        mark.tintColor = boxed ? Theme.accent : .label
        mark.isHidden = !selected
        mark.setContentHuggingPriority(.required, for: .horizontal)
        let views: [UIView] = boxed ? [Classic.body(title, 16), UIView(), mark] : [Classic.body(title, 16), mark, UIView()]
        let row = ClassicRow(UIStackView(.horizontal, spacing: 6, alignment: .center, views), insets: boxed ? UIEdgeInsets(top: 13, left: 12, bottom: 13, right: 14) : UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)) {
            Haptics.selection()
            action()
        }
        if boxed {
            row.layer.borderWidth = 1
            row.layer.borderColor = Theme.line.cgColor
        }
        return row
    }

    private func toggle(_ title: String, _ get: Bool, _ set: @escaping (Bool) -> Void) -> UIView {
        let control = UISwitch()
        control.isOn = get
        control.onTintColor = Theme.accent
        control.addAction(UIAction { [weak control] _ in set(control?.isOn ?? false) }, for: .valueChanged)
        return UIStackView(.horizontal, spacing: 8, alignment: .center, [Classic.body(title, 16, .regular, Theme.text, lines: 0), UIView(), control])
    }

    private func link(_ title: String, _ make: @escaping () -> UIViewController) -> UIView {
        let chevron = UIImageView(image: UIImage(systemName: "arrow.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)))
        chevron.tintColor = .secondaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        return ClassicRow(UIStackView(.horizontal, spacing: 8, alignment: .center, [Classic.body(title, 16), UIView(), chevron]), insets: UIEdgeInsets(top: 13, left: 0, bottom: 13, right: 0)) { [weak self] in
            let root = make()
            if !(root is ServerOrderViewController) {
                root.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak root] _ in root?.dismiss(animated: true) })
            }
            let navigation = UINavigationController(rootViewController: root)
            navigation.overrideUserInterfaceStyle = Theme.userInterfaceStyle
            self?.present(navigation, animated: true)
        }
    }

    private func section(_ caption: String, _ views: [UIView], spacing: CGFloat = 10) -> ClassicFrame {
        let frame = ClassicFrame(caption: caption)
        frame.add(UIStackView(.vertical, spacing: spacing, alignment: .fill, views), insets: UIEdgeInsets(top: 14, left: 18, bottom: 18, right: 18))
        return frame
    }

    override func build() {
        let changed = { App.shared.networkSettingsChanged() }
        content.addArrangedSubview(section("ВНЕШНИЙ ВИД", [
            Classic.body("Интерфейс", 12, .regular, .secondaryLabel),
            option("Классика", selected: true, boxed: false) {},
            option("Минималистичный", selected: false, boxed: false) { Prefs.style = .minimal },
            Classic.body("Тема", 12, .regular, .secondaryLabel),
            option("Системная", selected: Prefs.theme == "system") { Prefs.theme = "system" },
            option("Светлая", selected: Prefs.theme == "light") { Prefs.theme = "light" },
            option("Тёмная", selected: Prefs.theme == "dark") { Prefs.theme = "dark" },
            link("Цвета и шрифт") { ColorsViewController() },
        ]))
        content.addArrangedSubview(section("ЯЗЫК", [option("Русский", selected: true) {}]))
        content.addArrangedSubview(section("ИЗМЕРЕНИЕ ЗАДЕРЖКИ", [
            option("Основной", selected: Prefs.pingMode == "primary") { [weak self] in Prefs.pingMode = "primary"; self?.rebuild() },
            option("Классика", selected: Prefs.pingMode == "classic") { [weak self] in Prefs.pingMode = "classic"; self?.rebuild() },
            option("Альтернативный", selected: Prefs.pingMode == "alternative") { [weak self] in Prefs.pingMode = "alternative"; self?.rebuild() },
            Classic.body("Тест только показывает задержку и не меняет выбранный сервер. Его можно остановить в любой момент.", 12, .regular, .secondaryLabel, lines: 0),
        ]))
        content.addArrangedSubview(section("ПОДКЛЮЧЕНИЕ", [
            toggle("Автоподключение", Prefs.autoConnect) { Prefs.autoConnect = $0; App.shared.tunnel.applySettings() },
            toggle("Неизвестные Wi-Fi", Prefs.unknownWiFi) { Prefs.unknownWiFi = $0; App.shared.tunnel.applySettings() },
            toggle("Автоматический failover", Prefs.autoFailover) { Prefs.autoFailover = $0 },
        ], spacing: 14))
        content.addArrangedSubview(section("МАРШРУТИЗАЦИЯ", [
            toggle("Блокировка рекламы", Prefs.adBlocking) { Prefs.adBlocking = $0; changed() },
            toggle("Обход российских сайтов", Prefs.bypassRussia) { Prefs.bypassRussia = $0; changed() },
            toggle("Защищённый DNS", Prefs.secureDNS) { Prefs.secureDNS = $0; App.shared.tunnel.applySettings() },
            toggle("Локальная сеть", Prefs.localNetwork) { Prefs.localNetwork = $0; changed() },
            Classic.body("Серверы DNS берутся из конфигурации. После изменения системных маршрутов переподключите VPN.", 12, .regular, .secondaryLabel, lines: 0),
        ], spacing: 14))
        content.addArrangedSubview(section("БЕЗОПАСНОСТЬ", [toggle("Блокировка приложения", Prefs.appLock) { Prefs.appLock = $0 }]))
        content.addArrangedSubview(section("ДАННЫЕ", [
            link("Порядок серверов") { ServerOrderViewController() },
            link("Проверка соединения") { DiagnosticsViewController() },
            link("Журнал службы") { ServiceLogViewController() },
            link("Резервные копии") { BackupViewController() },
            link("Сетевая активность приложения") { NetworkActivityViewController() },
            link("О приложении") { AboutViewController() },
        ], spacing: 0))
    }
}
