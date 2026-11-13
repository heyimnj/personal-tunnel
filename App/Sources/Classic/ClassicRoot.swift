import TunnelCore
import UIKit

/// «Классика»: PERSONAL TUNNEL header, four numbered tabs. Metrics are 1.5.0's:
/// a 58 pt app bar under the status bar and a 46 pt tab bar above the home indicator.
final class ClassicRootViewController: UIViewController {
    static let appBarHeight: CGFloat = 58
    static let tabBarHeight: CGFloat = 46

    private let pages: [UIViewController] = [ClassicHomeViewController(), ClassicServersViewController(), ClassicManageViewController(), ClassicSettingsViewController()]
    private let titles = [L("Главная"), L("Серверы"), L("Управление"), L("Настройки")]
    private let counter = Classic.micro("VPN / 01")
    private let container = UIView()
    private let bar = UIStackView(.horizontal, spacing: 0, alignment: .fill, [])
    private var tabs: [(control: TapControl, number: UILabel, title: UILabel)] = []
    private var index = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        let name = Classic.text("PERSONAL TUNNEL", 15, .bold)
        let header = UIView()
        let brand = UIStackView(.vertical, spacing: 1, alignment: .leading, [name, Classic.micro("PRIVATE NETWORK")])
        for item in [brand, counter] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(item)
        }
        NSLayoutConstraint.activate([
            brand.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20), brand.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            counter.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20), counter.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            brand.trailingAnchor.constraint(lessThanOrEqualTo: counter.leadingAnchor, constant: -8),
        ])
        let top = Classic.rule()
        let bottom = Classic.rule()
        bar.distribution = .fillEqually
        for (offset, title) in titles.enumerated() {
            let number = Classic.micro(String(format: "%02d", offset + 1))
            let label = Classic.text(title, 11)
            let stack = UIStackView(.vertical, spacing: 3, alignment: .center, [number, label])
            let holder = UIView()
            holder.addSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
            // Number and title sit in the top 46 pt; the tab (and its highlight) runs on to the screen edge.
            NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
                                         stack.centerYAnchor.constraint(equalTo: holder.topAnchor, constant: (Self.tabBarHeight - 1) / 2)])
            let tab = ClassicRow(holder) { [weak self] in self?.select(offset) }
            tabs.append((tab, number, label))
            bar.addArrangedSubview(tab)
        }
        for item in [header, top, container, bottom, bar] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor), header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.appBarHeight - 1),
            top.topAnchor.constraint(equalTo: header.bottomAnchor), top.leadingAnchor.constraint(equalTo: view.leadingAnchor), top.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.topAnchor.constraint(equalTo: top.bottomAnchor), container.leadingAnchor.constraint(equalTo: view.leadingAnchor), container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: view.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.topAnchor.constraint(equalTo: bottom.bottomAnchor), bar.leadingAnchor.constraint(equalTo: view.leadingAnchor), bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // As in 1.5.0: 46 pt above the home indicator, and the bar reaches the screen edge.
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -(Self.tabBarHeight - 1)),
        ])
        for page in pages {
            addChild(page)
            page.view.frame = container.bounds
            page.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            page.view.isHidden = true
            container.addSubview(page.view)
            page.didMove(toParent: self)
        }
        select(0)
        Prefs.appearanceChanged.observe(self) { [weak self] in
            guard let self else { return }
            self.view.backgroundColor = Theme.background
            self.select(self.index)
        }
    }

    func select(_ next: Int) {
        if next != index { Haptics.selection() }
        index = next
        counter.text = String(format: "VPN / %02d", next + 1)
        for (offset, page) in pages.enumerated() { page.view.isHidden = offset != next }
        for (offset, tab) in tabs.enumerated() {
            let active = offset == next
            tab.control.backgroundColor = active ? Theme.accent.withAlphaComponent(0.14) : .clear
            tab.number.textColor = active ? Theme.accent : .secondaryLabel
            tab.title.font = Theme.fixed(11, active ? .semibold : .regular)
        }
    }
}

/// 01 Главная, laid out as 1.5.0 did on one screen: the status card, «Локация»,
/// the location list (it scrolls inside its frame) and the subscription card at the bottom.
final class ClassicHomeViewController: UIViewController {
    private let session = UILabel(font: Theme.fixedMono(13, .semibold))
    private let traffic = UILabel(font: Theme.fixedMono(13, .semibold))
    private let cardBox = UIView()
    private let listHolder = UIView()
    private let listScroll = UIScrollView()
    private let list = UIStackView(.vertical, spacing: 0, alignment: .fill, [])
    private let quickBox = UIView()
    private let fade = CAGradientLayer()
    private var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        let all = ClassicRow(Classic.text(L("ВСЕ ЛОКАЦИИ →"), 10, .semibold, Theme.text.withAlphaComponent(0.75), tracking: 0.5)) { [weak self] in
            (self?.parent as? ClassicRootViewController)?.select(1)
        }
        all.setContentHuggingPriority(.required, for: .horizontal)
        let heading = UIStackView(.horizontal, spacing: 8, alignment: .firstBaseline, [Classic.text(L("Локация"), 20, .semibold, tracking: -0.4), UIView(), all])
        heading.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true

        listScroll.showsVerticalScrollIndicator = false
        listScroll.alwaysBounceVertical = false
        listHolder.addSubview(listScroll)
        listScroll.pin(to: listHolder)
        let framed = UIView()
        framed.layer.borderWidth = 1
        framed.layer.borderColor = Theme.text.cgColor
        framed.addSubview(list)
        list.pin(to: framed)
        listScroll.addSubview(framed)
        framed.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            framed.topAnchor.constraint(equalTo: listScroll.contentLayoutGuide.topAnchor),
            framed.bottomAnchor.constraint(equalTo: listScroll.contentLayoutGuide.bottomAnchor, constant: -8),
            framed.leadingAnchor.constraint(equalTo: listScroll.frameLayoutGuide.leadingAnchor),
            framed.trailingAnchor.constraint(equalTo: listScroll.frameLayoutGuide.trailingAnchor),
        ])
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        fade.locations = [0, 0.9, 1]

        let stack = UIStackView(.vertical, spacing: 0, alignment: .fill, [cardBox, heading, listHolder, quickBox])
        stack.setCustomSpacing(14, after: cardBox)
        stack.setCustomSpacing(10, after: heading)
        stack.setCustomSpacing(8, after: listHolder)
        // The list takes what is left; everything else keeps its height.
        listHolder.setContentHuggingPriority(.defaultLow - 1, for: .vertical)
        listHolder.setContentCompressionResistancePriority(.defaultLow - 1, for: .vertical)
        for item in [cardBox, heading, quickBox] as [UIView] {
            item.setContentHuggingPriority(.required, for: .vertical)
            item.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        view.addSubview(stack)
        stack.pin(to: view, insets: UIEdgeInsets(top: 24, left: 20, bottom: 12, right: 20))

        let app = App.shared
        app.tunnel.state.observe(self, fireNow: false) { [weak self] _ in self?.rebuild() }
        app.store.library.observe(self, fireNow: false) { [weak self] _ in self?.rebuild() }
        app.latency.changed.observe(self, fireNow: false) { [weak self] _ in self?.rebuild() }
        Prefs.appearanceChanged.observe(self) { [weak self, weak framed] in
            self?.view.backgroundColor = Theme.background
            framed?.layer.borderColor = Theme.text.cgColor
            self?.rebuild()
        }
        // Only the two labels follow the clock and the counters.
        app.core.status.observe(self) { [weak self] status in
            self?.traffic.text = Classic.traffic((status?.downlinkTotal ?? 0) + (status?.uplinkTotal ?? 0))
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        rebuild()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        // Layer colours do not follow the appearance by themselves.
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle { rebuild() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Fade only the bottom edge, and only when the list really scrolls.
        let scrolls = listScroll.contentSize.height > listScroll.bounds.height + 28
        fade.frame = listHolder.bounds
        listHolder.layer.mask = scrolls ? fade : nil
    }

    private func tick() {
        let since = App.shared.tunnel.connectedSince.value
        session.text = Format.duration(since.map { Int(Date().timeIntervalSince($0)) } ?? 0)
    }

    private func rebuild() {
        for box in [cardBox, quickBox] { box.subviews.forEach { $0.removeFromSuperview() } }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let app = App.shared
        let library = app.library
        let state = app.tunnel.state.value
        let subscription = library.activeSubscription
        let node = library.activeNode
        let on = state.isOn
        let stateText: String
        switch state {
        case .connected: stateText = L("Туннель запущен")
        case .reasserting: stateText = L("Восстановление туннеля")
        case .connecting: stateText = L("Запуск туннеля")
        case .disconnecting: stateText = L("Туннель останавливается")
        case .disconnected: stateText = L("Туннель остановлен")
        }
        let stateColor: UIColor = state.isBusy ? .systemOrange : (on ? .systemGreen : Theme.danger)
        let label = subscription.flatMap { s in node.map { app.store.label(of: $0, in: s) } }
        let entry = subscription.flatMap { s in node.flatMap { app.latency.entry(s.id, $0.id) } }
        let ink = Theme.text

        // Status card
        func dot(_ color: UIColor, _ side: CGFloat) -> UIView {
            let view = UIView()
            view.backgroundColor = color
            view.layer.cornerRadius = side / 2
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: side), view.heightAnchor.constraint(equalToConstant: side)])
            return view
        }
        let short = String((subscription?.name ?? "").uppercased().prefix(6))
        let slot = Classic.mono((short.isEmpty ? "IMPORT" : short) + " / 01", 11, ink.withAlphaComponent(0.85), weight: .regular)
        let status = Classic.text(stateText.uppercased(), 11, .semibold, stateColor, tracking: 0.3)
        let cardHeader = UIStackView(.horizontal, spacing: 6, alignment: .center, [dot(stateColor, 6), status, UIView(), slot])
        func metric(_ caption: String, _ value: UILabel) -> UIView {
            value.textColor = ink
            value.adjustsFontSizeToFitWidth = true
            value.minimumScaleFactor = 0.75
            return UIStackView(.vertical, spacing: 2, alignment: .leading, [Classic.mono(caption, 9, .secondaryLabel, weight: .medium, tracking: 0.4), value])
        }
        let pingValue = UILabel(entry?.result.milliseconds.map { "\($0) MS" } ?? "— MS", font: Theme.fixedMono(13, .semibold))
        tick()
        let place: UIView
        if let label {
            let line = Classic.text(label.text, 13, .medium)
            line.adjustsFontSizeToFitWidth = true
            line.minimumScaleFactor = 0.8
            place = UIStackView(.horizontal, spacing: 6, alignment: .center, [Classic.flag(label.countryCode, width: 18, height: 12), line])
        } else {
            place = Classic.text(state.isBusy ? L("Определяем…") : L("Локация не выбрана"), 13, .medium, .secondaryLabel)
        }
        let headline = Classic.text(stateText, 20, .semibold, lines: 2, tracking: -0.5)
        let left = UIStackView(.vertical, spacing: 5, alignment: .leading, [
            headline, place,
            UIStackView(.horizontal, spacing: 12, alignment: .top, [metric(L("СЕАНС"), session), metric(L("ТРАФИК"), traffic), metric(L("ПИНГ"), pingValue)]),
        ])
        let button = ClassicConnectButton(on: on, busy: state.isBusy)
        let cardBody = UIStackView(.horizontal, spacing: 12, alignment: .center, [left, button])
        let footer = UIStackView(.horizontal, spacing: 6, alignment: .center, [
            dot(on ? ink : .secondaryLabel, 5), Classic.mono(stateText, 10, ink.withAlphaComponent(0.85), tracking: 0.4), UIView(),
            Classic.mono(Prefs.autoSelect ? "PROXY · AUTO" : "PROXY · MANUAL", 10, ink.withAlphaComponent(0.85), tracking: 0.3),
        ])
        let card = UIStackView(.vertical, spacing: 0, alignment: .fill, [
            Classic.padded(cardHeader, UIEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)), Classic.rule(UIColor.black.withAlphaComponent(0.10)),
            Classic.padded(cardBody, UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 12)), Classic.rule(UIColor.black.withAlphaComponent(0.10)),
            Classic.padded(footer, UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)),
        ])
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.borderWidth = 1
        card.layer.borderColor = ink.cgColor
        cardBox.addSubview(card)
        card.pin(to: cardBox)

        // Location list: the mode card, the chosen server, then up to nine more.
        list.addArrangedSubview(ClassicModeCard(title: Prefs.autoSelect ? L("Автовыбор") : L("Пользовательский"),
                                                subtitle: (label?.text ?? "—").uppercased(),
                                                ping: entry?.result.milliseconds.map { "\($0) MS" } ?? "— MS"))
        if let subscription {
            let labels = app.store.labels(for: subscription)
            let selected = library.selectedNodeID(in: subscription)
            let shown = subscription.nodes.filter { $0.id == selected } + subscription.nodes.filter { $0.id != selected }.prefix(9)
            let rows = UIStackView(.vertical, spacing: 0, alignment: .fill, [])
            rows.backgroundColor = Theme.background
            for (offset, item) in shown.enumerated() {
                if offset > 0 { rows.addArrangedSubview(Classic.rule()) }
                let itemEntry = app.latency.entry(subscription.id, item.id)
                let id = subscription.id, tag = item.id
                rows.addArrangedSubview(ClassicLocationRow(
                    title: labels[item.id]?.text ?? item.name, meta: item.facts.summary, flag: labels[item.id]?.countryCode,
                    ping: Classic.ping(itemEntry, testing: app.latency.isTesting(subscription.id, item.id), upper: false),
                    limited: subscription.info.isLimited, selected: item.id == selected
                ) { App.shared.select(node: tag, in: id) })
            }
            list.addArrangedSubview(rows)
        }

        // Subscription card: system text sizes, as in 1.5.0.
        let folder = UIButton(type: .system)
        var folderConfig = UIButton.Configuration.plain()
        folderConfig.image = UIImage(systemName: "folder")
        folderConfig.imagePadding = 8
        folderConfig.contentInsets = .zero
        folderConfig.title = subscription?.name ?? L("Выбрать подписку")
        folderConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.font(.body)
            return attributes
        }
        folderConfig.titleLineBreakMode = .byTruncatingTail
        folder.configuration = folderConfig
        folder.tintColor = Theme.accent
        folder.contentHorizontalAlignment = .leading
        folder.addAction(UIAction { [weak self] _ in self?.present(ClassicSubscriptionsSheet.wrapped(), animated: true) }, for: .touchUpInside)
        let refresh = UIButton(type: .system)
        refresh.setImage(UIImage(systemName: "arrow.clockwise", withConfiguration: UIImage.SymbolConfiguration(textStyle: .body)), for: .normal)
        refresh.tintColor = Theme.accent
        refresh.isEnabled = !app.latency.progress.value.running
        refresh.accessibilityLabel = L("Обновить пинг")
        refresh.addAction(UIAction { _ in if let subscription = App.shared.library.activeSubscription { App.shared.ping([subscription]) } }, for: .touchUpInside)
        refresh.setContentHuggingPriority(.required, for: .horizontal)
        let check = UIButton(type: .system)
        check.setTitle(L("Проверка соединения и журнал"), for: .normal)
        check.titleLabel?.font = Theme.font(.body)
        check.tintColor = Theme.accent
        check.contentHorizontalAlignment = .leading
        check.addAction(UIAction { [weak self] _ in
            let root = DiagnosticsViewController()
            root.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak root] _ in root?.dismiss(animated: true) })
            self?.present(UINavigationController(rootViewController: root), animated: true)
        }, for: .touchUpInside)
        var quickLines: [UIView] = [
            UIStackView(.horizontal, spacing: 8, alignment: .center, [folder, UIView(), refresh]),
            UILabel(L("Прокси: Не проверено · Интернет: Не проверено"), font: Theme.font(.caption1), color: .secondaryLabel, lines: 0),
            check,
        ]
        if let entry {
            quickLines.append(UILabel(L("Задержка: ") + (app.tunnelSubscription != nil ? "HTTPS " : "TCP ") + Format.ago(entry.date), font: Theme.font(.caption2), color: .secondaryLabel))
        }
        quickLines.append(UILabel(L("Пинг и счётчики трафика не подтверждают доступ в интернет."), font: Theme.font(.caption2), color: .secondaryLabel, lines: 0))
        let quick = UIStackView(.vertical, spacing: 12, alignment: .fill, quickLines)
        let quickFrame = UIView()
        quickFrame.layer.borderWidth = 1
        quickFrame.layer.borderColor = Theme.line.cgColor
        quickFrame.addSubview(quick)
        quick.pin(to: quickFrame, insets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
        quickBox.addSubview(quickFrame)
        quickFrame.pin(to: quickBox)
        view.setNeedsLayout()
    }
}

/// The 96 pt square that connects and disconnects (1.5.0 `DirectHomeConnectButton`).
private final class ClassicConnectButton: TapControl {
    init(on: Bool, busy: Bool) {
        super.init(frame: .zero)
        pressScale = 1
        let ring = UIView()
        ring.layer.borderWidth = 2
        ring.layer.borderColor = UIColor.black.cgColor
        ring.layer.cornerRadius = 12
        let core = UIView()
        core.backgroundColor = .black
        core.layer.cornerRadius = 5.5
        let title = Classic.text(busy ? L("ОТМЕНА") : (on ? "DISCONNECT" : "CONNECT"), 10, .bold, .black)
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.7
        title.textAlignment = .center
        for item in [ring, core, title] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.isUserInteractionEnabled = false
            addSubview(item)
        }
        // Glyph (24) + 10 + title, centred in the square.
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 96), heightAnchor.constraint(equalToConstant: 96),
            ring.widthAnchor.constraint(equalToConstant: 24), ring.heightAnchor.constraint(equalToConstant: 24),
            ring.centerXAnchor.constraint(equalTo: centerXAnchor), ring.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            core.widthAnchor.constraint(equalToConstant: 11), core.heightAnchor.constraint(equalToConstant: 11),
            core.centerXAnchor.constraint(equalTo: ring.centerXAnchor), core.centerYAnchor.constraint(equalTo: ring.centerYAnchor),
            title.topAnchor.constraint(equalTo: ring.bottomAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
        backgroundColor = busy ? UIColor.systemOrange.withAlphaComponent(0.9) : (on ? Theme.accent : .white)
        layer.borderWidth = 1.5
        layer.borderColor = Theme.text.cgColor
        alpha = busy ? 0.85 : 1
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        accessibilityLabel = busy ? L("ОТМЕНА") : (on ? "DISCONNECT" : "CONNECT")
        onTap = { App.shared.toggleConnection() }
    }
}

/// Dark mode card at the top of the location list (1.5.0 `DirectHomeAutoLocationCard`).
private final class ClassicModeCard: UIView {
    init(title: String, subtitle: String, ping: String) {
        super.init(frame: .zero)
        backgroundColor = Theme.panel
        let tile = UIView()
        tile.backgroundColor = Theme.accent
        tile.layer.borderWidth = 1.4
        tile.layer.borderColor = Theme.text.cgColor
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([tile.widthAnchor.constraint(equalToConstant: 40), tile.heightAnchor.constraint(equalToConstant: 40)])
        let circles: [(side: CGFloat, filled: Bool)] = [(20, false), (11, false), (4.5, true)]
        for (side, filled) in circles {
            let circle = UIView()
            circle.layer.cornerRadius = side / 2
            if filled { circle.backgroundColor = .black } else { circle.layer.borderWidth = 1.7; circle.layer.borderColor = UIColor.black.cgColor }
            circle.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(circle)
            NSLayoutConstraint.activate([
                circle.widthAnchor.constraint(equalToConstant: side), circle.heightAnchor.constraint(equalToConstant: side),
                circle.centerXAnchor.constraint(equalTo: tile.centerXAnchor), circle.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            ])
        }
        let texts = UIStackView(.vertical, spacing: 3, alignment: .leading, [
            Classic.text(title, 15, .semibold, .white), Classic.text(subtitle, 9, .medium, UIColor.white.withAlphaComponent(0.45), tracking: 0.5),
        ])
        let right = UIStackView(.vertical, spacing: 2, alignment: .trailing, [
            Classic.text(ping, 13, .semibold, Theme.accent), Classic.text("BEST", 9, .semibold, .white, tracking: 0.6),
        ])
        right.setContentHuggingPriority(.required, for: .horizontal)
        right.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(.horizontal, spacing: 12, alignment: .center, [tile, texts, UIView(), right])
        addSubview(row)
        row.pin(to: self, insets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }
}

/// A server of the home list (1.5.0 `DirectHomeLocationRow`).
private final class ClassicLocationRow: TapControl {
    init(title: String, meta: String, flag: String?, ping: String, limited: Bool, selected: Bool, action: @escaping () -> Void) {
        super.init(frame: .zero)
        pressScale = 1
        let flagView = Classic.flag(flag)
        let flagBox = Classic.padded(flagView, UIEdgeInsets(top: 1, left: 0, bottom: 0, right: 12))
        let name = Classic.text(title, 15, .semibold)
        name.lineBreakMode = .byTruncatingTail
        let texts = UIStackView(.vertical, spacing: 2, alignment: .leading, [name, Classic.text(meta, 9, .medium, .secondaryLabel, tracking: 0.3)])
        if !limited {
            let note = Classic.text(L("ЛИМИТ НЕ УКАЗАН"), 10, .medium, Theme.accent)
            texts.addArrangedSubview(note)
            texts.setCustomSpacing(6, after: texts.arrangedSubviews[1])
        }
        let box = UIView()
        box.backgroundColor = selected ? Theme.accent : .white
        box.layer.borderWidth = 1.35
        box.layer.borderColor = Theme.text.cgColor
        if selected {
            let check = UIImageView(image: UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)))
            check.tintColor = .black
            check.contentMode = .center
            box.addSubview(check)
            check.pin(to: box)
        }
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([box.widthAnchor.constraint(equalToConstant: 18), box.heightAnchor.constraint(equalToConstant: 18)])
        let pingLabel = Classic.text(ping, 12)
        let right = UIStackView(.vertical, spacing: 5, alignment: .trailing, [UIStackView(.horizontal, spacing: 8, alignment: .center, [pingLabel, box])])
        if !limited {
            let dash = Classic.text("—", 12)
            dash.textAlignment = .center
            dash.widthAnchor.constraint(equalToConstant: 18).isActive = true
            right.addArrangedSubview(dash)
        }
        right.setContentHuggingPriority(.required, for: .horizontal)
        right.setContentCompressionResistancePriority(.required, for: .horizontal)
        let rightBox = Classic.padded(right, UIEdgeInsets(top: 1, left: 10, bottom: 0, right: 0))
        let row = UIStackView(.horizontal, spacing: 0, alignment: .top, [flagBox, texts, UIView(), rightBox])
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.pin(to: self, insets: UIEdgeInsets(top: 11, left: 10, bottom: 11, right: 10))
        onTap = action
    }
}

/// Sheet «Подписки»: saved profiles, the active one highlighted.
final class ClassicSubscriptionsSheet: ClassicPage {
    static func wrapped() -> UIViewController {
        let controller = ClassicSubscriptionsSheet()
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 0
        }
        controller.overrideUserInterfaceStyle = Theme.userInterfaceStyle
        return controller
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        App.shared.store.library.observe(self, fireNow: false) { [weak self] _ in self?.rebuild() }
    }

    override func build() {
        let library = App.shared.library
        content.spacing = 0
        let close = ClassicRow({ () -> UIView in
            let icon = UIImageView(image: UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)))
            icon.tintColor = Theme.accent
            icon.contentMode = .center
            return icon
        }()) { [weak self] in self?.dismiss(animated: true) }
        close.backgroundColor = Theme.panel
        close.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([close.widthAnchor.constraint(equalToConstant: 38), close.heightAnchor.constraint(equalToConstant: 38)])
        let dash = UIView()
        dash.backgroundColor = Theme.accent
        dash.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dash.widthAnchor.constraint(equalToConstant: 14), dash.heightAnchor.constraint(equalToConstant: 2)])
        let title = Classic.text(L("Подписки"), 34, .semibold)
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.8
        content.addArrangedSubview(UIStackView(.horizontal, spacing: 12, alignment: .bottom, [
            UIStackView(.vertical, spacing: 5, alignment: .leading, [
                UIStackView(.horizontal, spacing: 7, alignment: .center, [Classic.micro("01", Theme.accent), dash, Classic.micro(L("ПОДКЛЮЧЕНИЕ / ПОДПИСКИ"))]),
                title, Classic.text(L("Сохранённые профили на этом устройстве"), 11, .medium, .secondaryLabel),
            ]), UIView(), close,
        ]))
        content.setCustomSpacing(15, after: content.arrangedSubviews[0])
        content.addArrangedSubview(Classic.rule())
        let visible = library.subscriptions.filter { !$0.nodes.isEmpty }
        let count = UIStackView(.horizontal, spacing: 8, alignment: .center, [
            Classic.micro(L("ДОБАВЛЕННЫЕ ПОДПИСКИ"), Theme.text), UIView(), Classic.micro(String(format: "%02d", visible.count), Theme.accent),
        ])
        count.heightAnchor.constraint(equalToConstant: 36).isActive = true
        content.setCustomSpacing(18, after: content.arrangedSubviews[1])
        content.addArrangedSubview(Classic.rule(Theme.text))
        content.addArrangedSubview(count)
        let list = UIStackView(.vertical, spacing: 1, alignment: .fill, [])
        let active = library.activeSubscription?.id
        let formatter = DateFormatter()
        formatter.locale = Language.locale
        formatter.dateStyle = .medium
        let dark = traitCollection.userInterfaceStyle == .dark
        for subscription in visible {
            let isActive = subscription.id == active
            let tile = Classic.mono("URL", 10, isActive ? Theme.accent : Theme.text, weight: .bold)
            tile.textAlignment = .center
            tile.backgroundColor = dark ? .tertiarySystemBackground : (isActive ? Theme.text : UIColor.white.withAlphaComponent(0.72))
            tile.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([tile.widthAnchor.constraint(equalToConstant: 48), tile.heightAnchor.constraint(equalToConstant: 42)])
            var detail = (subscription.isRemote ? L("Внешний провайдер") : L("Добавлено вручную")) + " · " + Format.plural(subscription.nodes.count, L("локация"), L("локации"), L("локаций"))
            if let expires = subscription.info.expiresAt { detail += " · " + formatter.string(from: expires) }
            let name = Classic.text(subscription.name, 13, .semibold)
            name.lineBreakMode = .byTruncatingTail
            var titleViews: [UIView] = [name]
            if isActive { titleViews.append(Classic.micro(L("АКТИВНА"), Theme.accent)) }
            let mark = UIImageView(image: UIImage(systemName: isActive ? "checkmark" : "arrow.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)))
            mark.tintColor = isActive ? Theme.accent : .secondaryLabel
            mark.setContentHuggingPriority(.required, for: .horizontal)
            let detailLabel = Classic.text(detail, 10, .regular, .secondaryLabel)
            detailLabel.lineBreakMode = .byTruncatingTail
            let row = UIStackView(.horizontal, spacing: 12, alignment: .center, [
                tile, UIStackView(.vertical, spacing: 4, alignment: .leading, [UIStackView(.horizontal, spacing: 7, alignment: .center, titleViews), detailLabel]), UIView(), mark,
            ])
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true
            let id = subscription.id
            let control = ClassicRow(row, insets: UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)) { [weak self] in
                guard let target = App.shared.library.subscription(id), let node = App.shared.library.selectedNodeID(in: target) else { return }
                App.shared.select(node: node, in: id)
                self?.dismiss(animated: true)
            }
            control.layer.borderWidth = 1
            control.layer.borderColor = (isActive ? Theme.accent : Theme.line).cgColor
            control.backgroundColor = isActive ? Theme.accent.withAlphaComponent(0.16) : (dark ? .secondarySystemBackground : UIColor.white.withAlphaComponent(0.72))
            list.addArrangedSubview(control)
        }
        content.addArrangedSubview(list)
    }
}
