import TunnelCore
import UIKit

/// «Порядок серверов» of the Modern style. 3.5 beta 4 (the owner: beta 2's page
/// was a table in edit mode — a line ran down beside the handles and the pins sat
/// unevenly): a list of cards as in the servers sheet, no lines anywhere.
/// Subscriptions first; then each subscription folds open into its servers.
/// A card is moved by its handle (or a long press on it) and lifts while it moves.
/// What it changes is the same `Arrangement` the Classic page edits.
final class ModernServerOrderViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let layout = UICollectionViewFlowLayout()
    private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private var subscriptions: [Subscription] = []
    /// One per multi-server subscription, in the list's order, with its servers.
    private var groups: [(subscription: Subscription, nodes: [ServerNode])] = []
    private var labels: [Int64: [String: ServerLabels.Label]] = [:]
    /// Subscriptions folded open on this page.
    private var unfolded = Set<Int64>()
    /// The card being moved, and where the finger took it.
    private var moving: IndexPath?
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

        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 8, left: Self.side, bottom: 6, right: Self.side)
        collection.backgroundColor = .clear
        collection.alwaysBounceVertical = true
        collection.dataSource = self
        collection.delegate = self
        collection.register(OrderCell.self, forCellWithReuseIdentifier: OrderCell.id)
        collection.register(TopHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: TopHeader.id)
        collection.register(GroupHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: GroupHeader.id)
        collection.contentInset.bottom = 24
        view.addSubview(collection)
        collection.pin(to: view)
        // A long press anywhere on a card moves it too.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        collection.addGestureRecognizer(hold)
        reload()
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
        collection.reloadData()
    }

    private func key(_ path: IndexPath) -> String {
        if path.section == 0 { return Arrangement.subscription(subscriptions[path.item].id) }
        let group = groups[path.section - 1]
        return Arrangement.server(group.subscription.id, group.nodes[path.item].id)
    }

    private func togglePin(_ key: String) {
        Haptics.selection()
        var next = Prefs.arrangement
        next.togglePin(key)
        Prefs.arrangement = next
        // Pinned cards go to the top of their list: the order changes.
        UIView.transition(with: collection, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) { self.reload() }
    }

    private func fold(_ section: Int) {
        guard section > 0, groups.indices.contains(section - 1) else { return }
        let id = groups[section - 1].subscription.id
        let open = !unfolded.contains(id)
        if open { unfolded.insert(id) } else { unfolded.remove(id) }
        Haptics.item()
        let paths = groups[section - 1].nodes.indices.map { IndexPath(item: $0, section: section) }
        if open {
            collection.performBatchUpdates { collection.insertItems(at: paths) }
        } else {
            collapse(section, paths)
        }
        (collection.supplementaryView(forElementKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section)) as? GroupHeader)?.setOpen(open, animated: true)
    }

    /// 3.5 (the owner's video: closing a subscription went in jerks). The flow
    /// layout's own animation of a deletion moved the headers below from where it
    /// guessed they had been (off screen, under dozens of servers) and back. Now
    /// the change is made at once, and drawn over: the servers that were on screen
    /// fade as a picture, and what lies below the head rises into its place.
    private func collapse(_ section: Int, _ paths: [IndexPath]) {
        let kind = UICollectionView.elementKindSectionHeader
        let headPath = IndexPath(item: 0, section: section)
        guard !UIAccessibility.isReduceMotionEnabled, view.window != nil,
              let head = collection.supplementaryView(forElementKind: kind, at: headPath) else {
            collection.performBatchUpdates { collection.deleteItems(at: paths) }
            return
        }
        let bounds = collection.bounds
        let oldTop = head.frame.maxY - bounds.minY
        let below = CGRect(x: bounds.minX, y: max(head.frame.maxY, bounds.minY), width: bounds.width, height: max(0, bounds.maxY - max(head.frame.maxY, bounds.minY)))
        let picture = below.height > 1 ? collection.resizableSnapshotView(from: below, afterScreenUpdates: false, withCapInsets: .zero) : nil
        UIView.performWithoutAnimation {
            collection.performBatchUpdates { collection.deleteItems(at: paths) }
            collection.layoutIfNeeded()
        }
        guard let newHead = collection.supplementaryView(forElementKind: kind, at: headPath) else { return }
        let newBounds = collection.bounds
        let newTop = newHead.frame.maxY - newBounds.minY
        // The list may have been pulled up to its new end: everything moves by as much.
        let shift = oldTop - newTop
        let rise = min(max(0, newBounds.height - newTop), 240)
        var moved: [UIView] = []
        var views: [UIView] = collection.visibleCells
        views += collection.visibleSupplementaryViews(ofKind: kind) as [UIView]
        for item in views {
            if item.frame.minY >= newHead.frame.maxY - 0.5 {
                item.transform = CGAffineTransform(translationX: 0, y: shift + rise)
                item.alpha = 0
            } else {
                item.transform = CGAffineTransform(translationX: 0, y: shift)
            }
            moved.append(item)
        }
        if let picture {
            picture.frame = collection.convert(below, to: view)
            picture.isUserInteractionEnabled = false
            view.addSubview(picture)
        }
        let travel = shift
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            for item in moved {
                item.transform = .identity
                item.alpha = 1
            }
            picture?.frame.origin.y += -travel - 24
        }
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut]) {
            picture?.alpha = 0
        } completion: { _ in
            picture?.removeFromSuperview()
        }
    }

    // MARK: Moving

    @objc private func held(_ hold: UILongPressGestureRecognizer) {
        let point = hold.location(in: collection)
        switch hold.state {
        case .began:
            guard let path = collection.indexPathForItem(at: point) else { return }
            begin(path)
        case .changed:
            follow(point)
        case .ended:
            finish(cancelled: false)
        default:
            finish(cancelled: true)
        }
    }

    /// The handle's own drag: it starts at once.
    fileprivate func handleDragged(_ cell: OrderCell, _ pan: UILongPressGestureRecognizer) {
        let point = pan.location(in: collection)
        switch pan.state {
        case .began:
            guard let path = collection.indexPath(for: cell) else { return }
            begin(path)
        case .changed:
            follow(point)
        case .ended:
            finish(cancelled: false)
        default:
            finish(cancelled: true)
        }
    }

    private func begin(_ path: IndexPath) {
        guard moving == nil, collection.beginInteractiveMovementForItem(at: path) else { return }
        moving = path
        Haptics.tap()
        (collection.cellForItem(at: path) as? OrderCell)?.setLifted(true)
    }

    private func follow(_ point: CGPoint) {
        guard moving != nil else { return }
        // Up and down only.
        collection.updateInteractiveMovementTargetPosition(CGPoint(x: collection.bounds.midX, y: point.y))
    }

    private func finish(cancelled: Bool) {
        guard let path = moving else { return }
        moving = nil
        if cancelled { collection.cancelInteractiveMovement() } else { collection.endInteractiveMovement() }
        for cell in collection.visibleCells { (cell as? OrderCell)?.setLifted(false) }
        // A subscription moved: its servers' part follows it, once the drop has settled.
        if !cancelled, path.section == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.moving == nil else { return }
                UIView.transition(with: self.collection, duration: 0.2, options: [.transitionCrossDissolve]) { self.reload() }
            }
        }
    }

    func collectionView(_: UICollectionView, canMoveItemAt _: IndexPath) -> Bool { true }

    func collectionView(_: UICollectionView, targetIndexPathForMoveOfItemFromOriginalIndexPath original: IndexPath,
                        atCurrentIndexPath current: IndexPath, toProposedIndexPath proposed: IndexPath) -> IndexPath {
        proposed.section == original.section ? proposed : current
    }

    func collectionView(_: UICollectionView, moveItemAt source: IndexPath, to destination: IndexPath) {
        guard source.section == destination.section else { return }
        var keys: [String]
        if source.section == 0 {
            keys = subscriptions.map { Arrangement.subscription($0.id) }
            let moved = subscriptions.remove(at: source.item)
            subscriptions.insert(moved, at: destination.item)
        } else {
            let index = source.section - 1
            keys = groups[index].nodes.map { Arrangement.server(groups[index].subscription.id, $0.id) }
            let moved = groups[index].nodes.remove(at: source.item)
            groups[index].nodes.insert(moved, at: destination.item)
        }
        let old = keys
        let movedKey = keys.remove(at: source.item)
        keys.insert(movedKey, at: destination.item)
        var next = Prefs.arrangement
        next.setManualOrder(keys, replacing: old)
        Prefs.arrangement = next
        // The order set by hand is what the servers sheet shows now.
        Prefs.sortByLatency = false
        Prefs.sortByRecent = false
        Haptics.selection()
    }

    // MARK: Data

    func numberOfSections(in _: UICollectionView) -> Int { 1 + groups.count }

    func collectionView(_: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        if section == 0 { return subscriptions.count }
        let group = groups[section - 1]
        return unfolded.contains(group.subscription.id) ? group.nodes.count : 0
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: OrderCell.id, for: indexPath) as! OrderCell
        cell.owner = self
        if indexPath.section == 0 {
            let subscription = subscriptions[indexPath.item]
            if subscription.isStandalone, let node = subscription.nodes.first {
                let label = App.shared.store.label(of: node, in: subscription)
                cell.show(name: label.text, flag: Theme.flag(label.countryCode), count: nil, badges: node.facts.badges)
            } else {
                cell.show(name: subscription.name, flag: nil, count: subscription.nodes.count, badges: [])
            }
        } else {
            let group = groups[indexPath.section - 1]
            let node = group.nodes[indexPath.item]
            let label = labels[group.subscription.id]?[node.id] ?? ServerLabels.Label(text: node.name, countryCode: nil)
            cell.show(name: label.text, flag: Theme.flag(label.countryCode), count: nil, badges: node.facts.badges)
        }
        let pinKey = self.key(indexPath)
        cell.setPinned(Prefs.arrangement.isPinned(pinKey)) { [weak self] in self?.togglePin(pinKey) }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        if indexPath.section == 0 {
            let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: TopHeader.id, for: indexPath) as! TopHeader
            header.onByName = { [weak self] on in
                var next = Prefs.arrangement
                next.byName = on
                Prefs.arrangement = next
                self?.reload()
            }
            header.byName.isOn = Prefs.arrangement.byName
            return header
        }
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: GroupHeader.id, for: indexPath) as! GroupHeader
        let group = groups[indexPath.section - 1]
        header.show(name: group.subscription.name, count: group.nodes.count, open: unfolded.contains(group.subscription.id))
        header.onTap = { [weak self, weak header] in
            guard let self, let header, let section = self.collection.indexPath(forSupplementaryView: header)?.section else { return }
            self.fold(section)
        }
        return header
    }

    func collectionView(_ collectionView: UICollectionView, layout _: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = collectionView.bounds.width - 2 * Self.side
        let plain = indexPath.section == 0 && !subscriptions[indexPath.item].isStandalone
        return CGSize(width: max(1, width), height: plain ? 60 : 68)
    }

    func collectionView(_ collectionView: UICollectionView, layout _: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize {
        if section == 0 { return CGSize(width: collectionView.bounds.width, height: TopHeader.height(for: collectionView.bounds.width)) }
        return CGSize(width: collectionView.bounds.width, height: section == 1 ? 102 : 74)
    }

    func collectionView(_: UICollectionView, layout _: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        guard section > 0 else { return layout.sectionInset }
        let open = unfolded.contains(groups[section - 1].subscription.id)
        return UIEdgeInsets(top: open ? 8 : 0, left: Self.side, bottom: open ? 6 : 0, right: Self.side)
    }
}

// MARK: - Views

/// The switch «Сортировать по имени» on a card, the note and the first caption.
private final class TopHeader: UICollectionReusableView {
    static let id = "top"
    let byName = UISwitch()
    var onByName: ((Bool) -> Void)?
    private static let note = L("Закреплённые серверы остаются сверху. Ручной порядок сохраняется при выборе сервера. Перетаскивание включает ручной порядок.")

    override init(frame: CGRect) {
        super.init(frame: frame)
        byName.onTintColor = Theme.accent
        byName.addTactileToggle()
        byName.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onByName?(self.byName.isOn)
        }, for: .valueChanged)
        let row = UIStackView(.horizontal, spacing: 8, alignment: .center, [UILabel(L("Сортировать по имени"), font: Theme.font(17, .medium)), UIView(), byName])
        let card = UIView()
        card.backgroundColor = SurfaceView.card
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.addSubview(row)
        row.pin(to: card, insets: UIEdgeInsets(top: 12, left: 18, bottom: 12, right: 16))
        let note = UILabel(Self.note, font: Theme.font(13), color: .secondaryLabel, lines: 0)
        let caption = OrderCaption(L("Подписки"))
        let stack = UIStackView(.vertical, spacing: 8, alignment: .fill, [card, Classic.padded(note, UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)), caption])
        stack.setCustomSpacing(22, after: stack.arrangedSubviews[1])
        addSubview(stack)
        stack.pin(to: self, insets: UIEdgeInsets(top: 12, left: 16, bottom: 0, right: 16))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    /// The card (55), the note's lines, the caption (20) and the gaps.
    static func height(for width: CGFloat) -> CGFloat {
        let font = Theme.font(13)
        let text = (note as NSString).boundingRect(with: CGSize(width: width - 32 - 12, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin], attributes: [.font: font], context: nil)
        return 12 + 55 + 8 + ceil(text.height) + 22 + 20
    }
}

/// A small heading over a part of the list.
private final class OrderCaption: UIView {
    init(_ text: String) {
        super.init(frame: .zero)
        let label = UILabel(text.uppercased(), font: Theme.font(13, .semibold), color: .secondaryLabel)
        addSubview(label)
        label.pin(to: self, insets: UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6))
        heightAnchor.constraint(equalToConstant: 20).isActive = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }
}

/// A subscription's head: its name and size on a card that folds its servers open.
private final class GroupHeader: UICollectionReusableView {
    static let id = "group"
    var onTap: (() -> Void)?
    private let caption = OrderCaption(L("Серверы"))
    private let tap = TapControl()
    private let name = UILabel(font: Theme.font(17, .semibold))
    private let count = UILabel(font: Theme.font(13, .medium), color: .secondaryLabel)
    private let countPill = UIView()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        tap.backgroundColor = SurfaceView.card
        tap.layer.cornerRadius = 22
        tap.layer.cornerCurve = .continuous
        tap.pressScale = 0.98
        tap.onTap = { [weak self] in self?.onTap?() }
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.textAlignment = .center
        countPill.backgroundColor = UIColor.label.withAlphaComponent(0.06)
        countPill.layer.cornerRadius = 12
        countPill.isUserInteractionEnabled = false
        chevron.tintColor = .secondaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(.horizontal, spacing: 10, alignment: .center, [name, UIView(), count, chevron])
        row.setCustomSpacing(12, after: count)
        row.isUserInteractionEnabled = false
        tap.addSubview(countPill)
        tap.addSubview(row)
        row.pin(to: tap, insets: UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20))
        countPill.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            count.heightAnchor.constraint(equalToConstant: 24), count.widthAnchor.constraint(greaterThanOrEqualToConstant: 38),
            countPill.leadingAnchor.constraint(equalTo: count.leadingAnchor), countPill.trailingAnchor.constraint(equalTo: count.trailingAnchor),
            countPill.topAnchor.constraint(equalTo: count.topAnchor), countPill.bottomAnchor.constraint(equalTo: count.bottomAnchor),
        ])
        tap.isAccessibilityElement = true
        tap.accessibilityTraits = .button
        for item in [caption, tap] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        NSLayoutConstraint.activate([
            tap.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), tap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            tap.bottomAnchor.constraint(equalTo: bottomAnchor), tap.heightAnchor.constraint(equalToConstant: 60),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            caption.bottomAnchor.constraint(equalTo: tap.topAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The «Серверы» caption only over the first subscription (its header is taller).
        caption.isHidden = bounds.height < 90
    }

    func show(name text: String, count number: Int, open: Bool) {
        name.text = text
        count.text = "\(number)"
        tap.accessibilityLabel = text
        tap.accessibilityValue = Format.plural(number, L("сервер"), L("сервера"), L("серверов"))
        setOpen(open, animated: false)
    }

    func setOpen(_ open: Bool, animated: Bool) {
        let apply = {
            self.chevron.transform = open ? CGAffineTransform(rotationAngle: .pi - 0.0001) : .identity
            self.countPill.backgroundColor = open ? Theme.accent.withAlphaComponent(0.14) : UIColor.label.withAlphaComponent(0.06)
            self.count.textColor = open ? Theme.accent : .secondaryLabel
        }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.beginFromCurrentState], animations: apply)
        } else {
            apply()
        }
    }
}

/// One card: a server (flag, name, tags) or a subscription (its name and size),
/// the pin and the handle.
private final class OrderCell: UICollectionViewCell {
    static let id = "order"
    weak var owner: ModernServerOrderViewController?
    private let card = UIView()
    private let flag = UILabel(font: .systemFont(ofSize: 22))
    /// 3.6.7 (the owner): a server whose country is unknown (was the globe); a dashed pin since 3.6.10.
    private let globe = UIImageView(image: MinimalIcons.unplaced(24))
    private let name = UILabel(font: Theme.font(17, .medium))
    private let count = UILabel(font: Theme.font(13, .medium), color: .secondaryLabel)
    private let countPill = UIView()
    private let badges = BadgeRow()
    private let pin = UIButton(type: .system)
    private let pinBack = UIView()
    private let handle = UIImageView(image: UIImage(systemName: "line.3.horizontal", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)))
    private let handleArea = UIView()
    private let leading = UIView()
    private var onPin: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.backgroundColor = SurfaceView.card
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        contentView.addSubview(card)
        card.pin(to: contentView)

        globe.tintColor = .secondaryLabel
        flag.textAlignment = .center
        for view in [flag, globe] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            leading.addSubview(view)
            NSLayoutConstraint.activate([view.centerXAnchor.constraint(equalTo: leading.centerXAnchor), view.centerYAnchor.constraint(equalTo: leading.centerYAnchor)])
        }
        leading.widthAnchor.constraint(equalToConstant: 30).isActive = true
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badges.heightAnchor.constraint(equalToConstant: 17).isActive = true
        let text = UIStackView(.vertical, spacing: 5, alignment: .fill, [name, badges])
        count.textAlignment = .center
        countPill.backgroundColor = UIColor.label.withAlphaComponent(0.06)
        countPill.layer.cornerRadius = 12
        countPill.isUserInteractionEnabled = false

        // The pin: a round button, filled with the accent's tint when pinned.
        pinBack.layer.cornerRadius = 17
        pinBack.isUserInteractionEnabled = false
        pin.addAction(UIAction { [weak self] _ in self?.onPin?() }, for: .touchUpInside)
        handle.tintColor = .tertiaryLabel
        handle.contentMode = .center
        handleArea.isAccessibilityElement = false
        handleArea.addSubview(handle)
        handle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([handle.centerXAnchor.constraint(equalTo: handleArea.centerXAnchor), handle.centerYAnchor.constraint(equalTo: handleArea.centerYAnchor)])
        // The handle takes the finger at once.
        let drag = UILongPressGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.minimumPressDuration = 0.01
        handleArea.addGestureRecognizer(drag)

        let row = UIStackView(.horizontal, spacing: 12, alignment: .center, [leading, text, count, pinBack, handleArea])
        row.setCustomSpacing(10, after: count)
        row.setCustomSpacing(4, after: pinBack)
        card.addSubview(countPill)
        card.addSubview(row)
        pinBack.addSubview(pin)
        pin.pin(to: pinBack)
        row.pin(to: card, insets: UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 4))
        countPill.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pinBack.widthAnchor.constraint(equalToConstant: 34), pinBack.heightAnchor.constraint(equalToConstant: 34),
            handleArea.widthAnchor.constraint(equalToConstant: 44), handleArea.heightAnchor.constraint(equalTo: row.heightAnchor),
            count.heightAnchor.constraint(equalToConstant: 24), count.widthAnchor.constraint(greaterThanOrEqualToConstant: 38),
            countPill.leadingAnchor.constraint(equalTo: count.leadingAnchor), countPill.trailingAnchor.constraint(equalTo: count.trailingAnchor),
            countPill.topAnchor.constraint(equalTo: count.topAnchor), countPill.bottomAnchor.constraint(equalTo: count.bottomAnchor),
        ])
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 6)
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    @objc private func dragged(_ drag: UILongPressGestureRecognizer) {
        owner?.handleDragged(self, drag)
    }

    func show(name text: String, flag emoji: String?, count number: Int?, badges tags: [String]) {
        name.text = text
        flag.text = emoji
        flag.isHidden = emoji == nil
        // A subscription has no flag or tags: its size stands in the pill instead.
        let subscription = number != nil
        leading.isHidden = subscription
        globe.isHidden = emoji != nil || subscription
        badges.set(tags)
        badges.isHidden = tags.isEmpty
        count.text = number.map { "\($0)" }
        count.isHidden = !subscription
        countPill.isHidden = !subscription
        name.font = subscription ? Theme.font(17, .semibold) : Theme.font(17, .medium)
        accessibilityLabel = text
        accessibilityValue = number.map { Format.plural($0, L("сервер"), L("сервера"), L("серверов")) }
    }

    func setPinned(_ pinned: Bool, action: @escaping () -> Void) {
        onPin = action
        pin.setImage(UIImage(systemName: pinned ? "pin.fill" : "pin", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)), for: .normal)
        pin.tintColor = pinned ? Theme.accent : .tertiaryLabel
        pinBack.backgroundColor = pinned ? Theme.accent.withAlphaComponent(0.14) : .clear
        pin.accessibilityLabel = pinned ? L("Открепить") : L("Закрепить")
        accessibilityTraits = pinned ? [.selected] : []
    }

    /// While it moves the card rises a little over the others.
    func setLifted(_ lifted: Bool) {
        UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.card.transform = lifted ? CGAffineTransform(scaleX: 1.03, y: 1.03) : .identity
            self.layer.shadowOpacity = lifted ? 0.16 : 0
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        card.transform = .identity
        layer.shadowOpacity = 0
    }
}
