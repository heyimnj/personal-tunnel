import TunnelCore
import UIKit
import UniformTypeIdentifiers

/// «Проверка соединения»: measured facts, not the state of the switch.
final class DiagnosticsViewController: UIViewController {
    private let scroll = UIScrollView()
    private let tunnel = UILabel(font: Theme.font(20, .semibold))
    private let proxy = UILabel(font: Theme.font(20, .semibold), lines: 0)
    private let proxyDetail = UILabel(font: Theme.font(14), color: .secondaryLabel, lines: 0)
    private let internet = UILabel(font: Theme.font(20, .semibold), lines: 0)
    private let internetDetail = UILabel(font: Theme.font(14), color: .secondaryLabel, lines: 0)
    private var proxyResult = "Не проверено"
    private var internetResult = "Не проверено"
    private var checking = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        navigationItem.largeTitleDisplayMode = .never
        view.addSubview(scroll)
        scroll.pin(to: view)
        func action(_ title: String, _ selector: Selector) -> UIButton {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = Theme.font(20)
            button.titleLabel?.numberOfLines = 0
            button.contentHorizontalAlignment = .leading
            button.tintColor = Theme.accent
            button.addTarget(self, action: selector, for: .touchUpInside)
            return button
        }
        func note(_ text: String) -> UILabel { UILabel(text, font: Theme.font(14), color: .secondaryLabel, lines: 0) }
        let stack = UIStackView(.vertical, spacing: 14, alignment: .fill, [
            UILabel("СИСТЕМА", font: Theme.font(11, .medium), color: .secondaryLabel),
            UILabel("Диагностика", font: Theme.font(26, .bold)),
            note("Результаты измерений, а не состояние переключателя"),
            tunnel, proxy, proxyDetail, internet, internetDetail,
            note("При раздельной маршрутизации успешный системный запрос не доказывает работу прокси. DNS-утечки этой проверкой не измеряются."),
            action("Проверить соединение", #selector(check)),
            note("Проверка обращается к www.gstatic.com/generate_204: через выбранный outbound и через системный маршрут; таймаут до 8 секунд."),
            action("Открыть журнал службы", #selector(openLog)),
            action("Скопировать отчёт", #selector(copyReport)),
            note("REALITY: проверьте SNI, ключ, short ID, время и ограничения версии Xray на сервере. Журнал показывает конкретную причину отказа."),
            note("TLS: сертификат, SNI и доступность маскировочного сайта. DNS: резолвер и маршрут к нему. Транспорт: соответствие TCP/WS/gRPC и пути серверу."),
        ])
        stack.setCustomSpacing(4, after: stack.arrangedSubviews[0])
        stack.setCustomSpacing(4, after: proxy)
        stack.setCustomSpacing(4, after: internet)
        scroll.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
        App.shared.tunnel.state.observe(self) { [weak self] _ in self?.show() }
    }

    private func show() {
        tunnel.text = App.shared.tunnel.state.value.isOn ? "Туннель запущен" : "Туннель остановлен"
        proxy.text = "Прокси: " + (proxyResult.hasPrefix("Не") ? proxyResult : "проверено")
        proxyDetail.text = proxyResult
        internet.text = "Интернет · системный маршрут: " + (internetResult.hasPrefix("Не") ? internetResult : "проверено")
        internetDetail.text = internetResult
    }

    @objc private func check() {
        guard !checking else { return }
        checking = true
        proxyResult = "Проверяется…"
        internetResult = "Проверяется…"
        show()
        Task { @MainActor in
            let probes = NetworkProbes()
            if App.shared.tunnel.state.value == .connected, let node = App.shared.library.activeNode {
                switch await LatencyRunner.deadline(seconds: 9, { await probes.url(tag: node.id, link: ConfigBuilder.probeURL, timeoutMs: 8000) }) {
                case let .delay(value): self.proxyResult = "Ответ за \(value) мс через «\(node.name)»"
                case let .failed(reason): self.proxyResult = "Не отвечает: \(reason.title)"
                }
            } else {
                self.proxyResult = "Не проверено: туннель не запущен"
            }
            var request = URLRequest(url: URL(string: ConfigBuilder.probeURL)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.httpMethod = "HEAD"
            let start = Date()
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                self.internetResult = "HTTP \(code) за \(Int(Date().timeIntervalSince(start) * 1000)) мс"
            } catch {
                self.internetResult = "Не отвечает: \(error.localizedDescription)"
            }
            self.checking = false
            self.show()
        }
    }

    @objc private func openLog() {
        navigationController?.pushViewController(ServiceLogViewController(), animated: true)
    }

    @objc private func copyReport() {
        let library = App.shared.library
        let report = [
            "Personal Tunnel \(AboutViewController.version)", tunnel.text ?? "", "Прокси: \(proxyResult)", "Интернет: \(internetResult)",
            "Протокол: \(library.activeNode?.facts.summary ?? "—")", "Режим пинга: \(Prefs.pingMode)",
        ].joined(separator: "\n")
        UIPasteboard.general.string = Redactor.redact(report)
        Haptics.result(true)
    }
}

/// «Журнал службы»: the core's log, streamed while the screen is open.
final class ServiceLogViewController: UIViewController, UITableViewDataSource, UISearchBarDelegate {
    private let table = UITableView(frame: .zero, style: .plain)
    private let live = UILabel("LIVE", font: Theme.font(13, .bold), color: .systemRed)
    private let state = UILabel("STREAMING", font: Theme.font(20, .semibold))
    private let search = UISearchBar()
    private var lines: [LogLine] = []
    private var query = ""
    private var minimumLevel: Int32 = 7
    private let pause = UIButton(type: .system)
    private static let levels = ["PANIC", "FATAL", "ERROR", "WARN", "INFO", "DEBUG", "TRACE"]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Журнал"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.background
        func tool(_ symbol: String, _ selector: Selector?) -> UIButton {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)), for: .normal)
            button.tintColor = .label
            if let selector { button.addTarget(self, action: selector, for: .touchUpInside) }
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            return button
        }
        let dot = UIView()
        dot.backgroundColor = .systemRed
        dot.layer.cornerRadius = 7
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 14), dot.heightAnchor.constraint(equalToConstant: 14)])
        pause.setImage(UIImage(systemName: "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)), for: .normal)
        pause.tintColor = .label
        pause.addTarget(self, action: #selector(togglePause), for: .touchUpInside)
        pause.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let filter = tool("line.3.horizontal.decrease", nil)
        filter.showsMenuAsPrimaryAction = true
        filter.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] done in
                let current = self?.minimumLevel ?? 7
                done([("Все", Int32(7)), ("INFO и важнее", 4), ("WARN и важнее", 3), ("Только ошибки", 2)].map { title, level in
                    UIAction(title: title, state: level == current ? .on : .off) { _ in
                        self?.minimumLevel = level
                        self?.refilter()
                    }
                } + [UIAction(title: "Очистить журнал", attributes: .destructive) { _ in App.shared.core.clearLogs() }])
            },
        ])
        let bar = UIStackView(.horizontal, spacing: 12, alignment: .center, [dot, live, UIView(), tool("magnifyingglass", #selector(toggleSearch)), pause, filter])
        let panel = UIView()
        panel.backgroundColor = FormViewController.cellColor
        panel.layer.cornerRadius = 28
        panel.layer.cornerCurve = .continuous
        panel.addSubview(bar)
        bar.pin(to: panel, insets: UIEdgeInsets(top: 14, left: 24, bottom: 14, right: 16))
        let caption = UIStackView(.horizontal, spacing: 8, alignment: .center, [UILabel("SERVICE.LOG", font: Theme.font(20, .semibold)), UIView(), state])
        search.searchBarStyle = .minimal
        search.placeholder = "Поиск"
        search.delegate = self
        search.isHidden = true
        table.dataSource = self
        table.backgroundColor = FormViewController.cellColor
        table.layer.cornerRadius = 28
        table.layer.cornerCurve = .continuous
        table.separatorInset = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 70
        table.allowsSelection = false
        let stack = UIStackView(.vertical, spacing: 16, alignment: .fill, [panel, search, caption, table])
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        stack.setCustomSpacing(8, after: caption)
        caption.isLayoutMarginsRelativeArrangement = true
        caption.layoutMargins = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        App.shared.core.logsChanged.observe(self) { [weak self] in self?.refilter() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        App.shared.core.setDetails(true)
        refilter()
    }

    private func refilter() {
        let needle = query.lowercased()
        lines = App.shared.core.logs.filter { $0.level <= minimumLevel && (needle.isEmpty || $0.text.lowercased().contains(needle)) }
        let atBottom = table.contentOffset.y >= table.contentSize.height - table.bounds.height - 80
        table.reloadData()
        if atBottom, !lines.isEmpty { table.scrollToRow(at: IndexPath(row: lines.count - 1, section: 0), at: .bottom, animated: false) }
        let running = App.shared.tunnel.state.value.isOn
        state.text = !running ? "STOPPED" : (App.shared.core.logsPaused ? "PAUSED" : "STREAMING")
        live.text = running && !App.shared.core.logsPaused ? "LIVE" : "PAUSE"
    }

    @objc private func togglePause() {
        App.shared.core.logsPaused.toggle()
        pause.setImage(UIImage(systemName: App.shared.core.logsPaused ? "play.fill" : "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)), for: .normal)
        refilter()
    }

    @objc private func toggleSearch() {
        search.isHidden.toggle()
        if search.isHidden { search.resignFirstResponder(); query = ""; search.text = nil; refilter() } else { search.becomeFirstResponder() }
    }

    func searchBar(_: UISearchBar, textDidChange text: String) {
        query = text
        refilter()
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { lines.count }

    func tableView(_: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = .clear
        let line = lines[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = ServiceLogViewController.levels.indices.contains(Int(line.level)) ? ServiceLogViewController.levels[Int(line.level)] : "LOG"
        content.textProperties.font = Theme.font(12, .semibold)
        content.textProperties.color = line.level <= 2 ? .systemRed : .secondaryLabel
        content.secondaryText = line.text
        content.secondaryTextProperties.font = Theme.mono(13)
        content.secondaryTextProperties.color = .label
        content.textToSecondaryTextVerticalPadding = 6
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        cell.contentConfiguration = content
        return cell
    }
}

/// «Порядок серверов»: pins and manual order by dragging.
final class ServerOrderViewController: UITableViewController {
    private var subscriptions: [Subscription] = []

    init() {
        super.init(style: .plain)
        title = "Порядок серверов"
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .always
        tableView.backgroundColor = Theme.background
        tableView.isEditing = true
        tableView.allowsSelectionDuringEditing = true
        view.tintColor = Theme.accent
        let toggle = UISwitch()
        toggle.isOn = Prefs.arrangement.byName
        toggle.onTintColor = Theme.accent
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            var next = Prefs.arrangement
            next.byName = toggle?.isOn ?? false
            Prefs.arrangement = next
            self?.reload()
        }, for: .valueChanged)
        let row = UIStackView(.horizontal, spacing: 8, alignment: .center, [UILabel("Сортировать по имени", font: Theme.font(17)), UIView(), toggle])
        let note = UILabel("Закреплённые серверы остаются сверху. Ручной порядок сохраняется при выборе сервера. Перетаскивание включает ручной порядок.", font: Theme.font(13), color: .secondaryLabel, lines: 0)
        let header = UIStackView(.vertical, spacing: 12, alignment: .fill, [row, note])
        header.isLayoutMarginsRelativeArrangement = true
        header.layoutMargins = UIEdgeInsets(top: 8, left: 16, bottom: 12, right: 16)
        header.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 130)
        tableView.tableHeaderView = header
        if navigationController?.viewControllers.first === self, presentingViewController != nil {
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        }
        reload()
    }

    @objc private func close() { dismiss(animated: true) }

    private func reload() {
        subscriptions = Prefs.arrangement.sorted(App.shared.library.subscriptions.filter { !$0.nodes.isEmpty }, key: { Arrangement.subscription($0.id) }, name: { $0.name })
        tableView.reloadData()
    }

    private func nodes(_ subscription: Subscription) -> [ServerNode] {
        let labels = App.shared.store.labels(for: subscription)
        return Prefs.arrangement.sorted(subscription.nodes, key: { Arrangement.server(subscription.id, $0.id) }, name: { labels[$0.id]?.text ?? $0.name })
    }

    /// Section 0 lists subscriptions; then one section per multi-server subscription.
    private var groups: [Subscription] { subscriptions.filter { !$0.isStandalone } }

    override func numberOfSections(in _: UITableView) -> Int { 1 + groups.count }
    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? subscriptions.count : groups[section - 1].nodes.count }
    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "Подписки" : groups[section - 1].name }

    private func key(_ path: IndexPath) -> (key: String, title: String) {
        if path.section == 0 {
            let subscription = subscriptions[path.row]
            return (Arrangement.subscription(subscription.id), subscription.name)
        }
        let subscription = groups[path.section - 1]
        let node = nodes(subscription)[path.row]
        return (Arrangement.server(subscription.id, node.id), App.shared.store.label(of: node, in: subscription).text)
    }

    override func tableView(_: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = .clear
        let item = key(indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = item.title
        content.textProperties.font = Theme.font(17)
        cell.contentConfiguration = content
        let pinned = Prefs.arrangement.isPinned(item.key)
        let pin = UIButton(type: .system)
        pin.setImage(UIImage(systemName: pinned ? "pin.fill" : "pin"), for: .normal)
        pin.tintColor = Theme.accent
        pin.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        pin.addAction(UIAction { [weak self] _ in
            var next = Prefs.arrangement
            next.togglePin(item.key)
            Prefs.arrangement = next
            self?.reload()
        }, for: .touchUpInside)
        cell.editingAccessoryView = pin
        cell.showsReorderControl = true
        return cell
    }

    override func tableView(_: UITableView, editingStyleForRowAt _: IndexPath) -> UITableViewCell.EditingStyle { .none }
    override func tableView(_: UITableView, shouldIndentWhileEditingRowAt _: IndexPath) -> Bool { false }
    override func tableView(_: UITableView, canMoveRowAt _: IndexPath) -> Bool { true }

    override func tableView(_: UITableView, targetIndexPathForMoveFromRowAt source: IndexPath, toProposedIndexPath proposed: IndexPath) -> IndexPath {
        proposed.section == source.section ? proposed : source
    }

    override func tableView(_: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        var keys: [String]
        if source.section == 0 {
            keys = subscriptions.map { Arrangement.subscription($0.id) }
        } else {
            let subscription = groups[source.section - 1]
            keys = nodes(subscription).map { Arrangement.server(subscription.id, $0.id) }
        }
        let old = keys
        let moved = keys.remove(at: source.row)
        keys.insert(moved, at: destination.row)
        var next = Prefs.arrangement
        next.setManualOrder(keys, replacing: old)
        Prefs.arrangement = next
        (tableView.tableHeaderView as? UIStackView)?.arrangedSubviews.first?.subviews.compactMap { $0 as? UISwitch }.first?.isOn = false
        reload()
    }
}

/// Adds servers from the clipboard, typed text or a file.
enum AddServerFlow {
    private static let picker = FilePicker()

    static func present(from host: UIViewController) {
        let sheet = UIAlertController(title: "Добавить сервер или подписку", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Вставить из буфера обмена", style: .default) { _ in
            guard let text = UIPasteboard.general.string, !text.isEmpty else {
                App.shared.notice.value = "Буфер обмена пуст."
                return
            }
            add(text, from: host)
        })
        sheet.addAction(UIAlertAction(title: "Ввести ссылку или адрес подписки", style: .default) { _ in
            let alert = UIAlertController(title: "Ссылка", message: "Адрес подписки (https://…) или ссылка сервера (vless://, ss://, hysteria2://…)", preferredStyle: .alert)
            alert.addTextField { $0.placeholder = "https://"; $0.autocapitalizationType = .none; $0.autocorrectionType = .no; $0.keyboardType = .URL }
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            alert.addAction(UIAlertAction(title: "Добавить", style: .default) { _ in add(alert.textFields?.first?.text ?? "", from: host) })
            host.present(alert, animated: true)
        })
        sheet.addAction(UIAlertAction(title: "Выбрать файл", style: .default) { _ in
            picker.pick(from: host) { text in add(text, from: host) }
        })
        sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        sheet.popoverPresentationController?.sourceView = host.view
        host.present(sheet, animated: true)
    }

    private static func add(_ text: String, from host: UIViewController) {
        let progress = UIAlertController(title: nil, message: "Добавление…", preferredStyle: .alert)
        host.present(progress, animated: true)
        App.shared.add(text: text) { message in
            progress.dismiss(animated: true) {
                Haptics.result(message == nil)
                if let message { App.shared.notice.value = message }
            }
        }
    }
}

final class FilePicker: NSObject, UIDocumentPickerDelegate {
    private var done: ((String) -> Void)?

    func pick(from host: UIViewController, done: @escaping (String) -> Void) {
        self.done = done
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .text, .data], asCopy: true)
        picker.delegate = self
        host.present(picker, animated: true)
    }

    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let data = try? Data(contentsOf: url) else { return }
        done?(String(decoding: data, as: UTF8.self))
    }
}

/// «Управление подписками».
final class SubscriptionsViewController: FormViewController {
    init() { super.init(title: "Управление подписками") }

    override func viewDidLoad() {
        super.viewDidLoad()
        App.shared.store.library.observe(self, fireNow: false) { [weak self] _ in self?.rebuild() }
    }

    override func build() -> [FormSection] {
        var sections = [FormSection([
            .button(title: "Добавить сервер или подписку", destructive: false) { [weak self] in
                if let self { AddServerFlow.present(from: self) }
            },
            .button(title: "Обновить подписки", destructive: false) { App.shared.refreshAll() },
        ])]
        for subscription in App.shared.library.subscriptions {
            var rows: [FormRow] = [
                .value(title: Format.plural(subscription.nodes.count, "сервер", "сервера", "серверов"), detail: { "обновлена " + Format.ago(subscription.updatedAt) }),
            ]
            if let expires = subscription.info.expiresAt {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "ru_RU")
                formatter.dateStyle = .medium
                rows.append(.value(title: "Действует до", detail: { formatter.string(from: expires) }))
            }
            if let used = subscription.info.usedBytes {
                rows.append(.value(title: "Трафик", detail: {
                    Format.bytes(used) + (subscription.info.isLimited ? " из " + Format.bytes(subscription.info.totalBytes ?? 0) : " · без лимита")
                }))
            }
            let id = subscription.id
            if subscription.isRemote {
                rows.append(.toggle(title: "Отправлять HWID", get: { App.shared.library.subscription(id)?.sendsDeviceIdentity ?? true }, set: { value in
                    App.shared.store.update { library in
                        guard var current = library.subscription(id) else { return }
                        current.sendsDeviceIdentity = value
                        library.replace(current)
                    }
                }))
                rows.append(.button(title: "Обновить", destructive: false) { App.shared.refresh(id) })
            }
            rows.append(.button(title: "Удалить", destructive: true) { [weak self] in
                let alert = UIAlertController(title: nil, message: "Удалить «\(subscription.name)»?", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
                alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { _ in App.shared.delete(subscription: id) })
                self?.present(alert, animated: true)
            })
            sections.append(FormSection(subscription.name, footer: subscription.warnings.first, rows))
        }
        return sections
    }
}

/// «Резервные копии»: the whole library as one JSON file.
final class BackupViewController: FormViewController {
    private let picker = FilePicker()

    init() { super.init(title: "Резервные копии") }

    override func build() -> [FormSection] {
        [FormSection(footer: "Копия содержит адреса подписок и ключи серверов. Храните её как пароль.", [
            .button(title: "Сохранить копию в Файлы", destructive: false) { [weak self] in self?.export() },
            .button(title: "Восстановить из файла", destructive: false) { [weak self] in self?.restore() },
        ])]
    }

    private func export() {
        guard let data = try? JSONEncoder().encode(App.shared.library) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PersonalTunnel-\(formatter.string(from: Date())).ptbackup.json")
        try? data.write(to: url, options: .atomic)
        present(UIDocumentPickerViewController(forExporting: [url], asCopy: true), animated: true)
    }

    private func restore() {
        picker.pick(from: self) { text in
            if let library = try? JSONDecoder().decode(Library.self, from: Data(text.utf8)), !library.subscriptions.isEmpty {
                App.shared.store.update { $0 = library }
                App.shared.notice.value = "Восстановлено подписок: \(library.subscriptions.count)."
            } else {
                // Not a 2.0 backup: try it as servers or a configuration.
                App.shared.add(text: text) { message in App.shared.notice.value = message ?? "Серверы из файла добавлены." }
            }
        }
    }
}

final class NetworkActivityViewController: FormViewController {
    init() { super.init(title: "Сетевая активность") }

    override func build() -> [FormSection] {
        [FormSection(footer: "У приложения нет своего сервера. Само оно выходит в сеть только чтобы обновить подписки, проверить соединение по кнопке и измерить задержку серверов.", [
            .value(title: "Обновление подписок", detail: { "по запросу" }),
            .value(title: "Проверка соединения", detail: { "www.gstatic.com" }),
            .value(title: "Пинг серверов", detail: { "TCP к серверу / через VPN" }),
            .value(title: "HWID", detail: { String(DeviceIdentity.hwid.prefix(4)) + "…" + String(DeviceIdentity.hwid.suffix(4)) }),
        ])]
    }
}

final class AboutViewController: FormViewController {
    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "2.0") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }

    init() { super.init(title: "О приложении") }

    override func build() -> [FormSection] {
        [FormSection(footer: "Personal Tunnel — личный VPN-клиент на ядре sing-box (форк sing-box-lx). Лицензия GPL-3.0-or-later.", [
            .value(title: "Версия", detail: { AboutViewController.version }),
            .value(title: "Ядро", detail: { CoreInfo.version }),
            .value(title: "Коммит", detail: { (Bundle.main.object(forInfoDictionaryKey: "PersonalSourceCommit") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "—" }),
            .value(title: "Группа", detail: { AppGroup.identifier }),
        ])]
    }
}
