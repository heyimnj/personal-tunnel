import TunnelCore
import UIKit

/// Coloured protocol tags under a server name. Each pill is a plain rounded layer
/// behind its text: no masking, so moving rows cost no offscreen passes.
final class BadgeRow: UIView {
    private static let colors: [UIColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemTeal]
    private var labels: [UILabel] = []
    private var pills: [UIView] = []
    private var shown: [String] = []

    private static let font = Theme.font(11, .semibold)
    private var widths: [CGFloat] = []

    /// Reuses its pills: a row scrolled into view only changes texts, it creates
    /// no views (creating them was the hitch while scrolling an open subscription).
    func set(_ badges: [String]) {
        guard badges != shown else { return }
        shown = badges
        while labels.count < badges.count {
            let color = BadgeRow.colors[labels.count % BadgeRow.colors.count]
            let pill = UIView()
            pill.backgroundColor = color.withAlphaComponent(0.13)
            pill.layer.cornerRadius = 8.5
            pill.isUserInteractionEnabled = false
            addSubview(pill)
            pills.append(pill)
            let label = UILabel("", font: BadgeRow.font, color: color)
            label.textAlignment = .center
            addSubview(label)
            labels.append(label)
        }
        widths = badges.map { ceil(($0 as NSString).size(withAttributes: [.font: BadgeRow.font]).width) + 12 }
        for (index, label) in labels.enumerated() {
            label.text = index < badges.count ? badges[index] : nil
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0
        for (index, (label, pill)) in zip(labels, pills).enumerated() {
            guard index < widths.count else {
                label.isHidden = true
                pill.isHidden = true
                continue
            }
            let width = widths[index]
            let frame = CGRect(x: x, y: 0, width: width, height: 17)
            if label.frame != frame { label.frame = frame; pill.frame = frame }
            let hidden = x + width > bounds.width
            label.isHidden = hidden
            pill.isHidden = hidden
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
    private let plusButton = UIButton(type: .system)
    private var titleCenter: NSLayoutConstraint!
    /// «Выбрать несколько», as in 1.5.0: taps select, the bar offers delete and copy.
    private var selecting = false
    private var selectedSubscriptions = Set<Int64>()
    /// `subscriptionID:tag`.
    private var selectedNodes = Set<String>()
    private var selectionEmpty: Bool { selectedSubscriptions.isEmpty && selectedNodes.isEmpty }

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
        let title = UILabel(L("Серверы"), font: Theme.font(17, .semibold))
        subtitle.textAlignment = .center
        let titles = UIStackView(.vertical, spacing: 1, alignment: .center, [title, subtitle])

        let plus = plusButton
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
        showBar()
    }

    /// The bar's first two buttons: ping and add, or (selecting) delete and copy.
    private func showBar() {
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        if selecting {
            pingButton.setImage(UIImage(systemName: "trash", withConfiguration: config), for: .normal)
            pingButton.accessibilityLabel = L("Удалить выбранное")
            plusButton.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: config), for: .normal)
            plusButton.accessibilityLabel = L("Скопировать выбранные ссылки")
            pingButton.isEnabled = !selectionEmpty
            plusButton.isEnabled = !selectionEmpty
            subtitle.text = Lf("Выбрано: %@", "\(selectedSubscriptions.count + selectedNodes.count)")
            subtitle.isHidden = false
        } else {
            plusButton.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
            plusButton.accessibilityLabel = L("Добавить")
            pingButton.isEnabled = true
            plusButton.isEnabled = true
            show(App.shared.latency.progress.value)
        }
    }

    private func show(_ progress: LatencyProgress) {
        guard !selecting else { return }
        let symbol = progress.running ? "stop.circle.fill" : "waveform.path.ecg"
        pingButton.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: progress.running ? 22 : 17, weight: .medium)), for: .normal)
        pingButton.accessibilityLabel = progress.running ? L("Остановить проверку") : L("Проверить пинг")
        subtitle.text = progress.running ? Lf("Проверено %@ из %@", "\(progress.done)", "\(progress.total)") : nil
        subtitle.isHidden = !progress.running
    }

    private func moreItems() -> [UIMenuElement] {
        let arrangement = Prefs.arrangement
        return [
            UIAction(title: L("Сортировать по имени"), image: UIImage(systemName: "textformat.abc"), state: arrangement.byName ? .on : .off) { [weak self] _ in
                var next = Prefs.arrangement
                next.byName.toggle()
                Prefs.arrangement = next
                self?.reload()
            },
            UIAction(title: L("Сортировать по задержке"), image: UIImage(systemName: "speedometer"), state: Prefs.sortByLatency ? .on : .off) { [weak self] _ in
                Prefs.sortByLatency.toggle()
                self?.reload()
            },
            UIAction(title: L("Порядок серверов")) { [weak self] _ in
                let order = UINavigationController(rootViewController: ServerOrderViewController())
                self?.present(order, animated: true)
            },
        ] + (selecting ? selectionItems() : [currentServerPin()]) + [
            UIAction(title: L("Обновить подписки")) { _ in App.shared.refreshAll() },
        ] + (selecting ? [UIAction(title: L("Отменить выбор")) { [weak self] _ in self?.endSelection() }] : [])
    }

    private func currentServerPin() -> UIMenuElement {
        UIAction(title: L("Закрепить текущий сервер")) { [weak self] _ in
            let library = App.shared.library
            guard let subscription = library.activeSubscription, let node = library.activeNode else { return }
            var next = Prefs.arrangement
            let key = subscription.isStandalone ? Arrangement.subscription(subscription.id) : Arrangement.server(subscription.id, node.id)
            if !next.isPinned(key) { next.togglePin(key) }
            Prefs.arrangement = next
            self?.reload()
        }
    }

    private func selectionItems() -> [UIMenuElement] {
        let empty = selectionEmpty
        var items: [UIMenuElement] = [
            UIAction(title: L("Закрепить выбранное"), attributes: empty ? .disabled : []) { [weak self] _ in self?.pinSelected(true) },
            UIAction(title: L("Открепить выбранное"), attributes: empty ? .disabled : []) { [weak self] _ in self?.pinSelected(false) },
            UIAction(title: L("Проверить выбранные узлы"), attributes: selectedNodes.isEmpty ? .disabled : []) { [weak self] _ in self?.pingSelected() },
        ]
        if selectedNodes.count == 1, let only = selectedNodes.first.flatMap(Self.split) {
            items.append(UIAction(title: L("Ссылка, QR и JSON")) { [weak self] _ in self?.inspect(only.1, in: only.0) })
        }
        return items
    }

    @objc private func closeTapped() {
        if selecting { endSelection() } else { dismiss(animated: true) }
    }

    @objc private func pingTapped() {
        Haptics.tap()
        if selecting {
            confirmDeleteSelected()
            return
        }
        if App.shared.latency.progress.value.running {
            App.shared.latency.cancel()
        } else {
            // Open subscriptions and single servers are what the user is looking at.
            let visible = ordered.filter { $0.isStandalone || expanded.contains($0.id) }
            App.shared.ping(visible.isEmpty ? ordered : visible)
        }
    }

    @objc private func addTapped() {
        if selecting {
            copySelected()
            return
        }
        AddServerFlow.present(from: self, source: plusButton)
    }

    // MARK: Selection

    static func split(_ key: String) -> (Int64, String)? {
        guard let colon = key.firstIndex(of: ":"), let id = Int64(key[..<colon]) else { return nil }
        return (id, String(key[key.index(after: colon)...]))
    }

    private func beginSelection(subscription: Int64? = nil, node: String? = nil) {
        if !selecting {
            selecting = true
            selectedSubscriptions = []
            selectedNodes = []
        }
        if let subscription {
            if let node { selectedNodes.insert(LatencyService.key(subscription, node)) } else { selectedSubscriptions.insert(subscription) }
        }
        selectionChanged(actions: true)
    }

    private func endSelection() {
        selecting = false
        selectedSubscriptions = []
        selectedNodes = []
        selectionChanged(actions: true)
    }

    private func selectionChanged(actions: Bool = false) {
        Haptics.selection()
        showBar()
        list.reconfigureRows()
        if actions { list.reloadActions() } else { list.reconfigureHeaders() }
    }

    private func toggleSelected(subscription id: Int64) {
        if selectedSubscriptions.contains(id) { selectedSubscriptions.remove(id) } else { selectedSubscriptions.insert(id) }
        selectionChanged()
    }

    private func toggleSelected(node tag: String, in id: Int64) {
        let key = LatencyService.key(id, tag)
        if selectedNodes.contains(key) { selectedNodes.remove(key) } else { selectedNodes.insert(key) }
        selectionChanged()
    }

    private var selectedPairs: [(Subscription, ServerNode)] {
        selectedNodes.compactMap(Self.split).compactMap { id, tag in
            guard let subscription = App.shared.library.subscription(id), let node = subscription.node(tag) else { return nil }
            return (subscription, node)
        }
    }

    private func pinSelected(_ pin: Bool) {
        var next = Prefs.arrangement
        var keys = selectedSubscriptions.map(Arrangement.subscription)
        for (subscription, node) in selectedPairs {
            keys.append(subscription.isStandalone ? Arrangement.subscription(subscription.id) : Arrangement.server(subscription.id, node.id))
        }
        for key in keys where next.isPinned(key) != pin { next.togglePin(key) }
        Prefs.arrangement = next
        reload()
    }

    private func pingSelected() {
        App.shared.ping(nodes: selectedPairs)
    }

    private func copySelected() {
        let library = App.shared.library
        let links = selectedSubscriptions.compactMap { library.subscription($0)?.url } + selectedPairs.compactMap { $0.1.link }
        guard !links.isEmpty else {
            App.shared.notice.value = L("У выбранного нет исходных ссылок: серверы добавлены из файла или из подписки в формате JSON.")
            return
        }
        UIPasteboard.general.string = links.joined(separator: "\n")
        Haptics.result(true)
        App.shared.notice.value = Lf("Скопировано ссылок: %@.", "\(links.count)")
    }

    private func confirmDeleteSelected() {
        guard !selectionEmpty else { return }
        let alert = UIAlertController(title: L("Удалить выбранное?"),
                                      message: L("Обновление удалённой подписки может вернуть её серверы. Сервер, оставшийся в подписке один, удаляется вместе с ней."),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("Удалить"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            let pairs = self.selectedPairs.filter { !self.selectedSubscriptions.contains($0.0.id) }
            for (subscription, node) in pairs { App.shared.delete(node: node.id, in: subscription.id) }
            for id in self.selectedSubscriptions { App.shared.delete(subscription: id) }
            self.endSelection()
        })
        present(alert, animated: true)
    }

    private func inspect(_ tag: String, in id: Int64) {
        guard let subscription = App.shared.library.subscription(id), let node = subscription.node(tag) else { return }
        let page = ServerInspectorViewController(node: node, subscription: subscription)
        let navigation = UINavigationController(rootViewController: page)
        navigation.overrideUserInterfaceStyle = Theme.userInterfaceStyle
        present(navigation, animated: true)
    }

    // MARK: List

    private func buildList() {
        list.frame = view.bounds
        list.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(list)
        list.configureHeader = { [weak self] header, id in
            guard let subscription = App.shared.library.subscription(id) else { return }
            header.title.text = subscription.name
            header.title.font = Theme.font(17, .semibold)
            // With a filter on: shown of all.
            let section = self?.list.sections.first { $0.id == id }
            if let section, !section.selected.isEmpty {
                header.count.text = "\(section.nodes.count)/\(subscription.nodes.count)"
            } else {
                header.count.text = "\(subscription.nodes.count)"
            }
            header.pin.isHidden = !Prefs.arrangement.isPinned(Arrangement.subscription(id))
            header.setMark(self?.selecting == true ? self?.selectedSubscriptions.contains(id) : nil)
            if App.shared.refreshing.value.contains(id) { header.spinner.startAnimating() } else { header.spinner.stopAnimating() }
        }
        list.configureRow = { [weak self] row, id, tag in
            guard let subscription = App.shared.library.subscription(id), let node = subscription.node(tag) else { return }
            self?.configure(row, node: node, subscription: subscription)
        }
        list.actionsForHeader = { [weak self] id in
            if self?.selecting == true { return [] }
            return [SwipeAction(symbol: "pencil", color: .systemOrange, title: L("Изменить")) { self?.rename(subscription: id) },
             SwipeAction(symbol: "arrow.clockwise", color: .systemBlue, title: L("Обновить")) { App.shared.refresh(id) },
             SwipeAction(symbol: "trash", color: .systemRed, title: L("Удалить")) { self?.confirmDelete(subscription: id) }]
        }
        list.actionsForRow = { [weak self] id, tag in
            if self?.selecting == true { return [] }
            return [SwipeAction(symbol: "pencil", color: .systemOrange, title: L("Изменить")) { self?.edit(node: tag, in: id) },
             SwipeAction(symbol: "waveform.path.ecg", color: .systemBlue, title: L("Пинг")) {
                 if let subscription = App.shared.library.subscription(id), let node = subscription.node(tag) { App.shared.ping(node: node, in: subscription) }
             },
             SwipeAction(symbol: "trash", color: .systemRed, title: L("Удалить")) { self?.confirmDelete(node: tag, in: id) }]
        }
        list.onFilter = { [weak self] id, tag in self?.pickFilter(id, tag) }
        list.onToggle = { [weak self] id in
            guard let self else { return }
            if self.selecting { self.toggleSelected(subscription: id) } else { self.toggle(id) }
        }
        list.onSelect = { [weak self] id, tag in
            guard let self else { return }
            if self.selecting { self.toggleSelected(node: tag, in: id) } else { App.shared.select(node: tag, in: id) }
        }
        list.onPing = { [weak self] id, tag in
            if self?.selecting == true { self?.toggleSelected(node: tag, in: id); return }
            guard let subscription = App.shared.library.subscription(id), let node = subscription.node(tag) else { return }
            Haptics.tap()
            App.shared.ping(node: node, in: subscription)
        }
        list.onHold = { [weak self] id, tag, point, release in
            guard let self, !self.selecting else { release(); return }
            self.hold(id, tag, at: point, release: release)
        }
    }

    /// What a row shows that does not change while the list is open: worked out
    /// once per server (names of a whole subscription, protocol facts), not on
    /// every row that scrolls into view.
    private struct RowModel {
        var name: String
        var flag: String?
        var badges: [String]
    }

    private var rowModels: [String: RowModel] = [:]
    private static let nameFont = Theme.font(17, .medium)

    private func model(_ node: ServerNode, _ subscription: Subscription) -> RowModel {
        let key = LatencyService.key(subscription.id, node.id)
        if let model = rowModels[key] { return model }
        let labels = App.shared.store.labels(for: subscription)
        for other in subscription.nodes where rowModels[LatencyService.key(subscription.id, other.id)] == nil {
            let label = labels[other.id] ?? ServerLabels.Label(text: other.name, countryCode: nil)
            rowModels[LatencyService.key(subscription.id, other.id)] = RowModel(name: label.text, flag: Theme.flag(label.countryCode), badges: other.facts.badges)
        }
        return rowModels[key] ?? RowModel(name: node.name, flag: nil, badges: node.facts.badges)
    }

    private func configure(_ row: ServerRowView, node: ServerNode, subscription: Subscription) {
        let model = model(node, subscription)
        if row.name.text != model.name { row.name.text = model.name }
        if row.name.font != Self.nameFont { row.name.font = Self.nameFont }
        let emoji = model.flag
        if row.flag.text != emoji { row.flag.text = emoji }
        row.flag.isHidden = emoji == nil
        row.globe.isHidden = emoji != nil
        row.badges.set(model.badges)
        row.setMark(selecting ? selectedNodes.contains(LatencyService.key(subscription.id, node.id)) : nil)
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
        rowModels = [:]
        let library = App.shared.library
        ordered = Prefs.arrangement.sorted(library.subscriptions.filter { !$0.nodes.isEmpty }, key: { Arrangement.subscription($0.id) }, name: { $0.name })
        let filters = Prefs.serverFilters
        let sections = ordered.map { subscription -> ServerListView.Section in
            let nodes = sortedNodes(subscription)
            let tags = Self.filterTags(subscription)
            let selected = Set(filters[String(subscription.id)] ?? []).intersection(tags)
            let shown = selected.isEmpty ? nodes : nodes.filter { selected.isSubset(of: Set($0.facts.badges)) }
            return ServerListView.Section(id: subscription.id, standalone: subscription.isStandalone, nodes: shown.map(\.id),
                                          tags: tags, selected: selected)
        }
        list.set(sections, open: expanded)
    }

    /// The tags a subscription's servers carry, most common first; a bar only
    /// when they differ (one kind of server has nothing to narrow).
    private static func filterTags(_ subscription: Subscription) -> [String] {
        guard !subscription.isStandalone, subscription.nodes.count > 1 else { return [] }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for node in subscription.nodes {
            for tag in node.facts.badges {
                if counts[tag] == nil { order.append(tag) }
                counts[tag, default: 0] += 1
            }
        }
        // A tag every server has does not narrow anything.
        let useful = order.filter { counts[$0] ?? 0 < subscription.nodes.count }
        guard !useful.isEmpty else { return [] }
        return useful.enumerated().sorted { (counts[$0.element] ?? 0, -$0.offset) > (counts[$1.element] ?? 0, -$1.offset) }.map(\.element)
    }

    private func pickFilter(_ id: Int64, _ tag: String?) {
        var filters = Prefs.serverFilters
        var selected = Set(filters[String(id)] ?? [])
        if let tag {
            if selected.contains(tag) { selected.remove(tag) } else { selected.insert(tag) }
        } else {
            selected = []
        }
        filters[String(id)] = selected.isEmpty ? nil : Array(selected)
        Prefs.serverFilters = filters
        reload()
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

    /// The items and their order are 1.5.0's.
    private func hold(_ id: Int64, _ tag: String?, at point: CGPoint, release: @escaping () -> Void) {
        guard let subscription = App.shared.library.subscription(id) else { return }
        let pinKey: String
        var items: [HoldMenuItem]
        let title: String
        if let tag, let node = subscription.node(tag) {
            title = App.shared.store.label(of: node, in: subscription).text
            pinKey = subscription.isStandalone ? Arrangement.subscription(id) : Arrangement.server(id, tag)
            items = [
                HoldMenuItem(title: L("Ссылка, QR и JSON"), symbol: "info.circle") { [weak self] in self?.inspect(tag, in: id) },
                HoldMenuItem(title: L("Проверить пинг"), symbol: "waveform.path.ecg") { App.shared.ping(node: node, in: subscription) },
                HoldMenuItem(title: L("Редактировать"), symbol: "pencil") { [weak self] in self?.edit(node: tag, in: id) },
            ]
            if subscription.isStandalone, subscription.isRemote {
                items.append(HoldMenuItem(title: L("Обновить"), symbol: "arrow.clockwise") { App.shared.refresh(id) })
            }
        } else {
            title = subscription.name
            pinKey = Arrangement.subscription(id)
            items = [
                HoldMenuItem(title: L("Проверить пинг"), symbol: "waveform.path.ecg") { App.shared.ping([subscription]) },
                HoldMenuItem(title: L("Редактировать"), symbol: "pencil") { [weak self] in self?.rename(subscription: id) },
            ]
            if subscription.isRemote {
                items.append(HoldMenuItem(title: L("Обновить"), symbol: "arrow.clockwise") { App.shared.refresh(id) })
                items.append(HoldMenuItem(title: L("Скопировать ссылку"), symbol: "doc.on.doc") { [weak self] in self?.copy(subscription.url) })
            }
        }
        let pinned = Prefs.arrangement.isPinned(pinKey)
        items.append(HoldMenuItem(title: pinned ? L("Открепить") : L("Закрепить"), symbol: pinned ? "pin.slash" : "pin") { [weak self] in self?.togglePin(pinKey) })
        items.append(HoldMenuItem(title: L("Выбрать несколько"), symbol: "checkmark.circle") { [weak self] in
            if let tag { self?.beginSelection(subscription: id, node: tag) } else { self?.beginSelection(subscription: id) }
        })
        items.append(HoldMenuItem(title: L("Удалить"), symbol: "trash", destructive: true) { [weak self] in
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
            App.shared.notice.value = L("У этого сервера нет исходной ссылки: он добавлен из файла или из подписки в формате JSON.")
            return
        }
        UIPasteboard.general.string = text
        Haptics.result(true)
    }

    private func prompt(_ title: String, value: String, apply: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = value; $0.clearButtonMode = .whileEditing }
        alert.addAction(UIAlertAction(title: L("Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("Сохранить"), style: .default) { _ in
            let text = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { apply(text) }
        })
        present(alert, animated: true)
    }

    private func rename(subscription id: Int64) {
        guard let subscription = App.shared.library.subscription(id) else { return }
        prompt(L("Название подписки"), value: subscription.name) { App.shared.rename(subscription: id, to: $0) }
    }

    /// «Редактировать»: the full form for servers it can describe; a name otherwise
    /// (groups, servers Xray runs).
    private func edit(node tag: String, in id: Int64) {
        guard let node = App.shared.library.subscription(id)?.node(tag) else { return }
        guard let draft = ServerDraft(outbound: node.outbound, name: node.name) else {
            rename(node: tag, in: id)
            return
        }
        present(ServerEditorViewController.wrapped(draft, title: L("Редактировать")) { outbound, name in
            App.shared.replace(node: tag, in: id, outbound: outbound, name: name)
        }, animated: true)
    }

    private func rename(node tag: String, in id: Int64) {
        guard let node = App.shared.library.subscription(id)?.node(tag) else { return }
        prompt(L("Название сервера"), value: node.name) { name in
            App.shared.store.update { library in
                guard var subscription = library.subscription(id), let index = subscription.nodes.firstIndex(where: { $0.id == tag }) else { return }
                subscription.nodes[index].name = name
                library.replace(subscription)
            }
        }
    }

    private func confirm(_ message: String, action: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("Удалить"), style: .destructive) { _ in action() })
        present(alert, animated: true)
    }

    private func confirmDelete(subscription id: Int64) {
        guard let subscription = App.shared.library.subscription(id) else { return }
        confirm(Lf("Удалить «%@»?", "\(subscription.name)")) { App.shared.delete(subscription: id) }
    }

    private func confirmDelete(node tag: String, in id: Int64) {
        guard let node = App.shared.library.subscription(id)?.node(tag) else { return }
        confirm(Lf("Удалить сервер «%@»?", "\(node.name)")) { App.shared.delete(node: tag, in: id) }
    }
}
