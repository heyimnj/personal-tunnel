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
            // 3.5.25 (the owner): no «Открыть журнал службы» — the log opens this page,
            // and the two led into each other without end.
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
            "\(TunnelController.appName) \(AboutViewController.version)", tunnel.text ?? "", Lf("Прокси: %@", "\(proxyResult)"), Lf("Интернет: %@", "\(internetResult)"),
            Lf("Протокол: %@", "\(library.activeNode?.facts.summary ?? "—")"), Lf("Режим пинга: %@", "\(Prefs.pingMode)"),
            L("Ядро туннеля") + ": " + CoreInfo.tunnelCore, memory.text ?? "",
        ].joined(separator: "\n")
        UIPasteboard.general.string = Redactor.forSharing(report, hosts: library.serverHosts)
        Haptics.result(true)
    }
}

/// «Журнал службы»: the core's log, streamed while the screen is open.
final class ServiceLogViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    private let table = UITableView(frame: .zero, style: .plain)
    private lazy var scrubber = ScrollScrubber(scrollView: table)
    private let live = UILabel("LIVE", font: Theme.font(12, .bold), color: .systemRed)
    private let state = UILabel("STREAMING", font: Theme.font(12, .semibold), color: .secondaryLabel)
    /// 3.6.16 (the owner: from the analytics): the core's memory, a thin line over
    /// the entries while the tunnel is up — «Память ядра  31.0 MB из 50 MB · 49 goroutines».
    private let memoryValue = UILabel(font: Theme.digits(12, .regular), color: .secondaryLabel)
    private lazy var memoryRow = UIStackView(.horizontal, spacing: 6, alignment: .firstBaseline, [
        UILabel(L("Память ядра"), font: Theme.font(12), color: .secondaryLabel), UIView(), memoryValue,
    ])
    private let search = UISearchBar()
    private var lines: [LogLine] = []
    /// How many times each shown line came in a row (3.6.19).
    private var repeats: [Int] = []
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
                    // 3.3 (PT-16): «info» (every connection) for half an hour, then «warn» again.
                    // 3.6.12 (the owner): «Подробный отчёт» (was «Подробный журнал для диагностики»),
                    // the trace below «Полный отчёт» (was «Подробный журнал»).
                    UIAction(title: L("Подробный отчёт"),
                             subtitle: Prefs.diagnosticLogActive
                                 ? Lf("Сам выключится через %@ мин", "\(max(1, Int(((Prefs.diagnosticLogUntil ?? Date()).timeIntervalSinceNow / 60).rounded(.up))))")
                                 : L("Каждое соединение на 30 минут"),
                             state: Prefs.diagnosticLogActive ? .on : .off) { _ in
                        App.shared.setDiagnosticLog(!Prefs.diagnosticLogActive)
                    },
                    UIAction(title: L("Полный отчёт"), subtitle: L("Каждый пакет: нагружает туннель"), state: Prefs.verboseLog ? .on : .off) { _ in
                        Prefs.verboseLog.toggle()
                        App.shared.reloadTunnel()
                    },
                    UIAction(title: L("Очистить журнал"), attributes: .destructive) { _ in App.shared.core.clearLogs() },
                ])
            },
        ])
        // 3.5.24 (the owner): «Проверка соединения» is here, first of the tools (it
        // was a row at the bottom of analytics).
        let check = tool("stethoscope", #selector(openCheck))
        check.accessibilityLabel = L("Проверка соединения")
        let bar = UIStackView(.horizontal, spacing: 6, alignment: .center, [dot, live, UIView(), check, tool("doc.on.doc", #selector(copyAll)), tool("magnifyingglass", #selector(toggleSearch)), pause, filter])
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
        table.delegate = self
        // Our own indicator, which can be taken and dragged (ScrollScrubber).
        table.showsVerticalScrollIndicator = false
        table.backgroundColor = FormViewController.cellColor
        table.layer.cornerRadius = 20
        table.layer.cornerCurve = .continuous
        table.separatorInset = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 44
        table.allowsSelection = false
        memoryRow.isLayoutMarginsRelativeArrangement = true
        memoryRow.layoutMargins = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        memoryValue.textAlignment = .right
        memoryValue.adjustsFontSizeToFitWidth = true
        memoryValue.minimumScaleFactor = 0.8
        let stack = UIStackView(.vertical, spacing: 10, alignment: .fill, [panel, search, caption, memoryRow, table])
        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            // Above the tab bar, so the card's rounded bottom is seen whole.
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        view.addSubview(scrubber)
        scrubber.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrubber.topAnchor.constraint(equalTo: table.topAnchor, constant: 10), scrubber.bottomAnchor.constraint(equalTo: table.bottomAnchor, constant: -10),
            scrubber.trailingAnchor.constraint(equalTo: table.trailingAnchor), scrubber.widthAnchor.constraint(equalToConstant: 30),
        ])
        stack.setCustomSpacing(4, after: caption)
        stack.setCustomSpacing(6, after: memoryRow)
        showMemory(App.shared.core.status.value)
        App.shared.core.status.observe(self) { [weak self] status in
            guard let self, self.viewIfLoaded?.window != nil else { return }
            self.showMemory(status)
        }
        caption.isLayoutMarginsRelativeArrangement = true
        caption.layoutMargins = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        // 3.5.11: only while on screen (the log streams all the time since 3.5, and a
        // log page left open under another tab redrew itself for every line).
        App.shared.core.logsChanged.observe(self) { [weak self] in
            guard let self, self.viewIfLoaded?.window != nil else { return }
            self.refilter()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refilter()
        showMemory(App.shared.core.status.value)
    }

    /// Shown only while the core reports (the tunnel is up).
    private func showMemory(_ status: CoreStatus?) {
        if let status {
            let text = Format.bytes(status.memory) + " " + Lf("из %@", "50 MB") + " · \(status.goroutines) goroutines"
            if memoryValue.text != text { memoryValue.text = text }
        }
        if memoryRow.isHidden != (status == nil) { memoryRow.isHidden = status == nil }
    }

    private func refilter() {
        let needle = query.lowercased()
        // Newest first: the screen opens on the latest lines and keeps them in view
        // while the reader stays at the top.
        let shown: [LogLine] = App.shared.core.logs.filter { $0.level <= minimumLevel && (needle.isEmpty || $0.text.lowercased().contains(needle)) }.reversed()
        // 3.6.19: a run of the same line (connections' numbers aside) stands once, the newest, with its count.
        let runs = LogDigest.runs(levels: shown.map(\.level), texts: shown.map(\.text))
        lines = runs.map { shown[$0.first] }
        repeats = runs.map(\.count)
        let atTop = table.contentOffset.y <= -table.adjustedContentInset.top + 40
        table.reloadData()
        if atTop, !lines.isEmpty { table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false) }
        let running = App.shared.tunnel.state.value.isOn
        state.text = !running ? "STOPPED" : (App.shared.core.logsPaused ? "PAUSED" : "STREAMING")
        live.text = running && !App.shared.core.logsPaused ? "LIVE" : "PAUSE"
    }

    /// Every line of the log, and the extension's own short log (memory, starts,
    /// stops), which outlives the extension. Addresses and keys are removed.
    @objc private func openCheck() {
        Haptics.tap()
        let page = DiagnosticsViewController()
        if let navigation = navigationController {
            navigation.pushViewController(page, animated: true)
        } else {
            let navigation = UINavigationController(rootViewController: page)
            navigation.overrideUserInterfaceStyle = Theme.userInterfaceStyle
            present(navigation, animated: true)
        }
    }

    @objc private func copyAll() {
        let levels = ServiceLogViewController.levels
        var text = ["\(TunnelController.appName) \(AboutViewController.version), " + L("ядро туннеля") + ": \(CoreInfo.tunnelCore)",
                    // 3.1.14: which shared container the app really got (a signing tool may give another).
                    "App Group: \(AppGroup.identifier)" + (App.shared.paths == nil ? " — " + L("нет доступа") : "")]
        // 3.5.14: the state the log was taken in, at its head (the owner: the log
        // must say more). Read from what the app already holds: nothing is woken.
        let device = UIDevice.current
        text.append("iOS \(device.systemVersion), " + Lf("стиль «%@», язык %@", "\(Prefs.style)", "\(Prefs.language)"))
        let tunnel = App.shared.tunnel
        var session = Lf("VPN: %@", "\(tunnel.state.value)")
        if let since = tunnel.connectedSince.value {
            session += ", " + Lf("сеанс %@", Format.duration(Int(Date().timeIntervalSince(since))))
        }
        if let status = App.shared.core.status.value {
            session += ", " + Lf("трафик ↓%@ ↑%@, память ядра %@", Format.bytes(status.downlinkTotal), Format.bytes(status.uplinkTotal), Format.bytes(status.memory))
        }
        text.append(session)
        let library = App.shared.library
        text.append(Lf("Подписок %@, серверов %@", "\(library.subscriptions.count)", "\(library.subscriptions.reduce(0) { $0 + $1.nodes.count })"))
        let options = Prefs.tunnelOptions
        let flags: [(String, Bool)] = [("autoSelect", options.autoSelect), ("killSwitch", Prefs.killSwitch), ("bypassRussia", options.bypassRussia),
                                       ("adBlocking", options.adBlocking), ("blockEncryptedDNS", options.blockEncryptedDNS), ("localNetwork", options.bypassPrivate), ("blockQUIC", options.blockQUIC),
                                       ("secureDNS", Prefs.secureDNS), ("autoConnect", Prefs.autoConnect), ("autoPing", Prefs.autoPing)]
        text.append(L("Настройки: ") + flags.map { "\($0.0)=\($0.1 ? "on" : "off")" }.joined(separator: ", ") + ", log=\(options.logLevel), ping=\(Prefs.pingMode)")
        text.append("")
        let hosts = App.shared.library.serverHosts
        // 3.3 (PT-16): no secrets, servers, destinations or addresses but the tunnel's own.
        func shared(_ lines: [String]) -> [String] {
            lines.isEmpty ? [] : Redactor.forSharing(lines.joined(separator: "\n"), hosts: hosts).components(separatedBy: "\n")
        }
        // 3.5: each line with its time; a line repeated stands once with its count
        // (masked first: lines that differ only by an address are the same then).
        let entries = App.shared.core.logs.map { line in
            LogDigest.Entry(level: levels.indices.contains(Int(line.level)) ? levels[Int(line.level)] : "LOG", time: line.time, text: line.text)
        }
        var masked = shared(entries.map(\.text))
        if masked.count != entries.count { masked = entries.map { Redactor.forSharing($0.text, hosts: hosts) } }
        let log = LogDigest.collapse(zip(entries, masked).map { LogDigest.Entry(level: $0.level, time: $0.time, text: $1) })
        text += log
        if let paths = App.shared.paths {
            // 3.5: only the last three sessions of the extension, not its events of days ago.
            let all = TunnelEvents.read(TunnelEvents.file(paths))
            let events = TunnelEvents.digest(all).map(TunnelText.localize)
            if !events.isEmpty { text += ["", L("Расширение:")] + shared(events) }
            let xray = ServiceLogViewController.tail(paths.xrayLog, lines: 80)
            if !xray.isEmpty { text += ["", "Xray-core:"] + shared(xray) }
            // 3.5: a fall of this session or the one before it, not of a day ago.
            let since = TunnelEvents.starts(all).suffix(2).first ?? Date().addingTimeInterval(-86_400)
            if let crash = ServiceLogViewController.lastCrash(paths, since: since) { text += ["", L("Последнее падение ядра:")] + shared(crash) }
        }
        UIPasteboard.general.string = text.joined(separator: "\n")
        Haptics.result(true)
        App.shared.notice.value = Lf("Скопировано строк: %@ из %@.", "\(log.count)", "\(entries.count)")
    }

    static func tail(_ url: URL, lines: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).map(String.init))
    }

    /// What the core wrote before it last fell (a Go panic), within the last day:
    /// the live file of the running extension, or the newest archived report.
    static func lastCrash(_ paths: SharedPaths, since: Date) -> [String]? {
        let manager = FileManager.default
        let dayAgo = max(since.addingTimeInterval(-5), Date().addingTimeInterval(-86_400))
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

    func scrollViewDidScroll(_: UIScrollView) { scrubber.update() }

    func tableView(_: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = table.dequeueReusableCell(withIdentifier: "line") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "line")
        cell.backgroundColor = .clear
        let line = lines[indexPath.row]
        var content = cell.defaultContentConfiguration()
        let level = ServiceLogViewController.levels.indices.contains(Int(line.level)) ? ServiceLogViewController.levels[Int(line.level)] : "LOG"
        // 3.5: the time the line came.
        content.text = line.time.map { level + " · " + $0 } ?? level
        if repeats.indices.contains(indexPath.row), repeats[indexPath.row] > 1 {
            content.text = (content.text ?? level) + " · ×\(repeats[indexPath.row])"
        }
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
        toggle.addTactileToggle()
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

    /// 3.3 (PT-14): the clipboard, a QR code, a file or typed text is shown on the
    /// confirmation first; nothing is fetched before «Добавить».
    private static func add(_ text: String, from host: UIViewController) {
        // A moment for a sheet that is closing (the file picker, the QR scanner) to go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            var top = host
            while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
            let presenter = top
            presenter.present(ImportConfirmViewController.wrapped(text) { text, sendsDeviceData in
                added(text, sendsDeviceData: sendsDeviceData, from: presenter)
            }, animated: true)
        }
    }

    private static func added(_ text: String, sendsDeviceData: Bool, from host: UIViewController) {
        let progress = UIAlertController(title: nil, message: L("Добавление…"), preferredStyle: .alert)
        host.present(progress, animated: true)
        App.shared.add(text: text, sendsDeviceData: sendsDeviceData) { message in
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
final class AddSheetViewController: UIViewController, UIViewControllerTransitioningDelegate, UIGestureRecognizerDelegate {
    struct Option {
        var symbol: String
        var title: String
        var action: () -> Void
    }

    private let heading: String
    private let options: [Option]
    /// The servers sheet's page and card tones (dark: #1C1C1E and #2C2C2E).
    static let sheetColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1) : UIColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1)
    }
    static let cardColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.173, green: 0.173, blue: 0.180, alpha: 1) : .white
    }
    private let content = UIStackView(.vertical, spacing: 14, alignment: .fill, [])

    init(title: String, options: [Option]) {
        heading = title
        self.options = options
        super.init(nibName: nil, bundle: nil)
        // 3.5.15 (the owner): iOS 26 floats a sheet of partial height, inset from
        // the screen's edges — the list showed under its bottom. There it is our own
        // sheet, attached to the bottom edge; below iOS 26 the system's, which is.
        if #available(iOS 26, *) {
            modalPresentationStyle = .custom
            transitioningDelegate = self
        } else {
            modalPresentationStyle = .pageSheet
        }
    }

    private var attached: Bool { modalPresentationStyle == .custom }

    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source _: UIViewController) -> UIPresentationController? {
        BottomSheetPresentation(presentedViewController: presented, presenting: presenting) { [weak self] width in
            self?.fittedHeight(width) ?? 0
        }
    }

    /// The sheet's height above the bottom safe area: the title and the card.
    private func fittedHeight(_ width: CGFloat) -> CGFloat {
        let fitted = content.systemLayoutSizeFitting(CGSize(width: width - 32, height: UIView.layoutFittingCompressedSize.height),
                                                     withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        // Below the card: room for the home indicator.
        return 26 + fitted.height + 16
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The colours of the servers sheet as it shows them, given outright: a sheet
        // of partial height is drawn on a raised (lighter) level in dark mode, and
        // on iOS 26 over glass, which turned the dynamic greys light grey.
        overrideUserInterfaceStyle = Theme.userInterfaceStyle
        let backdrop = UIView()
        backdrop.backgroundColor = Self.sheetColor
        backdrop.isUserInteractionEnabled = false
        view.addSubview(backdrop)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor), backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor), backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 200),
        ])
        view.backgroundColor = Self.sheetColor
        let title = UILabel(heading, font: Theme.font(.headline), lines: 0)
        title.textAlignment = .center
        content.addArrangedSubview(title)

        let card = UIView()
        card.backgroundColor = Self.cardColor
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
        if attached {
            view.layer.cornerRadius = 30
            view.layer.cornerCurve = .continuous
            view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            view.clipsToBounds = true
            let grabber = UIView()
            grabber.backgroundColor = UIColor.label.withAlphaComponent(0.18)
            grabber.layer.cornerRadius = 2.5
            grabber.isUserInteractionEnabled = false
            view.addSubview(grabber)
            grabber.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                grabber.topAnchor.constraint(equalTo: view.topAnchor, constant: 5), grabber.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                grabber.widthAnchor.constraint(equalToConstant: 36), grabber.heightAnchor.constraint(equalToConstant: 5),
            ])
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.delegate = self
            view.addGestureRecognizer(pan)
        } else if let sheet = sheetPresentationController {
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 30
            sheet.detents = [.custom(identifier: .init("content")) { [weak self] context in
                guard let self else { return context.maximumDetentValue }
                let width = self.view.bounds.width > 0 ? self.view.bounds.width : UIScreen.main.bounds.width
                // The detent excludes the bottom safe area.
                return min(context.maximumDetentValue, self.fittedHeight(width))
            }]
        }
    }

    /// Our sheet closes with a swipe down, as the system's does.
    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let down = max(0, pan.translation(in: view).y)
        switch pan.state {
        case .changed:
            view.transform = CGAffineTransform(translationX: 0, y: down)
        case .ended, .cancelled:
            let speed = pan.velocity(in: view).y
            if pan.state == .ended, down > 80 || speed > 700 {
                // From where the finger left it: the offset becomes the frame.
                let frame = view.frame
                view.transform = .identity
                view.frame = frame
                dismiss(animated: true)
            } else {
                UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                    self.view.transform = .identity
                }
            }
        default:
            break
        }
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool { true }

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

/// A sheet attached to the bottom edge, as tall as `height` (for the width) above
/// the bottom safe area; the rest of the screen dims, a touch on it closes the sheet.
final class BottomSheetPresentation: UIPresentationController {
    private let dim = UIControl()
    private let height: (CGFloat) -> CGFloat

    init(presentedViewController: UIViewController, presenting: UIViewController?, height: @escaping (CGFloat) -> CGFloat) {
        self.height = height
        super.init(presentedViewController: presentedViewController, presenting: presenting)
    }

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let container = containerView else { return .zero }
        let bounds = container.bounds
        let wanted = height(bounds.width) + container.safeAreaInsets.bottom
        let tall = min(bounds.height - container.safeAreaInsets.top, max(0, wanted))
        return CGRect(x: 0, y: bounds.height - tall, width: bounds.width, height: tall)
    }

    override func presentationTransitionWillBegin() {
        guard let container = containerView else { return }
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        dim.alpha = 0
        dim.frame = container.bounds
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.addTarget(self, action: #selector(dimTapped), for: .touchUpInside)
        container.insertSubview(dim, at: 0)
        guard let coordinator = presentedViewController.transitionCoordinator else { dim.alpha = 1; return }
        coordinator.animate(alongsideTransition: { _ in self.dim.alpha = 1 })
    }

    override func dismissalTransitionWillBegin() {
        guard let coordinator = presentedViewController.transitionCoordinator else { dim.alpha = 0; return }
        coordinator.animate(alongsideTransition: { _ in self.dim.alpha = 0 })
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        guard presentedViewController.view.transform == .identity else { return }
        presentedView?.frame = frameOfPresentedViewInContainerView
    }

    @objc private func dimTapped() { presentedViewController.dismiss(animated: true) }
}

/// A scroll indicator that can be taken and dragged, as long lists have it in
/// other apps: a thin grey capsule on the right that shows while the list
/// moves; held, it widens and the list follows it across its whole length.
final class ScrollScrubber: UIView {
    private weak var scrollView: UIScrollView?
    private let thumb = UIView()
    private var dragging = false
    private var grab: CGFloat = 0
    private var hideWork: DispatchWorkItem?
    private static let thin: CGFloat = 4
    private static let wide: CGFloat = 8

    init(scrollView: UIScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        thumb.backgroundColor = .systemGray
        thumb.alpha = 0
        thumb.layer.cornerCurve = .continuous
        addSubview(thumb)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panned(_:))))
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    /// Touches reach the scrubber only on its visible capsule (and a margin round
    /// it); everywhere else they go to the list.
    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        guard thumb.alpha > 0.05 else { return false }
        return thumb.frame.insetBy(dx: -16, dy: -14).contains(point)
    }

    private var range: (min: CGFloat, max: CGFloat, page: CGFloat)? {
        guard let scrollView else { return nil }
        let inset = scrollView.adjustedContentInset
        let page = scrollView.bounds.height
        let min = -inset.top
        let max = scrollView.contentSize.height + inset.bottom - page
        guard max - min > page * 0.5 else { return nil }
        return (min, max, page)
    }

    private var thumbHeight: CGFloat {
        guard let range else { return 0 }
        let total = range.max - range.min + range.page
        return Swift.max(40, bounds.height * range.page / total)
    }

    /// Places the capsule for the list's offset and shows it for a moment.
    func update() {
        guard !dragging else { return }
        layoutThumb()
        guard range != nil else { return }
        show()
        scheduleHide()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutThumb()
    }

    private func layoutThumb() {
        guard let scrollView, let range else { thumb.alpha = 0; return }
        let height = thumbHeight
        let fraction = Swift.min(1, Swift.max(0, (scrollView.contentOffset.y - range.min) / (range.max - range.min)))
        let width = dragging ? Self.wide : Self.thin
        thumb.frame = CGRect(x: bounds.width - width - 4, y: (bounds.height - height) * fraction, width: width, height: height)
        thumb.layer.cornerRadius = width / 2
    }

    private func show() {
        hideWork?.cancel()
        guard thumb.alpha < 1 else { return }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.thumb.alpha = 1 }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.dragging else { return }
            UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.thumb.alpha = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let scrollView, let range else { return }
        let point = pan.location(in: self)
        switch pan.state {
        case .began:
            dragging = true
            hideWork?.cancel()
            grab = point.y - thumb.frame.minY
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
            Haptics.selection()
            UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState]) { self.layoutThumb() }
        case .changed:
            let travel = Swift.max(1, bounds.height - thumbHeight)
            let fraction = Swift.min(1, Swift.max(0, (point.y - grab) / travel))
            scrollView.contentOffset.y = range.min + fraction * (range.max - range.min)
            layoutThumb()
        default:
            dragging = false
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) { self.layoutThumb() }
            scheduleHide()
        }
    }
}

/// Deletes an exported temporary file when the export sheet closes.
final class TemporaryFileCleanup: NSObject, UIDocumentPickerDelegate {
    var file: URL?

    private func clean() {
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }

    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt _: [URL]) { clean() }
    func documentPickerWasCancelled(_: UIDocumentPickerViewController) { clean() }
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
            // 3.5.23 (the owner): the automatic update is here, beside «Обновить подписки».
            .toggle(title: L("Автообновление подписок"), get: { Prefs.autoUpdateSubscriptions }, set: { Prefs.autoUpdateSubscriptions = $0 }),
            .note(L("Подписки обновляются сами раз в 24 часа или каждый день в выбранное время — при первом открытии приложения после него (и пока оно открыто). Выключено — только вручную.")),
            .picker(title: L("Время обновления"), options: Prefs.subscriptionUpdateOptions,
                    get: { String(Prefs.subscriptionUpdateHour) }, set: { Prefs.subscriptionUpdateHour = Int($0) ?? SubscriptionSchedule.everyDay }),
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
                    Format.traffic(used) + (subscription.info.isLimited ? L(" из ") + Format.traffic(subscription.info.totalBytes ?? 0) : L(" · без лимита"))
                }))
            }
            let id = subscription.id
            if subscription.isRemote {
                rows.append(.toggle(title: L("Передавать данные устройства провайдеру"), get: { App.shared.library.subscription(id)?.sendsDeviceIdentity ?? true }, set: { value in
                    App.setSendsDeviceData(value, for: id)
                }))
                rows.append(.button(title: L("Обновить"), destructive: false) { App.shared.refresh(id) })
            }
            rows.append(.button(title: L("Удалить"), destructive: true) { [weak self] in
                let alert = UIAlertController(title: nil, message: Lf("Удалить «%@»?", "\(subscription.name)"), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L("Отмена"), style: .cancel))
                alert.addAction(UIAlertAction(title: L("Удалить"), style: .destructive) { _ in App.shared.delete(subscription: id) })
                self?.present(alert, animated: true)
            })
            let footer = subscription.warnings.first ?? (subscription.isRemote ? L("При обновлении подписки провайдер получает HWID и модель iPhone, а версию iOS и язык — только если без них не отдаёт серверы. Подробнее — в «Конфиденциальности».") : nil)
            sections.append(FormSection(subscription.name, footer: footer, rows))
        }
        return sections
    }
}

/// «Резервные копии»: the whole library as one JSON file.
final class BackupViewController: FormViewController {
    private let picker = FilePicker()
    private let exportCleanup = TemporaryFileCleanup()

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
        // 3.3 (PT-15): the temporary copy (every key in it) goes once it is saved or not.
        let exporter = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        exportCleanup.file = url
        exporter.delegate = exportCleanup
        present(exporter, animated: true)
    }

    private func restore() {
        picker.pick(from: self) { [weak self] text in
            if let library = try? JSONDecoder().decode(Library.self, from: Data(text.utf8)), !library.subscriptions.isEmpty {
                // 3.3 (PT-14): a backup replaces everything; it is asked first.
                let servers = library.subscriptions.reduce(0) { $0 + $1.nodes.count }
                let alert = UIAlertController(title: L("Восстановить из копии?"),
                                              message: Lf("Все подписки и серверы заменятся копией из файла: подписок %@, серверов %@.", "\(library.subscriptions.count)", "\(servers)"),
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L("Отмена"), style: .cancel))
                alert.addAction(UIAlertAction(title: L("Восстановить"), style: .destructive) { _ in
                    App.shared.store.update { $0 = library }
                    App.shared.notice.value = Lf("Восстановлено подписок: %@.", "\(library.subscriptions.count)")
                })
                self?.present(alert, animated: true)
            } else if let self {
                // Not a 2.0 backup: servers or a configuration, shown on the confirmation first.
                self.present(ImportConfirmViewController.wrapped(text) { text, sendsDeviceData in
                    App.shared.add(text: text, sendsDeviceData: sendsDeviceData) { message in App.shared.notice.value = message ?? L("Серверы из файла добавлены.") }
                }, animated: true)
            }
        }
    }
}

final class NetworkActivityViewController: FormViewController {
    init() { super.init(title: L("Сетевая активность")) }

    override func build() -> [FormSection] {
        [FormSection(footer: L("У приложения нет своего сервера. Само оно выходит в сеть только чтобы обновить подписки (по команде, после подключения VPN и один раз после обновления приложения), проверить соединение по кнопке и измерить задержку серверов."), [
            .value(title: L("Обновление подписок"), detail: { L("по запросу") }),
            .value(title: L("Проверка соединения"), detail: { "www.gstatic.com" }),
            .value(title: L("Пинг серверов"), detail: { L("URL-тест через сервер") }),
            .value(title: "HWID", detail: { let id = DeviceIdentity.hwid; return id.count > 8 ? String(id.prefix(4)) + "…" + String(id.suffix(4)) : id }),
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
