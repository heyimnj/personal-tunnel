import TunnelCore
import UIKit
import UIKit.UIGestureRecognizerSubclass

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
            let color = BadgeRow.colors[labels.count % 4]
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
            guard index < badges.count else { continue }
            // The core tag (3.1.13) keeps its own colour wherever it falls in the row.
            let color = BadgeRow.color(badges[index], at: index)
            if label.textColor != color {
                label.textColor = color
                pills[index].backgroundColor = color.withAlphaComponent(0.13)
            }
        }
        setNeedsLayout()
    }

    private static func color(_ badge: String, at index: Int) -> UIColor {
        switch badge {
        case ProtocolFacts.xrayBadge: return .systemTeal
        case ProtocolFacts.singBoxBadge: return .systemIndigo
        default: return colors[index % 4]
        }
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
final class MinimalServersViewController: UIViewController, UIScrollViewDelegate, UIAdaptivePresentationControllerDelegate, UISearchTextFieldDelegate {
    private let list = ServerListView()
    /// «Поиск», above the subscriptions: hidden under the bar, a pull down in the
    /// list brings it out (as in Telegram's chat list).
    private let search = UISearchTextField()
    private var query = ""
    /// Subscriptions the search found by their servers (opened to show them).
    private var searchFound = Set<Int64>()
    private var placedSearch = false
    /// The search's slot above the list (3.1.0: the field is 48 pt, was 40).
    private static let searchHeight: CGFloat = 64
    private static let searchFieldHeight: CGFloat = 48
    /// A well set into the sheet, darker than the cards and with a fine edge, so
    /// the search does not read as one more subscription (3.1.0).
    private static let searchFill = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.42) : UIColor(red: 0.878, green: 0.878, blue: 0.898, alpha: 1)
    }
    private static let searchEdge = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.06)
    }
    /// 3.5: the bar of the owner's «вариант A» — a large title on the left, «+»
    /// beside it, and a row of capsules under them (it was 70: ✕, title, three buttons).
    /// 3.5 beta 3: the owner chooses the sheet's layout on «Внешний вид»: «A» (the
    /// title on the left), «B» (the actions in a bar at the bottom), «C» (the
    /// search in the head, the order in segments).
    private enum Layout: String { case header, bottom, search }
    private let layout = Layout(rawValue: Prefs.serversLayout) ?? .header
    private var barHeight: CGFloat {
        switch layout {
        // 3.5 beta 4 (the owner): the head's buttons are larger in «A» and «C».
        case .header: return 146
        case .bottom: return 136
        case .search: return 140
        }
    }
    /// The search's slot in the list: only «A» tucks the search under its bar;
    /// «B» and «C» keep it in the head.
    private var searchSlot: CGFloat { layout == .header ? Self.searchHeight : 0 }
    /// «B»: the bottom bar's items.
    private let pingItem = BarItem()
    private let sortItem = BarItem()
    private let refreshItem = BarItem()
    private let moreItem = BarItem()
    /// «C»: the ping inside the search field, the order in segments, and the
    /// capsules of a selection in their place.
    private let pingDial = PingDial()
    private let segments = UISegmentedControl()
    private let selectionPills = UIStackView(.horizontal, spacing: 8, alignment: .fill, [])
    /// Where the last touch began, and whether the search was already out then:
    /// a pull closes the sheet from the bar, or from anywhere once the search is out.
    private var touchStart: CGPoint = .zero
    private var searchOutAtTouch = false
    /// Where the list was last let go towards: the search's out position or not.
    /// A second pull comes while the first one's motion is still settling (3.0.3
    /// counted the search as out only once the list had come to rest there, so a
    /// quick second pull did not close the sheet).
    private var headingToSearch = false
    /// The swipe from the left or right edge of the screen that closes the sheet.
    /// 3.0.5: on again at the owner's word, with the sheet's own closing (it goes
    /// down as from a pull) instead of 3.0.2's sideways slide. Rows do not start
    /// their swipe within `edgeWidth` of either edge.
    static let edgeCloseEnabled = true
    static let edgeWidth: CGFloat = 24
    /// The sheet is already on its way down (from an edge or a pull).
    private var closing = false
    private var expanded = Prefs.expandedSubscriptions
    private var ordered: [Subscription] = []
    private let subtitle = UILabel(font: Theme.font(13), color: .secondaryLabel)
    /// «Пинг», filling as the test goes (in selection: «Удалить»).
    private let pingButton = PillButton()
    /// The order of the list, tapped through (in selection: «Скопировать»).
    private let sortButton = PillButton()
    private let plusButton = UIButton(type: .system)
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
        // 3.1.6: the swipe's symbols are ready before the first swipe.
        PlateButton.warmUp()
        Haptics.prepare()
        buildList()
        buildHeader()
        buildSearch()
        buildEdgeClose()
        App.shared.store.library.observe(self) { [weak self] _ in
            self?.reload()
            self?.showBar()
        }
        App.shared.latency.changed.observe(self, fireNow: false) { [weak self] keys in self?.refresh(keys) }
        App.shared.latency.progress.observe(self) { [weak self] in self?.show($0) }
        App.shared.refreshing.observe(self, fireNow: false) { [weak self] _ in self?.list.reconfigureHeaders() }
        App.shared.tunnel.state.observe(self, fireNow: false) { [weak self] _ in self?.list.reconfigureRows() }
        // 3.3 beta 3: the connected server and subscription move (the list animates a reorder).
        App.shared.orderChanged.observe(self) { [weak self] in self?.reload() }
    }

    // MARK: Header

    private func buildHeader() {
        switch layout {
        case .header: buildHeaderA()
        case .bottom: buildHeaderB()
        case .search: buildHeaderC()
        }
    }

    /// The bar of the page's tone and the grabber; «B» and «C» put their own in it.
    private func addBar() -> UIView {
        let bar = UIView()
        bar.backgroundColor = .systemGroupedBackground
        view.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        let grabber = UIView()
        grabber.backgroundColor = UIColor.label.withAlphaComponent(0.22)
        grabber.layer.cornerRadius = 2.5
        grabber.isAccessibilityElement = true
        grabber.accessibilityLabel = L("Закрыть")
        grabber.accessibilityTraits = .button
        grabber.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closeTapped)))
        grabber.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(grabber)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor), bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor), bar.heightAnchor.constraint(equalToConstant: barHeight),
            grabber.topAnchor.constraint(equalTo: bar.topAnchor, constant: 7), grabber.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 36), grabber.heightAnchor.constraint(equalToConstant: 5),
        ])
        list.contentInset.top = barHeight + 6
        list.verticalScrollIndicatorInsets.top = barHeight + 6
        return bar
    }

    /// The red «+», as «A» draws it.
    private func stylePlus(size: CGFloat) {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: size > 50 ? 22 : 18, weight: .bold))
        config.baseBackgroundColor = Theme.accent
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        plusButton.configuration = config
        plusButton.accessibilityLabel = L("Добавить")
        plusButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([plusButton.widthAnchor.constraint(equalToConstant: size), plusButton.heightAnchor.constraint(equalToConstant: size)])
    }

    private func moreMenu() -> UIMenu {
        UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.moreItems() ?? []) }])
    }

    /// The four orders, with a check at the current one.
    private func sortMenu() -> UIMenu {
        UIMenu(title: L("Сортировка"), children: [UIDeferredMenuElement.uncached { [weak self] done in
            guard let self else { done([]); return }
            done(Self.sorts.map { option in
                UIAction(title: Self.title(option), state: self.sort == option ? .on : .off) { [weak self] _ in
                    Haptics.selection()
                    self?.apply(option)
                }
            })
        }])
    }

    /// «B» (the owner's mock-up): the title in the middle over the search; ping,
    /// order, «+», update and «…» in a bar at the bottom of the sheet.
    private func buildHeaderB() {
        let bar = addBar()
        let title = UILabel(L("Серверы"), font: Theme.font(22, .bold))
        title.textAlignment = .center
        title.accessibilityTraits = .header
        subtitle.textAlignment = .center
        subtitle.lineBreakMode = .byTruncatingTail
        for item in [title, subtitle, search] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(item)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: bar.topAnchor, constant: 22), title.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: bar.leadingAnchor, constant: 20),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1), subtitle.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            subtitle.leadingAnchor.constraint(greaterThanOrEqualTo: bar.leadingAnchor, constant: 20),
            search.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12), search.heightAnchor.constraint(equalToConstant: 44),
            search.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16), search.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
        ])

        pingItem.addTarget(self, action: #selector(pingTapped), for: .touchUpInside)
        sortItem.addTarget(self, action: #selector(bottomSortTapped), for: .touchUpInside)
        sortItem.menu = sortMenu()
        refreshItem.show(symbol: "arrow.clockwise", title: L("Обновить"), tint: .label)
        refreshItem.addTarget(self, action: #selector(refreshTapped), for: .touchUpInside)
        moreItem.show(symbol: "ellipsis", title: L("Ещё"), tint: .label)
        moreItem.menu = moreMenu()
        moreItem.showsMenuAsPrimaryAction = true
        let room = UIView()
        room.isUserInteractionEnabled = false
        let row = UIStackView(.horizontal, spacing: 0, alignment: .fill, [pingItem, sortItem, room, refreshItem, moreItem])
        row.distribution = .fillEqually
        let panel = SolidCapsule()
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.12
        panel.layer.shadowRadius = 16
        panel.layer.shadowOffset = CGSize(width: 0, height: 6)
        panel.contentView.addSubview(row)
        row.pin(to: panel.contentView, insets: UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6))
        view.addSubview(panel)
        stylePlus(size: 58)
        view.addSubview(plusButton)
        panel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), panel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8), panel.heightAnchor.constraint(equalToConstant: 66),
            plusButton.centerXAnchor.constraint(equalTo: panel.centerXAnchor), plusButton.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
        ])
        list.contentInset.bottom = 66 + 20
        list.verticalScrollIndicatorInsets.bottom = 66 + 20
        showBar()
    }

    /// «C» (the owner's mock-up): the search in the head, with the ping inside
    /// it and «+» beside; the order in segments under them.
    private func buildHeaderC() {
        let bar = addBar()
        pingDial.addTarget(self, action: #selector(pingTapped), for: .touchUpInside)
        let more = UIButton(type: .system)
        more.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold)), for: .normal)
        more.tintColor = .secondaryLabel
        more.accessibilityLabel = L("Ещё")
        more.menu = moreMenu()
        more.showsMenuAsPrimaryAction = true
        let accessory = UIStackView(.horizontal, spacing: 0, alignment: .center, [pingDial, more])
        NSLayoutConstraint.activate([more.widthAnchor.constraint(equalToConstant: 44), more.heightAnchor.constraint(equalToConstant: 44)])
        // 3.5.4 (the owner: the ping did nothing here): the buttons lie over the
        // field, not inside it as its right view — the field gave that view less
        // room than its buttons and kept their touches. The right view only keeps
        // the text clear of them.
        let holder = UIView(frame: CGRect(x: 0, y: 0, width: 90, height: 44))
        holder.isUserInteractionEnabled = false
        search.rightView = holder
        search.rightViewMode = .always
        stylePlus(size: 54)

        for (index, option) in Self.sorts.enumerated() { segments.insertSegment(withTitle: Self.title(option), at: index, animated: false) }
        segments.apportionsSegmentWidthsByContent = true
        segments.setTitleTextAttributes([.font: Theme.font(15, .medium)], for: .normal)
        segments.setTitleTextAttributes([.font: Theme.font(15, .semibold)], for: .selected)
        segments.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
        let more2 = UIButton(type: .system)
        more2.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold)), for: .normal)
        more2.tintColor = .label
        more2.accessibilityLabel = L("Ещё")
        more2.menu = moreMenu()
        more2.showsMenuAsPrimaryAction = true
        let moreCapsule = SolidCapsule()
        moreCapsule.contentView.addSubview(more2)
        more2.pin(to: moreCapsule.contentView)
        moreCapsule.widthAnchor.constraint(equalToConstant: 44).isActive = true
        pingButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for item in [pingButton, sortButton, moreCapsule] as [UIView] { selectionPills.addArrangedSubview(item) }
        selectionPills.isHidden = true

        for item in [search, plusButton, segments, selectionPills] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(item)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: bar.topAnchor, constant: 22), search.heightAnchor.constraint(equalToConstant: 54),
            search.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16), search.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor, constant: -10),
            plusButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16), plusButton.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            segments.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10), segments.heightAnchor.constraint(equalToConstant: 44),
            segments.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16), segments.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            selectionPills.topAnchor.constraint(equalTo: segments.topAnchor), selectionPills.bottomAnchor.constraint(equalTo: segments.bottomAnchor),
            selectionPills.leadingAnchor.constraint(equalTo: segments.leadingAnchor), selectionPills.trailingAnchor.constraint(equalTo: segments.trailingAnchor),
        ])
        accessory.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(accessory)
        NSLayoutConstraint.activate([
            accessory.trailingAnchor.constraint(equalTo: search.trailingAnchor, constant: -4),
            accessory.centerYAnchor.constraint(equalTo: search.centerYAnchor),
        ])
        showBar()
    }

    @objc private func segmentChanged() {
        let index = segments.selectedSegmentIndex
        guard Self.sorts.indices.contains(index) else { return }
        Haptics.selection()
        apply(Self.sorts[index])
    }

    /// «B»: the order's item opens its menu; in a selection it copies.
    @objc private func bottomSortTapped() {
        guard selecting else { return }
        copySelected()
    }

    @objc private func refreshTapped() {
        App.shared.refreshAll()
    }

    /// «A»: the title on the left, «+» beside it, capsules under them.
    private func buildHeaderA() {
        let bar = UIView()
        // The page's own tone, so the first card does not run into the bar.
        bar.backgroundColor = .systemGroupedBackground
        view.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        // The sheet closes with a pull down (and the edge swipe): a grabber says so,
        // where the ✕ was.
        let grabber = UIView()
        grabber.backgroundColor = UIColor.label.withAlphaComponent(0.22)
        grabber.layer.cornerRadius = 2.5
        grabber.isAccessibilityElement = true
        grabber.accessibilityLabel = L("Закрыть")
        grabber.accessibilityTraits = .button
        grabber.isUserInteractionEnabled = true
        grabber.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closeTapped)))
        let title = UILabel(L("Серверы"), font: Theme.font(28, .bold))
        title.accessibilityTraits = .header
        subtitle.lineBreakMode = .byTruncatingTail

        var plusConfig = UIButton.Configuration.filled()
        plusConfig.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .bold))
        plusConfig.baseBackgroundColor = Theme.accent
        plusConfig.baseForegroundColor = .white
        plusConfig.cornerStyle = .capsule
        plusButton.configuration = plusConfig
        plusButton.accessibilityLabel = L("Добавить")
        plusButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)

        pingButton.addTarget(self, action: #selector(pingTapped), for: .touchUpInside)
        sortButton.addTarget(self, action: #selector(sortTapped), for: .touchUpInside)
        let more = UIButton(type: .system)
        more.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .bold)), for: .normal)
        more.tintColor = .label
        more.accessibilityLabel = L("Ещё")
        more.showsMenuAsPrimaryAction = true
        more.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.moreItems() ?? []) }])
        let moreGlass = SolidCapsule()
        moreGlass.contentView.addSubview(more)
        more.pin(to: moreGlass.contentView)
        sortButton.setContentHuggingPriority(.required, for: .horizontal)
        pingButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let pills = UIStackView(.horizontal, spacing: 8, alignment: .fill, [pingButton, sortButton, moreGlass])

        for item in [grabber, title, subtitle, plusButton, pills] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(item)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor), bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor), bar.heightAnchor.constraint(equalToConstant: barHeight),
            grabber.topAnchor.constraint(equalTo: bar.topAnchor, constant: 7), grabber.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 36), grabber.heightAnchor.constraint(equalToConstant: 5),
            title.topAnchor.constraint(equalTo: bar.topAnchor, constant: 24), title.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(lessThanOrEqualTo: plusButton.leadingAnchor, constant: -12),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1), subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: plusButton.leadingAnchor, constant: -12),
            plusButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16), plusButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            plusButton.widthAnchor.constraint(equalToConstant: 52), plusButton.heightAnchor.constraint(equalToConstant: 52),
            pills.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16), pills.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            pills.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -10), pills.heightAnchor.constraint(equalToConstant: 50),
            moreGlass.widthAnchor.constraint(equalToConstant: 50),
        ])
        list.contentInset.top = barHeight + 6
        list.verticalScrollIndicatorInsets.top = barHeight + 6
        showBar()
    }

    override func accessibilityPerformEscape() -> Bool {
        closeTapped()
        return true
    }

    /// «По порядку» → «По имени» → «По задержке» → «Недавние» → «По порядку».
    private enum Sort { case manual, name, latency, recent }

    private var sort: Sort {
        if Prefs.sortByRecent { return .recent }
        return Prefs.sortByLatency ? .latency : (Prefs.arrangement.byName ? .name : .manual)
    }

    private static func title(_ sort: Sort) -> String {
        switch sort {
        case .manual: return L("По порядку")
        case .name: return L("По имени")
        case .latency: return L("По задержке")
        case .recent: return L("Недавние")
        }
    }

    private static let sorts: [Sort] = [.manual, .name, .latency, .recent]

    @objc private func sortTapped() {
        Haptics.selection()
        if selecting {
            copySelected()
            return
        }
        let index = Self.sorts.firstIndex(of: sort) ?? 0
        apply(Self.sorts[(index + 1) % Self.sorts.count])
    }

    private func apply(_ next: Sort) {
        var arrangement = Prefs.arrangement
        arrangement.byName = next == .name
        Prefs.sortByLatency = next == .latency
        Prefs.sortByRecent = next == .recent
        Prefs.arrangement = arrangement
        reload()
        showBar()
    }

    /// What the bar says: the list (subscriptions and servers), or the selection.
    private var listSummary: String {
        let library = App.shared.library
        let subscriptions = library.subscriptions.filter { !$0.isStandalone }.count
        let servers = library.subscriptions.reduce(0) { $0 + $1.nodes.count }
        let parts = [subscriptions > 0 ? Format.plural(subscriptions, L("подписка"), L("подписки"), L("подписок")) : nil,
                     Format.plural(servers, L("сервер"), L("сервера"), L("серверов"))].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    /// The capsules: ping and the order, or (selecting) delete and copy.
    private func showBar() {
        if selecting {
            pingButton.show(symbol: "trash", title: L("Удалить"), tint: .systemRed, detail: nil, progress: nil)
            pingButton.accessibilityLabel = L("Удалить выбранное")
            sortButton.show(symbol: "doc.on.doc", title: L("Скопировать"), tint: .label, detail: nil, progress: nil)
            sortButton.accessibilityLabel = L("Скопировать выбранные ссылки")
            pingButton.isEnabled = !selectionEmpty
            sortButton.isEnabled = !selectionEmpty
            plusButton.isHidden = true
            subtitle.text = Lf("Выбрано: %@", "\(selectedSubscriptions.count + selectedNodes.count)")
        } else {
            plusButton.isHidden = false
            pingButton.isEnabled = true
            sortButton.isEnabled = true
            sortButton.show(symbol: "arrow.up.arrow.down", title: Self.title(sort), tint: .label, detail: nil, progress: nil)
            sortButton.accessibilityLabel = L("Сортировка") + ": " + Self.title(sort)
            show(App.shared.latency.progress.value)
        }
        switch layout {
        case .header:
            break
        case .bottom:
            if selecting {
                pingItem.show(symbol: "trash", title: L("Удалить"), tint: .systemRed)
                sortItem.show(symbol: "doc.on.doc", title: L("Скопировать"), tint: .label)
            } else {
                sortItem.show(symbol: "line.3.horizontal.decrease", title: Self.title(sort), tint: .label)
                sortItem.accessibilityLabel = L("Сортировка") + ": " + Self.title(sort)
            }
            sortItem.showsMenuAsPrimaryAction = !selecting
            pingItem.isEnabled = !selecting || !selectionEmpty
            sortItem.isEnabled = !selecting || !selectionEmpty
        case .search:
            segments.isHidden = selecting
            selectionPills.isHidden = !selecting
            segments.selectedSegmentIndex = Self.sorts.firstIndex(of: sort) ?? 0
            pingDial.isHidden = selecting
            if selecting { search.placeholder = subtitle.text }
        }
    }

    private func show(_ progress: LatencyProgress) {
        guard !selecting else { return }
        if progress.running {
            pingButton.show(symbol: "stop.fill", title: L("Стоп"), tint: Theme.accent, detail: "\(progress.done)/\(progress.total)",
                            progress: progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0)
            pingButton.accessibilityLabel = L("Остановить проверку")
        } else {
            pingButton.show(symbol: "waveform.path.ecg", title: L("Пинг"), tint: Theme.accent, detail: nil, progress: nil)
            pingButton.accessibilityLabel = L("Проверить пинг")
        }
        subtitle.text = listSummary
        let fraction = progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0
        switch layout {
        case .header:
            break
        case .bottom:
            pingItem.show(symbol: progress.running ? "stop.fill" : "waveform.path.ecg",
                          title: progress.running ? "\(progress.done)/\(progress.total)" : L("Пинг"), tint: Theme.accent)
            pingItem.accessibilityLabel = progress.running ? L("Остановить проверку") : L("Проверить пинг")
        case .search:
            pingDial.show(running: progress.running, progress: fraction)
            let servers = App.shared.library.subscriptions.reduce(0) { $0 + $1.nodes.count }
            search.placeholder = progress.running ? Lf("Проверено %@ из %@", "\(progress.done)", "\(progress.total)") : L("Серверы") + " · \(servers)"
        }
    }

    private func moreItems() -> [UIMenuElement] {
        // 3.5: the order is the bar's own capsule now.
        return [
            UIAction(title: L("Порядок серверов"), image: UIImage(systemName: "list.number")) { [weak self] _ in
                // 3.5 beta 2: the Modern page of its own (cards, as in this sheet).
                self?.present(ModernServerOrderViewController.wrapped(), animated: true)
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

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        search.layer.borderColor = Self.searchEdge.resolvedColor(with: traitCollection).cgColor
    }

    /// 3.5 beta 4: the sheet is on screen (or on its way): Home's server capsule
    /// turns its chevron down while it is.
    static let shown = Observable(false)

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationController?.delegate = self
        Self.shown.set(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { Self.shown.set(false) }
    }

    /// A pull that went back: the sheet stays.
    func presentationControllerDidAttemptToDismiss(_: UIPresentationController) {
        Self.shown.set(true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if layout == .header {
            search.frame = CGRect(x: ServerListView.margin, y: 4, width: max(0, list.bounds.width - 2 * ServerListView.margin), height: Self.searchFieldHeight)
        }
        search.layer.borderColor = Self.searchEdge.resolvedColor(with: traitCollection).cgColor
        if !placedSearch, list.bounds.height > 0 {
            placedSearch = true
            list.layoutIfNeeded()
            list.contentOffset.y = searchHidden
        }
    }

    // MARK: Search

    /// The list's offsets with the search field out and tucked under the bar.
    private var searchShown: CGFloat { -list.adjustedContentInset.top }
    private var searchHidden: CGFloat { searchShown + searchSlot }

    private func buildSearch() {
        search.placeholder = L("Поиск")
        search.font = Theme.font(.body)
        search.returnKeyType = .search
        search.autocorrectionType = .no
        search.autocapitalizationType = .none
        search.clearButtonMode = .whileEditing
        search.backgroundColor = Self.searchFill
        search.borderStyle = .none
        search.layer.borderWidth = 1 / UIScreen.main.scale
        search.layer.cornerRadius = Self.searchFieldHeight / 2
        search.leftView?.tintColor = .secondaryLabel
        search.layer.cornerCurve = .continuous
        search.clipsToBounds = true
        search.delegate = self
        search.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        if layout == .header {
            list.addSubview(search)
        } else {
            // In the head: the cards' colour, as the mock-ups have it.
            search.backgroundColor = SurfaceView.card
            search.layer.borderWidth = 0
            search.layer.cornerRadius = layout == .bottom ? 22 : 27
        }
        list.leading = searchSlot
        list.delegate = self
        list.keyboardDismissMode = .onDrag
        // Touches are noted (never taken) to tell a pull on the bar from one in the list.
        let recorder = TouchRecorder { [weak self] point in
            guard let self else { return }
            self.touchStart = point
            self.searchOutAtTouch = self.searchIsOut(atTouch: true)
        }
        view.addGestureRecognizer(recorder)
    }

    /// The search is out, or on its way out from the last pull. `atTouch`: a new
    /// touch has landed; a list still settling towards the search is put there at
    /// once (a few points at most), so the sheet's own pull can take over from the
    /// first point of the gesture.
    private func searchIsOut(atTouch: Bool) -> Bool {
        guard placedSearch else { return false }
        let offset = list.contentOffset.y
        if offset <= searchShown + 1 { return true }
        guard headingToSearch, !list.isDragging, offset < searchHidden - 0.5 else { return false }
        if atTouch {
            list.setContentOffset(CGPoint(x: list.contentOffset.x, y: searchShown), animated: false)
        }
        return true
    }

    @objc private func searchChanged() {
        let next = (search.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard next != query else { return }
        query = next
        reload()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    /// A pull that stops half way settles with the field either out or tucked away.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard scrollView === list else { return }
        // 3.0.5: the second pull, when it lands while the first one's motion is
        // still settling, stays with the list (iOS gives the sheet only a pull that
        // starts on a list at rest), and the list just stretched past its top. Such
        // a pull, begun with the search out, closes the sheet when let go far
        // enough or fast enough downwards, with the sheet's own closing.
        let stretched = searchShown - list.contentOffset.y
        if searchOutAtTouch || touchStart.y <= barHeight, stretched > 0,
           stretched >= Self.pullToClose || velocity.y <= -Self.pullToCloseSpeed {
            targetContentOffset.pointee.y = searchShown
            headingToSearch = true
            close()
            return
        }
        let target = targetContentOffset.pointee.y
        defer { headingToSearch = targetContentOffset.pointee.y <= searchShown + 0.5 }
        guard target > searchShown + 0.5, target < searchHidden - 0.5 else { return }
        let keep = !query.isEmpty || search.isFirstResponder
        let out = keep || (velocity.y < 0 || (velocity.y == 0 && target < (searchShown + searchHidden) / 2))
        targetContentOffset.pointee.y = out ? searchShown : searchHidden
    }

    /// Where the list actually came to rest decides from now on.
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === list else { return }
        headingToSearch = list.contentOffset.y <= searchShown + 0.5
    }

    /// The sheet closes from a pull that starts on the bar (the close button, the
    /// title, the buttons), or anywhere once the search is out: the first pull in
    /// the list brings out the search, the next one closes the sheet.
    func presentationControllerShouldDismiss(_: UIPresentationController) -> Bool {
        touchStart.y <= barHeight || searchOutAtTouch
    }

    /// How far past its top (points) a pull that began with the search out must
    /// stretch the list to close the sheet, or how fast (points per millisecond) it
    /// must be let go downwards.
    private static let pullToClose: CGFloat = 44
    private static let pullToCloseSpeed: CGFloat = 0.5

    /// Closes the sheet the way a pull down does (iOS's own sheet closing).
    private func close() {
        guard !closing, presentedViewController == nil else { return }
        closing = true
        search.resignFirstResponder()
        list.closeSwipe()
        dismiss(animated: true)
    }

    // MARK: Closing from the edge

    /// A swipe from the very left or right edge of the screen closes the sheet,
    /// let go far or fast enough: it goes down exactly as from a pull (the sheet
    /// itself is not moved before: iOS's closing animates it from where it
    /// stands). From anywhere else a horizontal swipe is the rows' own.
    private func buildEdgeClose() {
        guard Self.edgeCloseEnabled else { return }
        for edge in [UIRectEdge.left, .right] {
            let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgePanned(_:)))
            pan.edges = edge
            view.addGestureRecognizer(pan)
        }
    }

    @objc private func edgePanned(_ pan: UIScreenEdgePanGestureRecognizer) {
        guard !closing else { return }
        let sign: CGFloat = pan.edges == .left ? 1 : -1
        let moved = max(0, pan.translation(in: view).x * sign)
        switch pan.state {
        case .began:
            search.resignFirstResponder()
            list.closeSwipe()
        case .ended:
            let speed = pan.velocity(in: view).x * sign
            if moved > 48 || (moved > 12 && speed > 350) { close() }
        default:
            break
        }
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
            App.shared.ping(nodes: shownServers())
        }
    }

    /// The servers the list shows, in its order (3.0.5): open subscriptions and
    /// single servers, each narrowed by its filters. With nothing open, every
    /// server left by the filters.
    ///
    /// 3.1.1: while searching, exactly the servers the search found, whether
    /// their subscription has finished opening or not; and the field's own text
    /// is read first, so a change that has not reached the list yet (a word
    /// picked from the keyboard's suggestions) still counts. The test ran over
    /// whole open subscriptions when the list lagged behind the field.
    private func shownServers() -> [(Subscription, ServerNode)] {
        let typed = (search.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if typed != query {
            query = typed
            reload()
        }
        let library = App.shared.library
        func servers(_ sections: [ServerListView.Section]) -> [(Subscription, ServerNode)] {
            sections.flatMap { section -> [(Subscription, ServerNode)] in
                guard let subscription = library.subscription(section.id) else { return [] }
                return section.nodes.compactMap { tag in subscription.node(tag).map { (subscription, $0) } }
            }
        }
        if !query.isEmpty {
            // Found by their servers (open, or opening), and those open by hand; a
            // subscription matched only by its name shows just its head until opened.
            return servers(list.sections.filter { $0.standalone || searchFound.contains($0.id) || list.isOpen($0.id) })
        }
        let open = servers(list.sections.filter { $0.standalone || list.isOpen($0.id) })
        return open.isEmpty ? servers(list.sections) : open
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
        // 3.5.17: servers without a link (Xray JSON, a file) are copied as JSON.
        let subscriptionLinks = selectedSubscriptions.compactMap { library.subscription($0)?.url }
        guard let result = ServerExport.text(selectedPairs.map(\.1), extraLinks: subscriptionLinks) else { return }
        Clipboard.copySecret(result.text)
        switch (result.links, result.configs) {
        case (_, 0): App.shared.notice.value = Lf("Скопировано ссылок: %@.", "\(result.links)")
        case (0, _): App.shared.notice.value = Lf("Скопировано в JSON: %@.", Format.plural(result.configs, L("сервер"), L("сервера"), L("серверов")))
        default: App.shared.notice.value = Lf("Скопировано ссылок: %@, в JSON: %@.", "\(result.links)", Format.plural(result.configs, L("сервер"), L("сервера"), L("серверов")))
        }
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
            return [SwipeAction(symbol: "pencil", color: .systemOrange, title: L("Изменить")) { self?.editSubscription(id) },
             SwipeAction(symbol: "arrow.clockwise", color: .systemBlue, title: L("Обновить")) { App.shared.refresh(id) },
             SwipeAction(symbol: "trash", color: .systemRed, title: L("Удалить")) { self?.confirmDelete(subscription: id) }]
        }
        list.actionsForRow = { [weak self] id, tag in
            if self?.selecting == true { return [] }
            return [SwipeAction(symbol: "pencil", color: .systemOrange, title: L("Изменить")) { self?.edit(node: tag, in: id) },
             // 3.5.15 (the owner): pin in place of ping (ping is the row's own button).
             { () -> SwipeAction in
                 let standalone = App.shared.library.subscription(id)?.isStandalone == true
                 let key = standalone ? Arrangement.subscription(id) : Arrangement.server(id, tag)
                 let pinned = Prefs.arrangement.isPinned(key)
                 return SwipeAction(symbol: pinned ? "pin.slash" : "pin", color: .systemBlue, title: pinned ? L("Открепить") : L("Закрепить")) { self?.togglePin(key) }
             }(),
             SwipeAction(symbol: "trash", color: .systemRed, title: L("Удалить")) { self?.confirmDelete(node: tag, in: id) }]
        }
        list.onFilter = { [weak self] id, tag in self?.pickFilter(id, tag) }
        list.onToggle = { [weak self] id in
            guard let self else { return }
            if self.selecting { self.toggleSelected(subscription: id) } else { self.toggle(id) }
        }
        list.onSelect = { [weak self] id, tag in
            guard let self else { return }
            if self.selecting { self.toggleSelected(node: tag, in: id); return }
            Haptics.item()
            App.shared.select(node: tag, in: id)
            // «Недавние»: the chosen server goes up at once, with the VPN off as well.
            if Prefs.sortByRecent { self.reload() }
        }
        list.onPing = { [weak self] id, tag in
            if self?.selecting == true { self?.toggleSelected(node: tag, in: id); return }
            guard let subscription = App.shared.library.subscription(id), let node = subscription.node(tag) else { return }
            Haptics.tap()
            App.shared.ping(node: node, in: subscription)
        }
        list.onHold = { [weak self] id, tag, point, source, release in
            guard let self, !self.selecting else { release(); return }
            self.hold(id, tag, at: point, source: source, release: release)
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
        // 3.3 beta 3: the server the VPN is connected to rises under the pinned ones.
        let lifted = App.shared.liftedServer
        var nodes = Prefs.arrangement.sorted(subscription.nodes, key: { Arrangement.server(subscription.id, $0.id) }, name: { labels[$0.id]?.text ?? $0.name }, lifted: lifted)
        if Prefs.sortByRecent {
            // The latest chosen first; servers never chosen keep their order after them.
            let pinned = Set(Prefs.arrangement.pinned)
            let used = Dictionary(Prefs.arrangement.recent.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
            nodes = nodes.enumerated().sorted { left, right in
                let lk = Arrangement.server(subscription.id, left.element.id), rk = Arrangement.server(subscription.id, right.element.id)
                let lp = pinned.contains(lk), rp = pinned.contains(rk)
                if lp != rp { return lp }
                if let lifted, (lk == lifted) != (rk == lifted) { return lk == lifted }
                let l = used[lk] ?? Int.max, r = used[rk] ?? Int.max
                return l != r ? l < r : left.offset < right.offset
            }.map(\.element)
        } else if Prefs.sortByLatency {
            let latency = App.shared.latency
            let pinned = Set(Prefs.arrangement.pinned)
            nodes = nodes.enumerated().sorted { left, right in
                let lk = Arrangement.server(subscription.id, left.element.id), rk = Arrangement.server(subscription.id, right.element.id)
                let lp = pinned.contains(lk), rp = pinned.contains(rk)
                if lp != rp { return lp }
                if let lifted, (lk == lifted) != (rk == lifted) { return lk == lifted }
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
        let needle = query.lowercased()
        var found = Set<Int64>()
        let sections = ordered.compactMap { subscription -> ServerListView.Section? in
            let nodes = sortedNodes(subscription)
            let tags = Self.filterTags(subscription)
            let selected = Set(filters[String(subscription.id)] ?? []).intersection(tags)
            var shown = selected.isEmpty ? nodes : nodes.filter { selected.isSubset(of: Set($0.facts.badges)) }
            // Searching: a subscription whose name matches shows as it is; otherwise
            // only its servers whose names match, and none at all hides it.
            if !needle.isEmpty, !subscription.name.lowercased().contains(needle) {
                let store = App.shared.store
                shown = shown.filter { store.label(of: $0, in: subscription).text.lowercased().contains(needle) || $0.name.lowercased().contains(needle) }
                guard !shown.isEmpty else { return nil }
                found.insert(subscription.id)
            }
            return ServerListView.Section(id: subscription.id, standalone: subscription.isStandalone, nodes: shown.map(\.id),
                                          tags: tags, selected: selected,
                                          traffic: Self.trafficText(subscription.info), expiry: Self.expiryText(subscription.info))
        }
        searchFound = found
        // Subscriptions found by their servers open to show them; the user's own
        // open/closed choice is kept for when the search is cleared.
        list.set(sections, open: needle.isEmpty ? expanded : expanded.union(found))
    }

    /// «65 GB из 500 GB»; without a limit «65 GB из ∞». Nothing when the provider
    /// reports no traffic.
    static func trafficText(_ info: SubscriptionInfo) -> String? {
        guard let used = info.usedBytes else { return nil }
        let limit = info.isLimited ? amount(info.totalBytes ?? 0) : "∞"
        return Lf("%@ из %@", amount(used), limit)
    }

    /// «Активна до 12.12.2026 (30 дней)», «… (сегодня)», or «Истекла 12.12.2026».
    static func expiryText(_ info: SubscriptionInfo, now: Date = Date()) -> String? {
        guard let expires = info.expiresAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Language.locale
        formatter.setLocalizedDateFormatFromTemplate("ddMMyyyy")
        let date = formatter.string(from: expires)
        guard expires > now else { return Lf("Истекла %@", date) }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: expires)).day ?? 0
        let left = days <= 0 ? L("сегодня") : Format.plural(days, L("день"), L("дня"), L("дней"))
        return Lf("Активна до %@ (%@)", date, left)
    }

    /// Bytes to two decimals without needless zeros: «101.98 GB», «65 GB», «1.5 TB».
    private static func amount(_ bytes: Int64) -> String {
        Format.traffic(bytes)
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
        Haptics.item()
        list.setOpen(id, open)
    }

    // MARK: Row actions

    /// The items and their order are 1.5.0's.
    private func hold(_ id: Int64, _ tag: String?, at point: CGPoint, source: ServerListView.HoldSource?, release: @escaping () -> Void) {
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
                HoldMenuItem(title: L("Редактировать"), symbol: "pencil") { [weak self] in self?.editSubscription(id) },
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
        HoldMenuView.show(in: view, at: list.convert(point, to: view), title: title, items: items, source: source, onDismiss: release)
    }

    private func togglePin(_ key: String) {
        var next = Prefs.arrangement
        next.togglePin(key)
        Prefs.arrangement = next
        reload()
        list.reloadActions()
    }

    private func copy(_ text: String?) {
        guard let text, !text.isEmpty else {
            App.shared.notice.value = L("У этого сервера нет исходной ссылки: он добавлен из файла или из подписки в формате JSON.")
            return
        }
        Clipboard.copySecret(text)
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

    /// «Редактировать» on a subscription: its name and the order of its servers.
    private func editSubscription(_ id: Int64) {
        guard let subscription = App.shared.library.subscription(id) else { return }
        present(SubscriptionEditorViewController.wrapped(subscription) { [weak self] in self?.reload() }, animated: true)
    }

    /// «Редактировать»: the full form. 3.1.6: a server Xray-core runs gets it too
    /// (written back into its Xray outbounds), a group its own editor; only what
    /// no form describes is renamed.
    private func edit(node tag: String, in id: Int64) {
        guard let node = App.shared.library.subscription(id)?.node(tag) else { return }
        if node.isGroup {
            present(GroupEditorViewController.wrapped(node: node) { outbound, members, name in
                App.shared.update(node: tag, in: id, outbound: outbound, members: members, name: name)
            }, animated: true)
            return
        }
        if node.type == XrayBacked.type, let draft = XrayBacked.draft(node.outbound, name: node.name) {
            let original = node.outbound
            present(ServerEditorViewController.wrapped(draft, original: original, title: L("Редактировать"),
                                                      write: { try XrayBacked.apply($0, to: original) }) { outbound, name in
                App.shared.update(node: tag, in: id, outbound: outbound, members: [], name: name)
            }, animated: true)
            return
        }
        guard let draft = ServerDraft(outbound: node.outbound, name: node.name) else {
            rename(node: tag, in: id)
            return
        }
        present(ServerEditorViewController.wrapped(draft, original: node.outbound, title: L("Редактировать")) { outbound, name in
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

/// Notes where each touch begins and never recognizes, so it takes nothing from
/// the views and gestures under it.
final class TouchRecorder: UIGestureRecognizer {
    private let began: (CGPoint) -> Void

    init(_ began: @escaping (CGPoint) -> Void) {
        self.began = began
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, let view { began(touch.location(in: view)) }
        state = .failed
    }

    override func canPrevent(_: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by _: UIGestureRecognizer) -> Bool { false }
}

/// A capsule of the servers' bar (3.5, the owner's «вариант A»): a symbol and a
/// word, a count at the end, and a fill that grows with a running test.
final class PillButton: UIControl {
    /// 3.5 beta 2: a solid capsule of the cards' own colour (the owner: the bar's
    /// capsules were glass, the subscriptions and servers below them are not).
    private let glass = SolidCapsule()
    private let fill = UIView()
    private let icon = UIImageView()
    private let label = UILabel(font: Theme.font(17, .medium))
    private let detail = UILabel(font: UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold), color: .secondaryLabel)
    private var progress: Double?

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.isUserInteractionEnabled = false
        addSubview(glass)
        glass.pin(to: self)
        fill.isUserInteractionEnabled = false
        glass.contentView.addSubview(fill)
        icon.contentMode = .center
        icon.setContentHuggingPriority(.required, for: .horizontal)
        detail.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let row = UIStackView(.horizontal, spacing: 6, alignment: .center, [icon, label, UIView(), detail])
        row.isUserInteractionEnabled = false
        glass.contentView.addSubview(row)
        row.pin(to: glass.contentView, insets: UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16))
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func show(symbol: String, title: String, tint: UIColor, detail text: String?, progress value: Double?) {
        icon.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: Theme.font(17, .semibold)))
        icon.tintColor = tint
        label.text = title
        detail.text = text
        detail.isHidden = text == nil
        fill.backgroundColor = tint.withAlphaComponent(0.14)
        let was = progress
        progress = value
        // The fill follows the test; it does not jump back when a new one starts.
        if let value, let was, value >= was {
            UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) { self.layoutFill() }
        } else {
            layoutFill()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutFill()
    }

    private func layoutFill() {
        let share = CGFloat(max(0, min(1, progress ?? 0)))
        fill.frame = CGRect(x: 0, y: 0, width: glass.contentView.bounds.width * share, height: glass.contentView.bounds.height)
    }

    override var isHighlighted: Bool {
        didSet { UIView.animate(withDuration: 0.15) { self.alpha = self.isHighlighted ? 0.6 : 1 } }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.4 }
    }

    override var accessibilityValue: String? {
        get { detail.isHidden ? nil : detail.text }
        set {}
    }
}

/// A capsule (or circle) of the servers' card colour, as the subscriptions and
/// servers under it are drawn: no glass, no blur (3.5 beta 2).
final class SolidCapsule: UIView {
    /// Put content here; it is clipped to the capsule.
    let contentView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = SurfaceView.card
        layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        contentView.layer.cornerCurve = .continuous
        addSubview(contentView)
        contentView.pin(to: self)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        contentView.layer.cornerRadius = bounds.height / 2
    }
}

/// An item of «B»'s bottom bar: a symbol over a small caption.
final class BarItem: UIButton {
    private let icon = UIImageView()
    private let caption = UILabel(font: Theme.font(10, .medium), color: .secondaryLabel)

    init() {
        super.init(frame: .zero)
        icon.contentMode = .center
        caption.textAlignment = .center
        caption.adjustsFontSizeToFitWidth = true
        caption.minimumScaleFactor = 0.75
        let stack = UIStackView(.vertical, spacing: 3, alignment: .center, [icon, caption])
        stack.isUserInteractionEnabled = false
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            icon.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func show(symbol: String, title: String, tint: UIColor) {
        icon.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        icon.tintColor = tint
        caption.text = title
        caption.textColor = tint == .systemRed ? .systemRed : .secondaryLabel
        accessibilityLabel = title
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.5 : (isEnabled ? 1 : 0.4) }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.4 }
    }
}

/// «C»'s ping inside the search field: a round button that fills its rim as
/// the test goes and stops it when tapped again.
final class PingDial: UIControl {
    private let icon = UIImageView()
    private let ring = CAShapeLayer()
    private static let side: CGFloat = 38

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.accent.withAlphaComponent(0.12)
        layer.cornerRadius = Self.side / 2
        icon.contentMode = .center
        icon.tintColor = Theme.accent
        icon.isUserInteractionEnabled = false
        addSubview(icon)
        ring.fillColor = nil
        ring.strokeColor = Theme.accent.cgColor
        ring.lineWidth = 2
        ring.lineCap = .round
        ring.strokeEnd = 0
        layer.addSublayer(ring)
        isAccessibilityElement = true
        accessibilityTraits = .button
        show(running: false, progress: 0)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: Self.side), heightAnchor.constraint(equalToConstant: Self.side)])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = bounds
        ring.frame = bounds
        ring.path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2 - 1,
                                 startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true).cgPath
    }

    func show(running: Bool, progress: Double) {
        icon.image = UIImage(systemName: running ? "stop.fill" : "waveform.path.ecg", withConfiguration: UIImage.SymbolConfiguration(pointSize: running ? 13 : 17, weight: .semibold))
        ring.strokeEnd = running ? CGFloat(max(0, min(1, progress))) : 0
        accessibilityLabel = running ? L("Остановить проверку") : L("Проверить пинг")
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.5 : 1 }
    }
}
