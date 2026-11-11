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

private enum ServerItem: Hashable {
    case header(Int64)
    case node(Int64, String)
}

private final class SubscriptionCell: UICollectionViewListCell {
    let title = UILabel(font: Theme.font(17, .semibold))
    let pin = UIImageView(image: UIImage(systemName: "pin.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
    let count = UILabel(font: Theme.font(13, .medium), color: .secondaryLabel)
    let chevron = UIImageView(image: UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
    let spinner = UIActivityIndicatorView(style: .medium)
    private var isOpen = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        pin.tintColor = Theme.accent
        pin.setContentHuggingPriority(.required, for: .horizontal)
        chevron.tintColor = .secondaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        count.textAlignment = .center
        count.layer.cornerRadius = 12
        count.layer.masksToBounds = true
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.hidesWhenStopped = true
        let row = UIStackView(.horizontal, spacing: 8, alignment: .center, [title, pin, UIView(), spinner, count, chevron])
        row.setCustomSpacing(12, after: count)
        contentView.addSubview(row)
        row.pin(to: contentView, insets: UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20))
        NSLayoutConstraint.activate([
            contentView.heightAnchor.constraint(equalToConstant: 66).withPriority(999),
            count.heightAnchor.constraint(equalToConstant: 24), count.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func set(open: Bool, animated: Bool) {
        isOpen = open
        var background = UIBackgroundConfiguration.clear()
        background.cornerRadius = 24
        background.backgroundColor = open ? .clear : .secondarySystemGroupedBackground
        backgroundConfiguration = background
        let update = {
            self.chevron.transform = open ? CGAffineTransform(rotationAngle: .pi) : .identity
            self.count.backgroundColor = open ? Theme.accent.withAlphaComponent(0.14) : UIColor.label.withAlphaComponent(0.06)
            self.count.textColor = open ? Theme.accent : .secondaryLabel
        }
        if animated { UIView.animate(withDuration: 0.28, animations: update) } else { update() }
    }
}

private final class NodeCell: UICollectionViewListCell {
    let flag = UILabel(font: .systemFont(ofSize: 22))
    let globe = UIImageView(image: UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20)))
    let name = UILabel(font: Theme.font(17, .medium))
    let badges = BadgeRow()
    let check = UIImageView(image: UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)))
    let ping = UILabel(font: Theme.font(13), color: .secondaryLabel)
    let spinner = UIActivityIndicatorView(style: .medium)
    let pingButton = TapControl()

    override init(frame: CGRect) {
        super.init(frame: frame)
        globe.tintColor = .label
        check.tintColor = Theme.accent
        check.setContentHuggingPriority(.required, for: .horizontal)
        spinner.color = Theme.accent
        spinner.hidesWhenStopped = true
        ping.textAlignment = .right
        name.lineBreakMode = .byTruncatingTail
        let leading = UIView()
        for view in [flag, globe] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            leading.addSubview(view)
            NSLayoutConstraint.activate([view.centerXAnchor.constraint(equalTo: leading.centerXAnchor), view.centerYAnchor.constraint(equalTo: leading.centerYAnchor)])
        }
        leading.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let titleRow = UIStackView(.horizontal, spacing: 6, alignment: .center, [name, check, UIView()])
        let text = UIStackView(.vertical, spacing: 5, alignment: .fill, [titleRow, badges])
        let trailing = UIStackView(.horizontal, spacing: 0, alignment: .center, [ping, spinner])
        trailing.isUserInteractionEnabled = false
        pingButton.addSubview(trailing)
        trailing.pin(to: pingButton, insets: UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 0))
        pingButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        pingButton.setContentHuggingPriority(.required, for: .horizontal)
        pingButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(.horizontal, spacing: 12, alignment: .center, [leading, text, pingButton])
        contentView.addSubview(row)
        row.pin(to: contentView, insets: UIEdgeInsets(top: 3, left: 22, bottom: 3, right: 24))
        contentView.heightAnchor.constraint(equalToConstant: 69).withPriority(999).isActive = true
        NSLayoutConstraint.activate([pingButton.heightAnchor.constraint(equalTo: row.heightAnchor)])
        var background = UIBackgroundConfiguration.clear()
        background.cornerRadius = 14
        background.backgroundColor = .secondarySystemGroupedBackground
        background.backgroundInsets = NSDirectionalEdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)
        backgroundConfiguration = background
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }
}

extension NSLayoutConstraint {
    func withPriority(_ value: Float) -> NSLayoutConstraint {
        priority = UILayoutPriority(value)
        return self
    }
}

/// Rounded backdrop of an expanded subscription.
private final class ContainerBackground: UICollectionReusableView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 0.16, alpha: 1) : UIColor(red: 0.91, green: 0.91, blue: 0.93, alpha: 1)
        }
        layer.cornerRadius = 24
        layer.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }
}

/// The «Серверы» sheet: subscriptions as cards that open into their servers.
final class MinimalServersViewController: UIViewController, UICollectionViewDelegate {
    private var collection: UICollectionView!
    private var source: UICollectionViewDiffableDataSource<Int64, ServerItem>!
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
        App.shared.store.library.observe(self) { [weak self] _ in self?.reload(animated: false) }
        App.shared.latency.changed.observe(self, fireNow: false) { [weak self] keys in self?.refresh(keys) }
        App.shared.latency.progress.observe(self) { [weak self] in self?.show($0) }
        App.shared.refreshing.observe(self, fireNow: false) { [weak self] _ in self?.reconfigureHeaders() }
        App.shared.tunnel.state.observe(self, fireNow: false) { [weak self] _ in self?.reconfigureAll() }
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
        bar.backgroundColor = UIColor.systemBackground
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
        collection.contentInset.top = 70
        collection.verticalScrollIndicatorInsets.top = 70
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
                self?.reload(animated: true)
            },
            UIAction(title: "Сортировать по задержке", image: UIImage(systemName: "speedometer"), state: Prefs.sortByLatency ? .on : .off) { [weak self] _ in
                Prefs.sortByLatency.toggle()
                self?.reload(animated: true)
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
                self?.reload(animated: true)
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
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.showsSeparators = false
            configuration.backgroundColor = .clear
            configuration.trailingSwipeActionsConfigurationProvider = { [weak self] path in self?.swipeActions(path) }
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            let open = self.map { $0.ordered.indices.contains(index) && $0.isOpen($0.ordered[index]) } ?? false
            section.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 16, bottom: open ? 13 : 5, trailing: 16)
            if open {
                let background = NSCollectionLayoutDecorationItem.background(elementKind: "container")
                background.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16)
                section.decorationItems = [background]
            }
            return section
        }
        layout.register(ContainerBackground.self, forDecorationViewOfKind: "container")
        collection = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.delegate = self
        collection.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(collection)
        collection.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(held(_:))))

        let header = UICollectionView.CellRegistration<SubscriptionCell, ServerItem> { [weak self] cell, _, item in
            guard let self, case let .header(id) = item, let subscription = App.shared.library.subscription(id) else { return }
            cell.title.text = subscription.name
            cell.title.font = Theme.font(17, .semibold)
            cell.count.text = "\(subscription.nodes.count)"
            cell.pin.isHidden = !Prefs.arrangement.isPinned(Arrangement.subscription(id))
            cell.set(open: self.expanded.contains(id), animated: false)
            if App.shared.refreshing.value.contains(id) { cell.spinner.startAnimating() } else { cell.spinner.stopAnimating() }
        }
        let node = UICollectionView.CellRegistration<NodeCell, ServerItem> { [weak self] cell, _, item in
            guard let self, case let .node(id, tag) = item, let subscription = App.shared.library.subscription(id), let node = subscription.node(tag) else { return }
            self.configure(cell, node: node, subscription: subscription)
        }
        source = UICollectionViewDiffableDataSource(collectionView: collection) { collection, path, item in
            switch item {
            case .header: return collection.dequeueConfiguredReusableCell(using: header, for: path, item: item)
            case .node: return collection.dequeueConfiguredReusableCell(using: node, for: path, item: item)
            }
        }
    }

    private func isOpen(_ subscription: Subscription) -> Bool { !subscription.isStandalone && expanded.contains(subscription.id) }

    private func configure(_ cell: NodeCell, node: ServerNode, subscription: Subscription) {
        let label = App.shared.store.label(of: node, in: subscription)
        cell.name.text = label.text
        cell.name.font = Theme.font(17, .medium)
        let emoji = Theme.flag(label.countryCode)
        cell.flag.text = emoji
        cell.flag.isHidden = emoji == nil
        cell.globe.isHidden = emoji != nil
        cell.badges.set(node.facts.badges)
        let library = App.shared.library
        cell.check.isHidden = !(library.activeSubscription?.id == subscription.id && library.selectedNodeID(in: subscription) == node.id)
        let id = subscription.id, tag = node.id
        cell.pingButton.onTap = {
            guard let subscription = App.shared.library.subscription(id), let node = subscription.node(tag) else { return }
            Haptics.tap()
            App.shared.ping(node: node, in: subscription)
        }
        if App.shared.latency.isTesting(id, tag) {
            cell.ping.text = nil
            cell.spinner.startAnimating()
        } else {
            cell.spinner.stopAnimating()
            switch App.shared.latency.entry(id, tag)?.result {
            case let .delay(value)?:
                cell.ping.text = "\(value) ms"
                cell.ping.textColor = .label
            case let .failed(reason)?:
                cell.ping.text = reason.title
                cell.ping.textColor = .secondaryLabel
            case nil:
                cell.ping.text = "—"
                cell.ping.textColor = .tertiaryLabel
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

    private func reload(animated: Bool) {
        let library = App.shared.library
        ordered = Prefs.arrangement.sorted(library.subscriptions.filter { !$0.nodes.isEmpty }, key: { Arrangement.subscription($0.id) }, name: { $0.name })
        var snapshot = NSDiffableDataSourceSnapshot<Int64, ServerItem>()
        for subscription in ordered {
            snapshot.appendSections([subscription.id])
            if subscription.isStandalone, let node = subscription.nodes.first {
                snapshot.appendItems([.node(subscription.id, node.id)], toSection: subscription.id)
            } else {
                snapshot.appendItems([.header(subscription.id)], toSection: subscription.id)
                if expanded.contains(subscription.id) {
                    snapshot.appendItems(sortedNodes(subscription).map { .node(subscription.id, $0.id) }, toSection: subscription.id)
                }
            }
        }
        let known = Set(source.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter(known.contains))
        source.apply(snapshot, animatingDifferences: animated)
    }

    private func reconfigureHeaders() {
        var snapshot = source.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { if case .header = $0 { return true }; return false })
        source.apply(snapshot, animatingDifferences: false)
    }

    private func reconfigureAll() {
        var snapshot = source.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        source.apply(snapshot, animatingDifferences: false)
    }

    /// A latency batch touches only the rows it changed.
    private func refresh(_ keys: Set<String>) {
        if Prefs.sortByLatency, !App.shared.latency.progress.value.running {
            reload(animated: true)
            return
        }
        var snapshot = source.snapshot()
        let changed = snapshot.itemIdentifiers.filter { item in
            if case let .node(id, tag) = item { return keys.contains(LatencyService.key(id, tag)) }
            return false
        }
        guard !changed.isEmpty else { return }
        snapshot.reconfigureItems(changed)
        source.apply(snapshot, animatingDifferences: false)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let item = source.itemIdentifier(for: indexPath) else { return }
        switch item {
        case let .header(id):
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            Prefs.expandedSubscriptions = expanded
            Haptics.soft(0.5)
            (collectionView.cellForItem(at: indexPath) as? SubscriptionCell)?.set(open: expanded.contains(id), animated: true)
            reload(animated: true)
        case let .node(id, tag):
            App.shared.select(node: tag, in: id)
        }
    }

    // MARK: Row actions

    private func swipeActions(_ path: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = source.itemIdentifier(for: path) else { return nil }
        func action(_ symbol: String, _ color: UIColor, _ handler: @escaping () -> Void) -> UIContextualAction {
            let action = UIContextualAction(style: .normal, title: nil) { _, _, done in handler(); done(true) }
            action.image = UIImage(systemName: symbol)
            action.backgroundColor = color
            return action
        }
        var actions: [UIContextualAction]
        switch item {
        case let .header(id):
            actions = [action("trash", .systemRed) { [weak self] in self?.confirmDelete(subscription: id) },
                       action("arrow.clockwise", Theme.accent) { App.shared.refresh(id) },
                       action("pencil", .systemOrange) { [weak self] in self?.rename(subscription: id) }]
        case let .node(id, tag):
            actions = [action("trash", .systemRed) { [weak self] in self?.confirmDelete(node: tag, in: id) },
                       action("waveform.path.ecg", Theme.accent) {
                           if let subscription = App.shared.library.subscription(id), let node = subscription.node(tag) { App.shared.ping(node: node, in: subscription) }
                       },
                       action("pencil", .systemOrange) { [weak self] in self?.rename(node: tag, in: id) }]
        }
        let configuration = UISwipeActionsConfiguration(actions: actions)
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: collection)
        guard let path = collection.indexPathForItem(at: point), let item = source.itemIdentifier(for: path) else { return }
        let cell = collection.cellForItem(at: path)
        cell?.contentView.backgroundColor = UIColor.label.withAlphaComponent(0.07)
        let clear = { cell?.contentView.backgroundColor = .clear }
        let pinKey: String
        var items: [HoldMenuItem]
        let title: String
        switch item {
        case let .header(id):
            guard let subscription = App.shared.library.subscription(id) else { return }
            title = subscription.name
            pinKey = Arrangement.subscription(id)
            items = [
                HoldMenuItem(title: "Проверить пинг", symbol: "waveform.path.ecg") { App.shared.ping([subscription]) },
                HoldMenuItem(title: "Редактировать", symbol: "pencil") { [weak self] in self?.rename(subscription: id) },
                HoldMenuItem(title: "Обновить", symbol: "arrow.clockwise") { App.shared.refresh(id) },
                HoldMenuItem(title: "Скопировать ссылку", symbol: "doc.on.doc") { [weak self] in self?.copy(subscription.url) },
            ]
            items.append(HoldMenuItem(title: Prefs.arrangement.isPinned(pinKey) ? "Открепить" : "Закрепить", symbol: "pin") { [weak self] in self?.togglePin(pinKey) })
            items.append(HoldMenuItem(title: "Удалить", symbol: "trash", destructive: true) { [weak self] in self?.confirmDelete(subscription: id) })
        case let .node(id, tag):
            guard let subscription = App.shared.library.subscription(id), let node = subscription.node(tag) else { return }
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
            items.append(HoldMenuItem(title: Prefs.arrangement.isPinned(pinKey) ? "Открепить" : "Закрепить", symbol: "pin") { [weak self] in self?.togglePin(pinKey) })
            items.append(HoldMenuItem(title: "Удалить", symbol: "trash", destructive: true) { [weak self] in self?.confirmDelete(node: tag, in: id) })
        }
        HoldMenuView.show(in: view, at: gesture.location(in: view), title: title, items: items, onDismiss: clear)
    }

    private func togglePin(_ key: String) {
        var next = Prefs.arrangement
        next.togglePin(key)
        Prefs.arrangement = next
        reload(animated: true)
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
