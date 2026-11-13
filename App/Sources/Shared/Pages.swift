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
    private let memory = UILabel(font: Theme.font(14), color: .secondaryLabel, lines: 0)
    private var proxyResult = L("Не проверено")
    private var internetResult = L("Не проверено")
    private var proxyPassed = false
    private var internetPassed = false
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
            UILabel(L("СИСТЕМА"), font: Theme.font(11, .medium), color: .secondaryLabel),
            UILabel(L("Диагностика"), font: Theme.font(26, .bold)),
            note(L("Результаты измерений, а не состояние переключателя")),
            tunnel, proxy, proxyDetail, internet, internetDetail, memory,
            note(L("При раздельной маршрутизации успешный системный запрос не доказывает работу прокси. DNS-утечки этой проверкой не измеряются.")),
            action(L("Проверить соединение"), #selector(check)),
            note(L("Проверка обращается к www.gstatic.com/generate_204: через выбранный outbound и через системный маршрут; таймаут до 8 секунд.")),
            action(L("Открыть журнал службы"), #selector(openLog)),
            action(L("Скопировать отчёт"), #selector(copyReport)),
            note(L("REALITY: проверьте SNI, ключ, short ID, время и ограничения версии Xray на сервере. Журнал показывает конкретную причину отказа.")),
            note(L("TLS: сертификат, SNI и доступность маскировочного сайта. DNS: резолвер и маршрут к нему. Транспорт: соответствие TCP/WS/gRPC и пути серверу.")),
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
        tunnel.text = App.shared.tunnel.state.value.isOn ? L("Туннель запущен") : L("Туннель остановлен")
        proxy.text = L("Прокси: ") + (proxyPassed ? L("проверено") : proxyResult)
        proxyDetail.text = proxyResult
        internet.text = L("Интернет · системный маршрут: ") + (internetPassed ? L("проверено") : internetResult)
        internetDetail.text = internetResult
        // The extension's last memory sample: kept in the group even when the log is not.
        if let sample = MemorySample.decode(AppGroup.defaults.data(forKey: SharedKey.tunnelMemory)) {
            let time = DateFormatter.localizedString(from: sample.date, dateStyle: .short, timeStyle: .medium)
            memory.text = Lf("Память расширения (%@): %@", time, sample.line)
        } else {
            memory.text = L("Память расширения: ещё не измерялась")
        }
    }

    @objc private func check() {
        guard !checking else { return }
        checking = true
        proxyResult = L("Проверяется…")
        internetResult = L("Проверяется…")
        proxyPassed = false
        internetPassed = false
        show()
        Task { @MainActor in
            let probes = NetworkProbes()
            if App.shared.tunnel.state.value == .connected, let node = App.shared.library.activeNode {
                switch await LatencyRunner.deadline(seconds: 9, { await probes.url(tag: node.id, link: ConfigBuilder.probeURL, timeoutMs: 8000) }) {
                case let .delay(value):
                    self.proxyResult = Lf("Ответ за %@ мс через «%@»", "\(value)", "\(node.name)")
                    self.proxyPassed = true
                case let .failed(reason): self.proxyResult = Lf("Не отвечает: %@", "\(reason.title)")
                }
            } else {
                self.proxyResult = L("Не проверено: туннель не запущен")
            }
            var request = URLRequest(url: URL(string: ConfigBuilder.probeURL)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.httpMethod = "HEAD"
            let start = Date()
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                self.internetResult = Lf("HTTP %@ за %@ мс", "\(code)", "\(Int(Date().timeIntervalSince(start) * 1000))")
                self.internetPassed = true
            } catch {
                self.internetResult = Lf("Не отвечает: %@", "\(error.localizedDescription)")
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
            "Personal Tunnel \(AboutViewController.version)", tunnel.text ?? "", Lf("Прокси: %@", "\(proxyResult)"), Lf("Интернет: %@", "\(internetResult)"),
            Lf("Протокол: %@", "\(library.activeNode?.facts.summary ?? "—")"), Lf("Режим пинга: %@", "\(Prefs.pingMode)"),
            L("Ядро туннеля") + ": " + CoreInfo.tunnelCore, memory.text ?? "",
        ].joined(separator: "\n")
        UIPasteboard.general.string = Redactor.redact(report)
        Haptics.result(true)
    }
}

/// «Журнал службы»: the core's log, streamed while the screen is open.
final class ServiceLogViewController: UIViewController, UITableViewDataSource, UISearchBarDelegate {
    private let table = UITableView(frame: .zero, style: .plain)
    private let live = UILabel("LIVE", font: Theme.font(12, .bold), color: .systemRed)
    private let state = UILabel("STREAMING", font: Theme.font(12, .semibold), color: .secondaryLabel)
    private let search = UISearchBar()
    private var lines: [LogLine] = []
    private var query = ""
    private var minimumLevel: Int32 = 7
    private let pause = UIButton(type: .system)
    private static let levels = ["PANIC", "FATAL", "ERROR", "WARN", "INFO", "DEBUG", "TRACE"]
    private static let toolSymbol = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("Журнал")
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.background
        // Compact, in the scale of the rest of the app: 16 pt tools in 38 pt targets.
        func tool(_ symbol: String, _ selector: Selector?) -> UIButton {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: symbol, withConfiguration: Self.toolSymbol), for: .normal)
            button.tintColor = .label
            if let selector { button.addTarget(self, action: selector, for: .touchUpInside) }
            button.widthAnchor.constraint(equalToConstant: 38).isActive = true
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
            return button
        }
        let dot = UIView()
        dot.backgroundColor = .systemRed
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])
        pause.setImage(UIImage(systemName: "pause.fill", withConfiguration: Self.toolSymbol), for: .normal)
        pause.tintColor = .label
        pause.addTarget(self, action: #selector(togglePause), for: .touchUpInside)
        pause.widthAnchor.constraint(equalToConstant: 38).isActive = true
        let filter = tool("line.3.horizontal.decrease", nil)
        filter.showsMenuAsPrimaryAction = true
        filter.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] done in
                let current = self?.minimumLevel ?? 7
                done([(L("Все"), Int32(7)), (L("INFO и важнее"), 4), (L("WARN и важнее"), 3), (L("Только ошибки"), 2)].map { title, level in
                    UIAction(title: title, state: level == current ? .on : .off) { _ in
                        self?.minimumLevel = level
                        self?.refilter()
                    }
                } + [
                    UIAction(title: L("Подробный журнал"), subtitle: L("Каждый пакет: нагружает туннель"), state: Prefs.verboseLog ? .on : .off) { _ in
                        Prefs.verboseLog.toggle()
                        App.shared.reloadTunnel()
                    },
                    UIAction(title: L("Очистить журнал"), attributes: .destructive) { _ in App.shared.core.clearLogs() },
                ])
            },
        ])
        let bar = UIStackView(.horizontal, spacing: 6, alignment: .center, [dot, live, UIView(), tool("doc.on.doc", #selector(copyAll)), tool("magnifyingglass", #selector(toggleSearch)), pause, filter])
        bar.setCustomSpacing(6, after: dot)
        let panel = UIView()
        panel.backgroundColor = FormViewController.cellColor
        panel.layer.cornerRadius = 20
        panel.layer.cornerCurve = .continuous
        panel.addSubview(bar)
        bar.pin(to: panel, insets: UIEdgeInsets(top: 6, left: 16, bottom: 6, right: 8))
        let caption = UIStackView(.horizontal, spacing: 8, alignment: .center, [UILabel("SERVICE.LOG", font: Theme.font(13, .semibold), color: .secondaryLabel), UIView(), state])
        search.searchBarStyle = .minimal
        search.placeholder = L("Поиск")
        search.delegate = self
        search.isHidden = true
        table.dataSource = self
        table.backgroundColor = FormViewController.cellColor
        table.layer.cornerRadius = 20
        table.layer.cornerCurve = .continuous
        table.separatorInset = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 44
        table.allowsSelection = false
        let stack = UIStackView(.vertical, spacing: 10, alignment: .fill, [panel, search, caption, table])
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            // Above the tab bar, so the card's rounded bottom is seen whole.
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        stack.setCustomSpacing(6, after: caption)
        caption.isLayoutMarginsRelativeArrangement = true
        caption.layoutMargins = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        App.shared.core.logsChanged.observe(self) { [weak self] in self?.refilter() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        App.shared.core.setLogStreamed(true)
        refilter()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        App.shared.core.setLogStreamed(false)
    }

    private func refilter() {
        let needle = query.lowercased()
        // Newest first: the screen opens on the latest lines and keeps them in view
        // while the reader stays at the top.
        lines = App.shared.core.logs.filter { $0.level <= minimumLevel && (needle.isEmpty || $0.text.lowercased().contains(needle)) }.reversed()
        let atTop = table.contentOffset.y <= -table.adjustedContentInset.top + 40
        table.reloadData()
        if atTop, !lines.isEmpty { table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false) }
        let running = App.shared.tunnel.state.value.isOn
        state.text = !running ? "STOPPED" : (App.shared.core.logsPaused ? "PAUSED" : "STREAMING")
        live.text = running && !App.shared.core.logsPaused ? "LIVE" : "PAUSE"
    }

    /// Every line of the log, and the extension's own short log (memory, starts,
    /// stops), which outlives the extension. Addresses and keys are removed.
    @objc private func copyAll() {
        let levels = ServiceLogViewController.levels
        var text = ["Personal Tunnel \(AboutViewController.version), " + L("ядро туннеля") + ": \(CoreInfo.tunnelCore)", ""]
        text += App.shared.core.logs.map { line in
            let level = levels.indices.contains(Int(line.level)) ? levels[Int(line.level)] : "LOG"
            return "\(level) \(line.text)"
        }
        if let paths = App.shared.paths {
            let events = TunnelEvents.read(TunnelEvents.file(paths))
            if !events.isEmpty { text += ["", L("Расширение:")] + events }
            let xray = ServiceLogViewController.tail(paths.xrayLog, lines: 80)
            if !xray.isEmpty { text += ["", "Xray-core:"] + xray }
            if let crash = ServiceLogViewController.lastCrash(paths) { text += ["", L("Последнее падение ядра:")] + crash }
        }
        UIPasteboard.general.string = Redactor.hideServers(Redactor.redact(text.joined(separator: "\n")), hosts: App.shared.library.serverHosts)
        Haptics.result(true)
        App.shared.notice.value = Lf("Скопировано строк: %@.", "\(App.shared.core.logs.count)")
    }

    static func tail(_ url: URL, lines: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).map(String.init))
    }

    /// What the core wrote before it last fell (a Go panic), within the last day:
    /// the live file of the running extension, or the newest archived report.
    static func lastCrash(_ paths: SharedPaths) -> [String]? {
        let manager = FileManager.default
        let dayAgo = Date().addingTimeInterval(-86_400)
        var candidates: [(URL, Date)] = []
        func add(_ url: URL) {
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, date > dayAgo,
                  let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 else { return }
            candidates.append((url, date))
        }
        add(paths.coreCrashLog)
        for folder in (try? manager.contentsOfDirectory(at: paths.crashReports, includingPropertiesForKeys: nil)) ?? [] {
            add(folder.appendingPathComponent("go.log"))
        }
        guard let newest = candidates.max(by: { $0.1 < $1.1 }) else { return nil }
        let formatter = ISO8601DateFormatter()
        guard let text = try? String(contentsOf: newest.0, encoding: .utf8) else { return nil }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // The reason (`panic: …`, `fatal error: …`) and the failing goroutine come first.
        let lines = all.count <= 120 ? all : Array(all.prefix(80)) + ["… (\(all.count - 120))"] + Array(all.suffix(40))
        return [formatter.string(from: newest.1)] + lines
    }

    @objc private func togglePause() {
        App.shared.core.logsPaused.toggle()
        pause.setImage(UIImage(systemName: App.shared.core.logsPaused ? "play.fill" : "pause.fill", withConfiguration: Self.toolSymbol), for: .normal)
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
        let cell = table.dequeueReusableCell(withIdentifier: "line") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "line")
        cell.backgroundColor = .clear
        let line = lines[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = ServiceLogViewController.levels.indices.contains(Int(line.level)) ? ServiceLogViewController.levels[Int(line.level)] : "LOG"
        content.textProperties.font = Theme.font(10, .semibold)
        content.textProperties.color = line.level <= 2 ? .systemRed : (line.level == 3 ? .systemOrange : .secondaryLabel)
        content.secondaryText = line.text
        content.secondaryTextProperties.font = Theme.mono(11.5)
        content.secondaryTextProperties.color = .label
        content.textToSecondaryTextVerticalPadding = 3
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        cell.contentConfiguration = content
        return cell
    }
}

/// «Порядок серверов»: pins and manual order by dragging.
final class ServerOrderViewController: UITableViewController {
    private var subscriptions: [Subscription] = []

    init() {
        super.init(style: .plain)
        title = L("Порядок серверов")
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
        let row = UIStackView(.horizontal, spacing: 8, alignment: .center, [UILabel(L("Сортировать по имени"), font: Theme.font(17)), UIView(), toggle])
        let note = UILabel(L("Закреплённые серверы остаются сверху. Ручной порядок сохраняется при выборе сервера. Перетаскивание включает ручной порядок."), font: Theme.font(13), color: .secondaryLabel, lines: 0)
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
    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? L("Подписки") : groups[section - 1].name }

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

    /// The ways to add, in a sheet that slides up from the bottom. `source` is
    /// kept for callers; the sheet does not need an anchor.
    static func present(from host: UIViewController, source _: UIView? = nil) {
        let options: [AddSheetViewController.Option] = [
            .init(symbol: "doc.on.clipboard", title: L("Вставить из буфера обмена")) {
                guard let text = UIPasteboard.general.string, !text.isEmpty else {
                    App.shared.notice.value = L("Буфер обмена пуст.")
                    return
                }
                add(text, from: host)
            },
            .init(symbol: "link", title: L("Ввести ссылку или адрес подписки")) {
                let alert = UIAlertController(title: L("Ссылка"), message: L("Адрес подписки (https://…) или ссылка сервера (vless://, ss://, hysteria2://…)"), preferredStyle: .alert)
                alert.addTextField { $0.placeholder = "https://"; $0.autocapitalizationType = .none; $0.autocorrectionType = .no; $0.keyboardType = .URL }
                alert.addAction(UIAlertAction(title: L("Отмена"), style: .cancel))
                alert.addAction(UIAlertAction(title: L("Добавить"), style: .default) { _ in add(alert.textFields?.first?.text ?? "", from: host) })
                host.present(alert, animated: true)
            },
            .init(symbol: "qrcode.viewfinder", title: L("Отсканировать QR")) {
                host.present(QRScannerViewController.wrapped { code in add(code, from: host) }, animated: true)
            },
            .init(symbol: "folder", title: L("Выбрать файл")) {
                picker.pick(from: host) { text in add(text, from: host) }
            },
            .init(symbol: "square.and.pencil", title: L("Создать вручную")) {
                host.present(ServerEditorViewController.wrapped(title: L("Новый сервер")) { outbound, name in
                    App.shared.addManual(outbound, name: name)
                }, animated: true)
            },
        ]
        host.present(AddSheetViewController(title: L("Добавить сервер или подписку"), options: options), animated: true)
    }

    private static func add(_ text: String, from host: UIViewController) {
        let progress = UIAlertController(title: nil, message: L("Добавление…"), preferredStyle: .alert)
        host.present(progress, animated: true)
        App.shared.add(text: text) { message in
            progress.dismiss(animated: true) {
                Haptics.result(message == nil)
                if let message { App.shared.notice.value = message }
            }
        }
    }
}

/// A sheet from the bottom with a title and a card of options; it is as tall as
/// its content and closes with a swipe down. A chosen option runs once the sheet
/// has gone, so whatever it presents comes from the screen underneath.
final class AddSheetViewController: UIViewController {
    struct Option {
        var symbol: String
        var title: String
        var action: () -> Void
    }

    private let heading: String
    private let options: [Option]
    private let content = UIStackView(.vertical, spacing: 14, alignment: .fill, [])

    init(title: String, options: [Option]) {
        heading = title
        self.options = options
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The colours of the servers sheet: its grouped grey, cards like the subscriptions'.
        view.backgroundColor = .systemGroupedBackground
        let title = UILabel(heading, font: Theme.font(.headline), lines: 0)
        title.textAlignment = .center
        content.addArrangedSubview(title)

        let card = UIView()
        card.backgroundColor = SurfaceView.card
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        let rows = UIStackView(.vertical, spacing: 0, alignment: .fill, [])
        for (index, option) in options.enumerated() {
            if index > 0 {
                let divider = UIView()
                divider.backgroundColor = .separator
                divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
                rows.addArrangedSubview(Classic.padded(divider, UIEdgeInsets(top: 0, left: 56, bottom: 0, right: 0)))
            }
            rows.addArrangedSubview(row(option))
        }
        card.addSubview(rows)
        rows.pin(to: card)
        content.addArrangedSubview(card)

        view.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 26),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
        if let sheet = sheetPresentationController {
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 30
            sheet.detents = [.custom(identifier: .init("content")) { [weak self] context in
                guard let self else { return context.maximumDetentValue }
                let width = self.view.bounds.width > 0 ? self.view.bounds.width : UIScreen.main.bounds.width
                let fitted = self.content.systemLayoutSizeFitting(CGSize(width: width - 32, height: UIView.layoutFittingCompressedSize.height),
                                                                 withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
                // Below the card: room for the home indicator (the detent excludes the bottom safe area).
                return min(context.maximumDetentValue, 26 + fitted.height + 16)
            }]
        }
    }

    private func row(_ option: Option) -> UIView {
        let control = TapControl()
        control.pressScale = 1
        let icon = UIImageView(image: UIImage(systemName: option.symbol, withConfiguration: UIImage.SymbolConfiguration(font: Theme.font(.body, .medium))))
        icon.tintColor = Theme.accent
        icon.contentMode = .center
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        let title = UILabel(option.title, font: Theme.font(.body), lines: 0)
        let line = UIStackView(.horizontal, spacing: 14, alignment: .center, [icon, title])
        line.isUserInteractionEnabled = false
        control.addSubview(line)
        line.pin(to: control, insets: UIEdgeInsets(top: 15, left: 16, bottom: 15, right: 16))
        control.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        control.accessibilityLabel = option.title
        control.accessibilityTraits = .button
        control.isAccessibilityElement = true
        control.onTap = { [weak self] in
            let action = option.action
            self?.dismiss(animated: true) { action() }
        }
        return control
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
    init() { super.init(title: L("Управление подписками")) }

    override func viewDidLoad() {
        super.viewDidLoad()
        App.shared.store.library.observe(self, fireNow: false) { [weak self] _ in self?.rebuild() }
    }

    override func build() -> [FormSection] {
        var sections = [FormSection([
            .button(title: L("Добавить сервер или подписку"), destructive: false) { [weak self] in
                if let self { AddServerFlow.present(from: self) }
            },
            .button(title: L("Обновить подписки"), destructive: false) { App.shared.refreshAll() },
        ])]
        // Subscriptions without servers are not shown (1.x left empty placeholders behind).
        for subscription in App.shared.library.subscriptions where !subscription.nodes.isEmpty {
            var rows: [FormRow] = [
                .value(title: Format.plural(subscription.nodes.count, L("сервер"), L("сервера"), L("серверов")), detail: { L("обновлена ") + Format.ago(subscription.updatedAt) }),
            ]
            if let expires = subscription.info.expiresAt {
                let formatter = DateFormatter()
                formatter.locale = Language.locale
                formatter.dateStyle = .medium
                rows.append(.value(title: L("Действует до"), detail: { formatter.string(from: expires) }))
            }
            if let used = subscription.info.usedBytes {
                rows.append(.value(title: L("Трафик"), detail: {
                    Format.bytes(used) + (subscription.info.isLimited ? L(" из ") + Format.bytes(subscription.info.totalBytes ?? 0) : L(" · без лимита"))
                }))
            }
            let id = subscription.id
            if subscription.isRemote {
                rows.append(.toggle(title: L("Отправлять HWID"), get: { App.shared.library.subscription(id)?.sendsDeviceIdentity ?? true }, set: { value in
                    App.shared.store.update { library in
                        guard var current = library.subscription(id) else { return }
                        current.sendsDeviceIdentity = value
                        library.replace(current)
                    }
                }))
                rows.append(.button(title: L("Обновить"), destructive: false) { App.shared.refresh(id) })
            }
            rows.append(.button(title: L("Удалить"), destructive: true) { [weak self] in
                let alert = UIAlertController(title: nil, message: Lf("Удалить «%@»?", "\(subscription.name)"), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L("Отмена"), style: .cancel))
                alert.addAction(UIAlertAction(title: L("Удалить"), style: .destructive) { _ in App.shared.delete(subscription: id) })
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

    init() { super.init(title: L("Резервные копии")) }

    override func build() -> [FormSection] {
        [FormSection(footer: L("Копия содержит адреса подписок и ключи серверов. Храните её как пароль."), [
            .button(title: L("Сохранить копию в Файлы"), destructive: false) { [weak self] in self?.export() },
            .button(title: L("Восстановить из файла"), destructive: false) { [weak self] in self?.restore() },
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
                App.shared.notice.value = Lf("Восстановлено подписок: %@.", "\(library.subscriptions.count)")
            } else {
                // Not a 2.0 backup: try it as servers or a configuration.
                App.shared.add(text: text) { message in App.shared.notice.value = message ?? L("Серверы из файла добавлены.") }
            }
        }
    }
}

final class NetworkActivityViewController: FormViewController {
    init() { super.init(title: L("Сетевая активность")) }

    override func build() -> [FormSection] {
        [FormSection(footer: L("У приложения нет своего сервера. Само оно выходит в сеть только чтобы обновить подписки, проверить соединение по кнопке и измерить задержку серверов."), [
            .value(title: L("Обновление подписок"), detail: { L("по запросу") }),
            .value(title: L("Проверка соединения"), detail: { "www.gstatic.com" }),
            .value(title: L("Пинг серверов"), detail: { L("URL-тест через сервер") }),
            .value(title: "HWID", detail: { String(DeviceIdentity.hwid.prefix(4)) + "…" + String(DeviceIdentity.hwid.suffix(4)) }),
        ])]
    }
}

final class AboutViewController: FormViewController {
    /// «3.0, RC 1 (216)», «3.0, beta 3 (215)»; a release has no label: «3.0 (217)».
    static var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "3.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        let label = (info?["PersonalPrerelease"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return label.isEmpty ? "\(marketing) (\(build))" : "\(marketing), \(label) (\(build))"
    }

    init() { super.init(title: L("О приложении")) }

    override func build() -> [FormSection] {
        [FormSection(footer: L("Personal Tunnel — личный VPN-клиент на ядре sing-box (форк sing-box-lx). Лицензия GPL-3.0-or-later."), [
            .value(title: L("Версия"), detail: { AboutViewController.version }),
            .value(title: L("Ядро"), detail: { CoreInfo.version }),
            .value(title: "Xray-core", detail: { CoreInfo.xrayVersion }),
            .value(title: L("Ядро туннеля"), detail: { CoreInfo.tunnelCore }),
            .value(title: L("Коммит"), detail: { (Bundle.main.object(forInfoDictionaryKey: "PersonalSourceCommit") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "—" }),
            .value(title: L("Группа"), detail: { AppGroup.identifier }),
        ])]
    }
}
