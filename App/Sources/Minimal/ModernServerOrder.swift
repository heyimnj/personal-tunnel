import TunnelCore
import UIKit

/// «Порядок серверов» of the Modern style (3.5 beta 2, the owner: the plain
/// list looked old). Subscriptions and servers are cards as in the servers
/// sheet — flag, name, protocol tags — with the pin and the drag handle at the
/// card's end. What it changes is the same `Arrangement` the Classic page edits.
final class ModernServerOrderViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let table = UITableView(frame: .zero, style: .grouped)
    private let byName = UISwitch()
    private var subscriptions: [Subscription] = []
    /// One per multi-server subscription, in the list's order, with its servers.
    private var groups: [(subscription: Subscription, nodes: [ServerNode])] = []
    private var labels: [Int64: [String: ServerLabels.Label]] = [:]
    /// The card's distance from the screen's sides.
    private static let side: CGFloat = 16

    static func wrapped() -> UIViewController {
        let navigation = UINavigationController(rootViewController: ModernServerOrderViewController())
        navigation.overrideUserInterfaceStyle = Theme.userInterfaceStyle
        return navigation
    }

    init() {
        super.init(nibName: nil, bundle: nil)
        title = L("Порядок серверов")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        view.tintColor = Theme.accent
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))

        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.dataSource = self
        table.delegate = self
        table.isEditing = true
        table.allowsSelectionDuringEditing = false
        table.sectionHeaderTopPadding = 0
        table.showsVerticalScrollIndicator = false
        table.sectionFooterHeight = 0
        // The table is as wide as the cards: the drag handles fall inside them.
        table.register(OrderCell.self, forCellReuseIdentifier: OrderCell.id)
        view.addSubview(table)
        table.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor), table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.side),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.side),
        ])
        view.clipsToBounds = true
        buildHeader()
        reload()
    }

    private func buildHeader() {
        byName.isOn = Prefs.arrangement.byName
        byName.onTintColor = Theme.accent
        byName.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            var next = Prefs.arrangement
            next.byName = self.byName.isOn
            Prefs.arrangement = next
            self.reload()
        }, for: .valueChanged)
        let row = UIStackView(.horizontal, spacing: 8, alignment: .center, [UILabel(L("Сортировать по имени"), font: Theme.font(17, .medium)), UIView(), byName])
        let card = UIView()
        card.backgroundColor = SurfaceView.card
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.addSubview(row)
        row.pin(to: card, insets: UIEdgeInsets(top: 12, left: 18, bottom: 12, right: 14))
        let note = UILabel(L("Закреплённые серверы остаются сверху. Ручной порядок сохраняется при выборе сервера. Перетаскивание включает ручной порядок."),
                           font: Theme.font(13), color: .secondaryLabel, lines: 0)
        let header = UIStackView(.vertical, spacing: 8, alignment: .fill, [card, Classic.padded(note, UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6))])
        header.isLayoutMarginsRelativeArrangement = true
        header.layoutMargins = UIEdgeInsets(top: 12, left: 0, bottom: 4, right: 0)
        let width = max(1, view.bounds.width - 2 * Self.side)
        header.frame = CGRect(x: 0, y: 0, width: width, height: 1)
        let size = header.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        header.frame.size.height = size.height
        table.tableHeaderView = header
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The header follows the table's width (the first layout comes before it is known).
        if let header = table.tableHeaderView, abs(header.frame.width - table.bounds.width) > 0.5 {
            let size = header.systemLayoutSizeFitting(CGSize(width: table.bounds.width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
            header.frame = CGRect(x: 0, y: 0, width: table.bounds.width, height: size.height)
            table.tableHeaderView = header
        }
    }

    @objc private func close() { dismiss(animated: true) }

    private func reload() {
        let arrangement = Prefs.arrangement
        let store = App.shared.store
        subscriptions = arrangement.sorted(App.shared.library.subscriptions.filter { !$0.nodes.isEmpty }, key: { Arrangement.subscription($0.id) }, name: { $0.name })
        labels = [:]
        groups = subscriptions.filter { !$0.isStandalone }.map { subscription in
            let names = store.labels(for: subscription)
            labels[subscription.id] = names
            let nodes = arrangement.sorted(subscription.nodes, key: { Arrangement.server(subscription.id, $0.id) }, name: { names[$0.id]?.text ?? $0.name })
            return (subscription, nodes)
        }
        if byName.isOn != arrangement.byName { byName.setOn(arrangement.byName, animated: true) }
        table.reloadData()
    }

    private func togglePin(_ key: String) {
        Haptics.selection()
        var next = Prefs.arrangement
        next.togglePin(key)
        Prefs.arrangement = next
        reload()
    }

    // MARK: Table

    func numberOfSections(in _: UITableView) -> Int { 1 + groups.count }

    func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? subscriptions.count : groups[section - 1].nodes.count
    }

    func tableView(_: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        indexPath.section == 0 ? 60 : 71
    }

    func tableView(_: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let text = section == 0 ? L("Подписки") : groups[section - 1].subscription.name
        let label = UILabel(text, font: Theme.font(15, .semibold), color: .secondaryLabel)
        label.lineBreakMode = .byTruncatingTail
        return Classic.padded(label, UIEdgeInsets(top: 18, left: 6, bottom: 6, right: 6))
    }

    func tableView(_: UITableView, heightForHeaderInSection _: Int) -> CGFloat { 48 }
    func tableView(_: UITableView, heightForFooterInSection _: Int) -> CGFloat { .leastNonzeroMagnitude }
    func tableView(_: UITableView, viewForFooterInSection _: Int) -> UIView? { nil }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: OrderCell.id, for: indexPath) as! OrderCell
        let key: String
        if indexPath.section == 0 {
            let subscription = subscriptions[indexPath.row]
            key = Arrangement.subscription(subscription.id)
            if subscription.isStandalone, let node = subscription.nodes.first {
                let label = App.shared.store.label(of: node, in: subscription)
                cell.show(name: label.text, flag: Theme.flag(label.countryCode), symbol: nil, detail: nil, badges: node.facts.badges)
            } else {
                cell.show(name: subscription.name, flag: nil, symbol: "folder", detail: Format.plural(subscription.nodes.count, L("сервер"), L("сервера"), L("серверов")), badges: [])
            }
        } else {
            let group = groups[indexPath.section - 1]
            let node = group.nodes[indexPath.row]
            key = Arrangement.server(group.subscription.id, node.id)
            let label = labels[group.subscription.id]?[node.id] ?? ServerLabels.Label(text: node.name, countryCode: nil)
            cell.show(name: label.text, flag: Theme.flag(label.countryCode), symbol: nil, detail: nil, badges: node.facts.badges)
        }
        cell.setPinned(Prefs.arrangement.isPinned(key)) { [weak self] in self?.togglePin(key) }
        return cell
    }

    func tableView(_: UITableView, editingStyleForRowAt _: IndexPath) -> UITableViewCell.EditingStyle { .none }
    func tableView(_: UITableView, shouldIndentWhileEditingRowAt _: IndexPath) -> Bool { false }
    func tableView(_: UITableView, canMoveRowAt _: IndexPath) -> Bool { true }

    func tableView(_: UITableView, targetIndexPathForMoveFromRowAt source: IndexPath, toProposedIndexPath proposed: IndexPath) -> IndexPath {
        proposed.section == source.section ? proposed : source
    }

    func tableView(_: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        var keys: [String]
        if source.section == 0 {
            keys = subscriptions.map { Arrangement.subscription($0.id) }
        } else {
            let group = groups[source.section - 1]
            keys = group.nodes.map { Arrangement.server(group.subscription.id, $0.id) }
        }
        let old = keys
        let moved = keys.remove(at: source.row)
        keys.insert(moved, at: destination.row)
        var next = Prefs.arrangement
        next.setManualOrder(keys, replacing: old)
        Prefs.arrangement = next
        // The order set by hand is what the servers sheet shows now.
        Prefs.sortByLatency = false
        Prefs.sortByRecent = false
        Haptics.selection()
        // After the drop has settled: a reload during it cuts the motion short.
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }
}

/// One card of the order page: what the servers sheet shows of a server (flag,
/// name, tags) or of a subscription (its name and size), the pin and the handle.
private final class OrderCell: UITableViewCell {
    static let id = "order"
    private let card = UIView()
    private let flag = UILabel(font: .systemFont(ofSize: 22))
    private let icon = UIImageView()
    private let name = UILabel(font: Theme.font(17, .medium))
    private let detail = UILabel(font: Theme.font(13), color: .secondaryLabel)
    private let badges = BadgeRow()
    private let pin = UIButton(type: .system)
    private var onPin: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        // The card lies under the whole row, the drag handle included; rows keep
        // a small gap between their cards.
        let back = UIView()
        card.backgroundColor = SurfaceView.card
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        back.addSubview(card)
        backgroundView = back
        icon.tintColor = Theme.accent
        icon.contentMode = .center
        flag.textAlignment = .center
        let leading = UIView()
        for view in [flag, icon] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            leading.addSubview(view)
            NSLayoutConstraint.activate([view.centerXAnchor.constraint(equalTo: leading.centerXAnchor), view.centerYAnchor.constraint(equalTo: leading.centerYAnchor)])
        }
        leading.widthAnchor.constraint(equalToConstant: 30).isActive = true
        name.lineBreakMode = .byTruncatingTail
        let text = UIStackView(.vertical, spacing: 5, alignment: .fill, [name, detail, badges])
        let row = UIStackView(.horizontal, spacing: 12, alignment: .center, [leading, text])
        contentView.addSubview(row)
        row.pin(to: contentView, insets: UIEdgeInsets(top: 4, left: 14, bottom: 4, right: 0))
        badges.heightAnchor.constraint(equalToConstant: 17).isActive = true
        pin.tintColor = Theme.accent
        pin.frame = CGRect(x: 0, y: 0, width: 40, height: 44)
        pin.addAction(UIAction { [weak self] _ in self?.onPin?() }, for: .touchUpInside)
        editingAccessoryView = pin
        showsReorderControl = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frame = bounds.insetBy(dx: 0, dy: 4)
        if card.frame != frame { card.frame = frame }
    }

    func show(name text: String, flag emoji: String?, symbol: String?, detail line: String?, badges tags: [String]) {
        name.text = text
        flag.text = emoji
        flag.isHidden = emoji == nil
        let glyph = symbol ?? (emoji == nil ? "globe" : nil)
        icon.image = glyph.flatMap { UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)) }
        icon.isHidden = glyph == nil
        icon.tintColor = symbol == nil ? .secondaryLabel : Theme.accent
        detail.text = line
        detail.isHidden = line == nil
        badges.set(tags)
        badges.isHidden = tags.isEmpty
    }

    func setPinned(_ pinned: Bool, action: @escaping () -> Void) {
        onPin = action
        pin.setImage(UIImage(systemName: pinned ? "pin.fill" : "pin", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)), for: .normal)
        pin.tintColor = pinned ? Theme.accent : .tertiaryLabel
        pin.accessibilityLabel = pinned ? L("Открепить") : L("Закрепить")
    }
}
