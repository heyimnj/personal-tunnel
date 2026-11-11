import TunnelCore
import UIKit

/// Coloured protocol tags under a server name.
final class BadgeRow: UIView {
    private static let colors: [UIColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemTeal]
    private var labels: [UILabel] = []
    private var shown: [String] = []

    func set(_ badges: [String]) {
        guard badges != shown else { return }
        shown = badges
        labels.forEach { $0.removeFromSuperview() }
        labels = badges.enumerated().map { index, text in
            let color = BadgeRow.colors[index % BadgeRow.colors.count]
            let label = UILabel(text, font: Theme.font(11, .semibold), color: color)
            label.textAlignment = .center
            label.backgroundColor = color.withAlphaComponent(0.13)
            label.layer.cornerRadius = 8.5
            label.layer.masksToBounds = true
            addSubview(label)
            return label
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0
        for label in labels {
            let width = ceil(label.intrinsicContentSize.width) + 12
            label.frame = CGRect(x: x, y: 0, width: width, height: 17)
            label.isHidden = x + width > bounds.width
            x += width + 4
        }
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 17) }
}

/// The «Серверы» sheet: subscriptions as cards that open into their servers.
final class MinimalServersViewController: UIViewController {
    private let list = ServerListView()
    private var expanded = Prefs.expandedSubscriptions
    private var ordered: [Subscription] = []
    private let subtitle = UILabel(font: Theme.font(12), color: .secondaryLabel)
    private let pingButton = UIButton(type: .system)
    private var titleCenter: NSLayoutConstraint!

    static func wrapped() -> UIViewController {
        let controller = MinimalServersViewController()
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.preferredCornerRadius = 36
        }
        controller.overrideUserInterfaceStyle = Theme.userInterfaceStyle
        return controller
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        view.tintColor = Theme.accent
        buildList()
        buildHeader()
        App.shared.store.library.observe(self) { [weak self] _ in self?.reload() }
        App.shared.latency.changed.observe(self, fireNow: false) { [weak self] keys in self?.refresh(keys) }
        App.shared.latency.progress.observe(self) { [weak self] in self?.show($0) }
        App.shared.refreshing.observe(self, fireNow: false) { [weak self] _ in self?.list.reconfigureHeaders() }
        App.shared.tunnel.state.observe(self, fireNow: false) { [weak self] _ in self?.list.reconfigureRows() }
    }

    // MARK: Header

    private func circle(_ symbol: String, _ action: Selector) -> UIView {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        button.tintColor = .label
        button.addTarget(self, action: action, for: .touchUpInside)
        let glass = GlassView()
        glass.contentView.addSubview(button)
        button.pin(to: glass.contentView)
        glass.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([glass.widthAnchor.constraint(equalToConstant: 44), glass.heightAnchor.constraint(equalToConstant: 44)])
        return glass
    }

    private func buildHeader() {
        let bar = UIView()
        // The page's own tone, so the first card does not run into the bar.
        bar.backgroundColor = .systemGroupedBackground
        view.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        let close = circle("xmark", #selector(closeTapped))
        let title = UILabel("Серверы", font: Theme.font(17, .semibold))
        subtitle.textAlignment = .center
        let titles = UIStackView(.vertical, spacing: 1, alignment: .center, [title, subtitle])

        let plus = UIButton(type: .system)
        plus.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
        plus.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        let more = UIButton(type: .system)
        more.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold)), for: .normal)
        more.showsMenuAsPrimaryAction = true
        more.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.moreItems() ?? []) }])
        pingButton.addTarget(self, action: #selector(pingTapped), for: .touchUpInside)
        let actions = UIStackView(.horizontal, spacing: 0, alignment: .fill, [pingButton, plus, more])
        actions.distribution = .fillEqually
        for button in [pingButton, plus, more] { button.tintColor = Theme.accent }
        let glass = GlassView()
        glass.contentView.addSubview(actions)
        actions.pin(to: glass.contentView, insets: UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4))

        for item in [close, titles, glass] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(item)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor), bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor), bar.heightAnchor.constraint(equalToConstant: 70),
            close.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16), close.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: 3),
            titles.centerXAnchor.constraint(equalTo: bar.centerXAnchor), titles.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            glass.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16), glass.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            glass.heightAnchor.constraint(equalToConstant: 44), glass.widthAnchor.constraint(equalToConstant: 116),
        ])
        list.contentInset.top = 76
        list.verticalScrollIndicatorInsets.top = 76
    }

    private func show(_ progress: LatencyProgress) {
        let symbol = progress.running ? "stop.circle.fill" : "waveform.path.ecg"
        pingButton.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: progress.running ? 22 : 17, weight: .medium)), for: .normal)
        pingButton.accessibilityLabel = progress.running ? "Остановить проверку" : "Проверить пинг"
        subtitle.text = progress.running ? "Проверено \(progress.done) из \(progress.total)" : nil
        subtitle.isHidden = !progress.running
    }

    private func moreItems() -> [UIMenuElement] {
        let arrangement = Prefs.arrangement
        return [
            UIAction(title: "Сортировать по имени", image: UIImage(systemName: "textformat.abc"), state: arrangement.byName ? .on : .off) { [weak self] _ in
                var next = Prefs.arrangement
                next.byName.toggle()
                Prefs.arrangement = next
                self?.reload()
            },
            UIAction(title: "Сортировать по задержке", image: UIImage(systemName: "speedometer"), state: Prefs.sortByLatency ? .on : .off) { [weak self] _ in
                Prefs.sortByLatency.toggle()
                self?.reload()
            },
            UIAction(title: "Порядок серверов") { [weak self] _ in
                let order = UINavigationController(rootViewController: ServerOrderViewController())
                self?.present(order, animated: true)
            },
            UIAction(title: "Закрепить текущий сервер") { [weak self] _ in
                let library = App.shared.library
                guard let subscription = library.activeSubscription, let node = library.activeNode else { return }
                var next = Prefs.arrangement
                let key = subscription.isStandalone ? Arrangement.subscription(subscription.id) : Arrangement.server(subscription.id, node.id)
                if !next.isPinned(key) { next.togglePin(key) }
                Prefs.arrangement = next
                self?.reload()
            },
            UIAction(title: "Обновить подписки") { _ in App.shared.refreshAll() },
        ]
    }

    @objc private func closeTapped() { dismiss(animated: true) }

    @objc private func pingTapped() {
        Haptics.tap()
        if App.shared.latency.progress.value.running {
            App.shared.latency.cancel()
        } else {
            // Open subscriptions and single servers are what the user is looking at.
            let visible = ordered.filter { $0.isStandalone || expanded.contains($0.id) }
            App.shared.ping(visible.isEmpty ? ordered : visible)
        }
    }

    @objc private func addTapped() {
        AddServerFlow.present(from: self)
    }

    // MARK: List

    private func buildList() {
        list.frame = view.bounds
        list.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(list)
        list.configureHeader = { header, id in
            guard let subscription = App.shared.library.subscription(id) else { return }
            header.title.text = subscription.name
            header.title.font = Theme.font(17, .semibold)
            header.count.text = "\(subscription.nodes.count)"
            header.pin.isHidden = !Prefs.arrangement.isPinned(Arrangement.subscription(id))
            if App.shared.refreshing.value.contains(id) { header.spinner.startAnimating() } else { header.spinner.stopAnimating() }
        }
        list.configureRow = { [weak self] row, id, tag in
            guard let subscription = App.shared.library.subscription(id), let node = subscription.node(tag) else { return }
            self?.configure(row, node: node, subscription: subscription)
        }
        list.actionsForHeader = { [weak self] id in
            [SwipeAction(symbol: "pencil", color: .systemOrange, title: "Редактировать") { self?.rename(subscription: id) },
             SwipeAction(symbol: "arrow.clockwise", color: Theme.accent, title: "Обновить") { App.shared.refresh(id) },
             SwipeAction(symbol: "trash", color: .systemRed, title: "Удалить") { self?.confirmDelete(subscription: id) }]
        }
        list.actionsForRow = { [weak self] id, tag in
            [SwipeAction(symbol: "pencil", color: .systemOrange, title: "Редактировать") { self?.rename(node: tag, in: id) },
             SwipeAction(symbol: "waveform.path.ecg", color: Theme.accent, title: "Проверить пинг") {
                 if let subscription = App.shared.library.subscription(id), let node = subscription.node(tag) { App.shared.ping(node: node, in: subscription) }
             },
             SwipeAction(symbol: "trash", color: .systemRed, title: "Удалить") { self?.confirmDelete(node: tag, in: id) }]
        }
        list.onToggle = { [weak self] id in self?.toggle(id) }
        list.onSelect = { id, tag in App.shared.select(node: tag, in: id) }
        list.onPing = { id, tag in
            guard let subscription = App.shared.library.subscription(id), let node = subscription.node(tag) else { return }
            Haptics.tap()
            App.shared.ping(node: node, in: subscription)
        }
        list.onHold = { [weak self] id, tag, point, release in self?.hold(id, tag, at: point, release: release) }
    }

    private func configure(_ row: ServerRowView, node: ServerNode, subscription: Subscription) {
        let label = App.shared.store.label(of: node, in: subscription)
        row.name.text = label.text
        row.name.font = Theme.font(17, .medium)
        let emoji = Theme.flag(label.countryCode)
        row.flag.text = emoji
        row.flag.isHidden = emoji == nil
        row.globe.isHidden = emoji != nil
        row.badges.set(node.facts.badges)
        let library = App.shared.library
        row.check.isHidden = !(library.activeSubscription?.id == subscription.id && library.selectedNodeID(in: subscription) == node.id)
        if App.shared.latency.isTesting(subscription.id, node.id) {
            row.ping.text = nil
            row.spinner.startAnimating()
        } else {
            row.spinner.stopAnimating()
            switch App.shared.latency.entry(subscription.id, node.id)?.result {
            case let .delay(value)?:
                row.ping.text = "\(value) ms"
                row.ping.textColor = .label
            case let .failed(reason)?:
                row.ping.text = reason.title
                row.ping.textColor = .secondaryLabel
            case nil:
                row.ping.text = "—"
                row.ping.textColor = .tertiaryLabel
            }
        }
    }

    private func sortedNodes(_ subscription: Subscription) -> [ServerNode] {
        let labels = App.shared.store.labels(for: subscription)
        var nodes = Prefs.arrangement.sorted(subscription.nodes, key: { Arrangement.server(subscription.id, $0.id) }, name: { labels[$0.id]?.text ?? $0.name })
        if Prefs.sortByLatency {
            let latency = App.shared.latency
            let pinned = Set(Prefs.arrangement.pinned)
            nodes = nodes.enumerated().sorted { left, right in
                let lp = pinned.contains(Arrangement.server(subscription.id, left.element.id)), rp = pinned.contains(Arrangement.server(subscription.id, right.element.id))
                if lp != rp { return lp }
                let l = latency.entry(subscription.id, left.element.id)?.result.milliseconds ?? Int.max
                let r = latency.entry(subscription.id, right.element.id)?.result.milliseconds ?? Int.max
                return l != r ? l < r : left.offset < right.offset
            }.map(\.element)
        }
        return nodes
    }

    private func reload() {
        let library = App.shared.library
        ordered = Prefs.arrangement.sorted(library.subscriptions.filter { !$0.nodes.isEmpty }, key: { Arrangement.subscription($0.id) }, name: { $0.name })
        let sections = ordered.map { subscription in
            ServerListView.Section(id: subscription.id, standalone: subscription.isStandalone, nodes: sortedNodes(subscription).map(\.id))
        }
        list.set(sections, open: expanded)
    }

    /// A latency batch touches only the rows it changed.
    private func refresh(_ keys: Set<String>) {
        if Prefs.sortByLatency, !App.shared.latency.progress.value.running {
            reload()
            return
        }
        list.reconfigureRows { id, tag in keys.contains(LatencyService.key(id, tag)) }
    }

    private func toggle(_ id: Int64) {
        let open = !list.isOpen(id)
        if open { expanded.insert(id) } else { expanded.remove(id) }
        Prefs.expandedSubscriptions = expanded
        Haptics.soft(open ? 0.55 : 0.4)
        list.setOpen(id, open)
    }

    // MARK: Row actions

    private func hold(_ id: Int64, _ tag: String?, at point: CGPoint, release: @escaping () -> Void) {
        guard let subscription = App.shared.library.subscription(id) else { return }
        let pinKey: String
        var items: [HoldMenuItem]
        let title: String
        if let tag, let node = subscription.node(tag) {
            title = App.shared.store.label(of: node, in: subscription).text
            pinKey = subscription.isStandalone ? Arrangement.subscription(id) : Arrangement.server(id, tag)
            items = [
                HoldMenuItem(title: "Проверить пинг", symbol: "waveform.path.ecg") { App.shared.ping(node: node, in: subscription) },
                HoldMenuItem(title: "Редактировать", symbol: "pencil") { [weak self] in self?.rename(node: tag, in: id) },
                HoldMenuItem(title: "Скопировать ссылку", symbol: "doc.on.doc") { [weak self] in self?.copy(node.link ?? (subscription.isStandalone ? subscription.url : nil)) },
            ]
            if subscription.isStandalone, subscription.isRemote {
                items.insert(HoldMenuItem(title: "Обновить", symbol: "arrow.clockwise") { App.shared.refresh(id) }, at: 2)
            }
        } else {
            title = subscription.name
            pinKey = Arrangement.subscription(id)
            items = [
                HoldMenuItem(title: "Проверить пинг", symbol: "waveform.path.ecg") { App.shared.ping([subscription]) },
                HoldMenuItem(title: "Редактировать", symbol: "pencil") { [weak self] in self?.rename(subscription: id) },
                HoldMenuItem(title: "Обновить", symbol: "arrow.clockwise") { App.shared.refresh(id) },
                HoldMenuItem(title: "Скопировать ссылку", symbol: "doc.on.doc") { [weak self] in self?.copy(subscription.url) },
            ]
        }
        items.append(HoldMenuItem(title: Prefs.arrangement.isPinned(pinKey) ? "Открепить" : "Закрепить", symbol: "pin") { [weak self] in self?.togglePin(pinKey) })
        items.append(HoldMenuItem(title: "Удалить", symbol: "trash", destructive: true) { [weak self] in
            if let tag { self?.confirmDelete(node: tag, in: id) } else { self?.confirmDelete(subscription: id) }
        })
        HoldMenuView.show(in: view, at: list.convert(point, to: view), title: title, items: items, onDismiss: release)
    }

    private func togglePin(_ key: String) {
        var next = Prefs.arrangement
        next.togglePin(key)
        Prefs.arrangement = next
        reload()
    }

    private func copy(_ text: String?) {
        guard let text, !text.isEmpty else {
            App.shared.notice.value = "У этого сервера нет исходной ссылки: он добавлен из файла или из подписки в формате JSON."
            return
        }
        UIPasteboard.general.string = text
        Haptics.result(true)
    }

    private func prompt(_ title: String, value: String, apply: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = value; $0.clearButtonMode = .whileEditing }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Сохранить", style: .default) { _ in
            let text = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { apply(text) }
        })
        present(alert, animated: true)
    }

    private func rename(subscription id: Int64) {
        guard let subscription = App.shared.library.subscription(id) else { return }
        prompt("Название подписки", value: subscription.name) { App.shared.rename(subscription: id, to: $0) }
    }

    private func rename(node tag: String, in id: Int64) {
        guard let node = App.shared.library.subscription(id)?.node(tag) else { return }
        prompt("Название сервера", value: node.name) { name in
            App.shared.store.update { library in
                guard var subscription = library.subscription(id), let index = subscription.nodes.firstIndex(where: { $0.id == tag }) else { return }
                subscription.nodes[index].name = name
                library.replace(subscription)
            }
        }
    }

    private func confirm(_ message: String, action: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { _ in action() })
        present(alert, animated: true)
    }

    private func confirmDelete(subscription id: Int64) {
        guard let subscription = App.shared.library.subscription(id) else { return }
        confirm("Удалить «\(subscription.name)»?") { App.shared.delete(subscription: id) }
    }

    private func confirmDelete(node tag: String, in id: Int64) {
        guard let node = App.shared.library.subscription(id)?.node(tag) else { return }
        confirm("Удалить сервер «\(node.name)»?") { App.shared.delete(node: tag, in: id) }
    }
}
