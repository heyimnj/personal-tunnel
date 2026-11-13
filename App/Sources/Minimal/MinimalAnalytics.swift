import TunnelCore
import UIKit

/// A rounded card of the analytics page.
final class AnalyticsCard: UIView {
    let stack = UIStackView(.vertical, spacing: 10, alignment: .leading, [])

    init(insets: UIEdgeInsets = UIEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)) {
        super.init(frame: .zero)
        backgroundColor = Theme.card
        layer.cornerRadius = 28
        layer.cornerCurve = .continuous
        addSubview(stack)
        stack.pin(to: self, insets: insets)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    /// 1.5.0: small cards title in caption medium (6 pt gap), big cards in subheadline medium.
    static func title(_ symbol: String, _ text: String, tint: UIColor = .label, big: Bool = false) -> UIStackView {
        let font = Theme.font(big ? .subheadline : .caption1, .medium)
        let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: font)))
        icon.tintColor = tint
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = UILabel(text, font: font, lines: 0)
        return UIStackView(.horizontal, spacing: big ? 8 : 6, alignment: .center, [icon, label])
    }
}

/// Small stat card: title, big value, grey caption. With `onTap` it opens a
/// sheet (a chevron by the title says so) and dims while pressed.
final class StatCard: UIView {
    private let card = AnalyticsCard()
    let value = UILabel(font: UIFont.monospacedDigitSystemFont(ofSize: Theme.font(.title3).pointSize, weight: .semibold))
    let caption = UILabel(font: Theme.font(.caption1), color: .secondaryLabel, lines: 2)
    private let titleRow: UIStackView
    /// Holds the card; enabled only with `onTap`.
    private let press = TapControl()

    var onTap: (() -> Void)? {
        didSet {
            press.onTap = onTap
            press.isEnabled = onTap != nil
            press.isAccessibilityElement = onTap != nil
            guard onTap != nil, titleRow.arrangedSubviews.count == 2 else { return }
            let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(font: Theme.font(.caption2, .semibold))))
            chevron.tintColor = .tertiaryLabel
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            titleRow.addArrangedSubview(chevron)
            press.accessibilityTraits = .button
        }
    }

    init(symbol: String, title: String, tint: UIColor) {
        titleRow = AnalyticsCard.title(symbol, title, tint: tint)
        super.init(frame: .zero)
        press.pressScale = 1
        press.isEnabled = false
        press.accessibilityLabel = title
        addSubview(press)
        press.pin(to: self)
        card.isUserInteractionEnabled = false
        press.addSubview(card)
        card.pin(to: press)
        card.stack.spacing = 14
        card.stack.addArrangedSubview(titleRow)
        card.stack.addArrangedSubview(value)
        card.stack.addArrangedSubview(caption)
        value.adjustsFontSizeToFitWidth = true
        value.minimumScaleFactor = 0.7
        heightAnchor.constraint(greaterThanOrEqualToConstant: 136).isActive = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }
}

/// Download and upload speed over the last two minutes.
final class SpeedGraphView: UIView {
    private let down = CAShapeLayer()
    private let up = CAShapeLayer()
    private let grid = CAShapeLayer()
    static let downColor = UIColor(red: 0.33, green: 0.75, blue: 0.91, alpha: 1)
    static let upColor = UIColor(red: 0.93, green: 0.26, blue: 0.36, alpha: 1)
    var history = TrafficHistory() { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        grid.strokeColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        grid.lineWidth = 0.5
        for (layer, color) in [(down, SpeedGraphView.downColor), (up, SpeedGraphView.upColor)] {
            layer.fillColor = nil
            layer.strokeColor = color.cgColor
            layer.lineWidth = 2
            layer.lineJoin = .round
            layer.lineCap = .round
        }
        layer.addSublayer(grid)
        layer.addSublayer(down)
        layer.addSublayer(up)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let lines = UIBezierPath()
        for index in 0 ..< 3 {
            let y = bounds.height * CGFloat(index) / 3
            lines.move(to: CGPoint(x: 0, y: y))
            lines.addLine(to: CGPoint(x: bounds.width, y: y))
        }
        grid.path = lines.cgPath
        let peak = max(1, (history.down + history.up).max() ?? 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        down.path = path(history.down, peak: peak)
        up.path = path(history.up, peak: peak)
        CATransaction.commit()
    }

    private func path(_ samples: [Int64], peak: Int64) -> CGPath {
        let path = UIBezierPath()
        let count = TrafficHistory.capacity
        let step = bounds.width / CGFloat(count - 1)
        let base = bounds.height - 1
        let offset = count - samples.count
        path.move(to: CGPoint(x: 0, y: base))
        if offset > 0 { path.addLine(to: CGPoint(x: CGFloat(offset) * step, y: base)) }
        for (index, sample) in samples.enumerated() {
            let y = base - CGFloat(sample) / CGFloat(peak) * (bounds.height - 6)
            path.addLine(to: CGPoint(x: CGFloat(offset + index) * step, y: y))
        }
        return path.cgPath
    }
}

/// Ring chart of traffic per server.
final class DonutView: UIView {
    static let palette: [UIColor] = [SpeedGraphView.downColor, UIColor(red: 0.37, green: 0.33, blue: 0.91, alpha: 1), .systemOrange, .systemGreen, .systemPink, .systemTeal]
    var shares: [Int64] = [] { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let width: CGFloat = 14
        let radius = min(bounds.width, bounds.height) / 2 - width / 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let total = shares.reduce(0, +)
        context.setLineWidth(width)
        guard total > 0 else {
            context.setStrokeColor(UIColor.separator.withAlphaComponent(0.4).cgColor)
            context.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            context.strokePath()
            return
        }
        var angle = -CGFloat.pi / 2
        for (index, share) in shares.enumerated() {
            let sweep = CGFloat(share) / CGFloat(total) * .pi * 2
            context.setStrokeColor(DonutView.palette[index % DonutView.palette.count].cgColor)
            context.addArc(center: center, radius: radius, startAngle: angle, endAngle: angle + sweep, clockwise: false)
            context.strokePath()
            angle += sweep
        }
    }
}

/// The second Home page.
final class MinimalAnalyticsViewController: UIViewController {
    private let scroll = HandoffScrollView()
    private let download = StatCard(symbol: "arrow.down", title: L("Загрузка"), tint: SpeedGraphView.downColor)
    private let upload = StatCard(symbol: "arrow.up", title: L("Отдача"), tint: SpeedGraphView.upColor)
    private let tcp = StatCard(symbol: "arrow.left.arrow.right", title: "TCP", tint: .systemIndigo)
    private let udp = StatCard(symbol: "arrow.up.arrow.down", title: "UDP", tint: .systemOrange)
    private let memory = StatCard(symbol: "memorychip", title: L("Память ядра"), tint: .systemPurple)
    private let delay = StatCard(symbol: "waveform", title: L("Задержка"), tint: .systemTeal)
    private let graph = SpeedGraphView()
    private let graphHint = UILabel(L("Данные появятся после подключения"), font: Theme.font(.caption1), color: .secondaryLabel)
    private let donut = DonutView()
    private let legend = UIStackView(.vertical, spacing: 8, alignment: .fill, [])
    private let routesEmpty = UILabel(L("Данные соединений пока недоступны"), font: Theme.font(.caption1), color: .secondaryLabel, lines: 0)
    private var routesChart: UIView?
    private let session = UILabel(font: UIFont.monospacedDigitSystemFont(ofSize: Theme.font(.footnote).pointSize, weight: .regular), color: .secondaryLabel)
    private var timer: Timer?
    private var visible = false

    var isAtTop: Bool { scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 1 }

    /// A pull past the top, handed to the pager (see HandoffScrollView).
    var onPull: ((CGFloat) -> Void)? {
        get { scroll.onPull }
        set { scroll.onPull = newValue }
    }

    var onPullEnd: ((CGFloat) -> Void)? {
        get { scroll.onPullEnd }
        set { scroll.onPullEnd = newValue }
    }

    var onHandOff: ((CGFloat) -> Void)? {
        get { scroll.onHandOff }
        set { scroll.onHandOff = newValue }
    }

    /// The screen's insets (status bar, tab bar), set by Home.
    var pageInsets: UIEdgeInsets = .zero {
        didSet {
            guard pageInsets != oldValue else { return }
            loadViewIfNeeded()
            let atTop = scroll.contentOffset.y <= -oldValue.top + 1
            let insets = UIEdgeInsets(top: pageInsets.top, left: 0, bottom: pageInsets.bottom, right: 0)
            scroll.contentInset = insets
            scroll.verticalScrollIndicatorInsets = insets
            if atTop { scroll.contentOffset = CGPoint(x: 0, y: -insets.top) }
        }
    }
    func scrollToTop() { scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: true) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        scroll.alwaysBounceVertical = true
        // The page's insets come from Home (see pageInsets), never from UIKit: inside
        // the pager UIKit hands this page its status-bar inset late, which first
        // left the title under the status bar and then pushed it too low.
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsVerticalScrollIndicator = true
        view.addSubview(scroll)
        scroll.pin(to: view)

        let title = UILabel(L("Аналитика"), font: Theme.font(17, .semibold))
        title.textAlignment = .center
        let more = UIButton(type: .system)
        more.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold)), for: .normal)
        more.tintColor = Theme.accent
        more.showsMenuAsPrimaryAction = true
        more.menu = UIMenu(children: [UIAction(title: L("Сбросить статистику")) { _ in App.shared.core.resetStatistics() }])
        let moreGlass = GlassView()
        moreGlass.isUserInteractionEnabled = false
        let header = UIView()
        for item in [title, moreGlass, more] as [UIView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(item)
        }
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 56),
            title.centerXAnchor.constraint(equalTo: header.centerXAnchor), title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            more.trailingAnchor.constraint(equalTo: header.trailingAnchor), more.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            more.widthAnchor.constraint(equalToConstant: 44), more.heightAnchor.constraint(equalToConstant: 44),
            moreGlass.centerXAnchor.constraint(equalTo: more.centerXAnchor), moreGlass.centerYAnchor.constraint(equalTo: more.centerYAnchor),
            moreGlass.widthAnchor.constraint(equalToConstant: 44), moreGlass.heightAnchor.constraint(equalToConstant: 44),
        ])

        let graphCard = AnalyticsCard()
        graphCard.stack.alignment = .fill
        graphCard.stack.spacing = 14
        graphCard.stack.addArrangedSubview(AnalyticsCard.title("waveform.path.ecg", L("Скорость за последние 2 минуты"), big: true))
        graph.heightAnchor.constraint(equalToConstant: 140).isActive = true
        graphCard.stack.addArrangedSubview(graph)
        func key(_ text: String, _ color: UIColor) -> UIView {
            let dot = UIView()
            dot.backgroundColor = color
            dot.layer.cornerRadius = 6
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 12), dot.heightAnchor.constraint(equalToConstant: 12)])
            return UIStackView(.horizontal, spacing: 6, alignment: .center, [dot, UILabel(text, font: Theme.font(.caption1), color: color)])
        }
        graphCard.stack.addArrangedSubview(UIStackView(.horizontal, spacing: 14, alignment: .center, [key(L("Загрузка"), SpeedGraphView.downColor), key(L("Отдача"), SpeedGraphView.upColor), UIView()]))
        // Over the graph, not under it: when data comes the card keeps its height
        // (a card that changed height moved the page under a scrolling finger).
        graphHint.textAlignment = .center
        graphHint.numberOfLines = 0
        graph.addSubview(graphHint)
        graphHint.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            graphHint.centerYAnchor.constraint(equalTo: graph.centerYAnchor), graphHint.leadingAnchor.constraint(equalTo: graph.leadingAnchor, constant: 12),
            graphHint.trailingAnchor.constraint(equalTo: graph.trailingAnchor, constant: -12),
        ])

        let routes = AnalyticsCard()
        routes.stack.alignment = .fill
        routes.stack.spacing = 14
        routes.stack.addArrangedSubview(AnalyticsCard.title("chart.pie", L("Маршруты наблюдаемых соединений"), big: true))
        // 1.5.0: an 88 pt ring with 8 pt around it. It is always there (grey with
        // «no data» beside it until connections come), so the card never changes
        // height while the page is scrolled: that moved everything below it.
        donut.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([donut.widthAnchor.constraint(equalToConstant: 88), donut.heightAnchor.constraint(equalToConstant: 88)])
        legend.spacing = 6
        legend.addArrangedSubview(routesEmpty)
        let chart = UIStackView(.horizontal, spacing: 18, alignment: .center, [Classic.padded(donut, UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)), legend])
        routesChart = chart
        routes.stack.addArrangedSubview(chart)
        routes.stack.addArrangedSubview(UILabel(L("Показаны только соединения, полученные от ядра во время наблюдения; это не весь трафик сеанса."), font: Theme.font(.caption2), color: .secondaryLabel, lines: 0))

        func pair(_ left: UIView, _ right: UIView) -> UIStackView {
            let row = UIStackView(.horizontal, spacing: 12, alignment: .fill, [left, right])
            row.distribution = .fillEqually
            return row
        }
        let links = AnalyticsCard(insets: UIEdgeInsets(top: 0, left: 18, bottom: 0, right: 18))
        links.stack.alignment = .fill
        links.stack.spacing = 0
        links.stack.addArrangedSubview(link("stethoscope", L("Проверка соединения")) { [weak self] in
            self?.navigationController?.pushViewController(DiagnosticsViewController(), animated: true)
        })
        let divider = UIView()
        divider.backgroundColor = .separator
        divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        links.stack.addArrangedSubview(Classic.padded(divider, UIEdgeInsets(top: 0, left: 30, bottom: 0, right: 0)))
        links.stack.addArrangedSubview(link("doc.text.magnifyingglass", L("Журнал службы")) { [weak self] in
            self?.navigationController?.pushViewController(ServiceLogViewController(), animated: true)
        })

        let content = UIStackView(.vertical, spacing: 18, alignment: .fill, [
            header, pair(download, upload), graphCard, routes, pair(tcp, udp), pair(memory, delay), session, links,
        ])
        content.setCustomSpacing(4, after: header)
        scroll.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
        tcp.caption.text = L("Активные соединения")
        udp.caption.text = L("Активные соединения")
        tcp.onTap = { [weak self] in self?.present(ConnectionsViewController.wrapped(udp: false), animated: true) }
        udp.onTap = { [weak self] in self?.present(ConnectionsViewController.wrapped(udp: true), animated: true) }

        let core = App.shared.core
        core.status.observe(self) { [weak self] in self?.show($0) }
        core.history.observe(self) { [weak self] history in
            guard let self, self.visible else { return }
            self.graph.history = history
        }
        core.connections.observe(self) { [weak self] connections in
            guard let self, self.visible else { return }
            self.show(connections)
        }
        App.shared.latency.changed.observe(self) { [weak self] _ in self?.showDelay() }
        App.shared.tunnel.connectedSince.observe(self) { [weak self] _ in self?.tick() }
        showDelay()
    }

    private func link(_ symbol: String, _ title: String, action: @escaping () -> Void) -> UIView {
        let control = TapControl()
        // 1.5.0 destination row: a body-style label with its icon, 18 pt padding.
        let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: Theme.font(.body))))
        icon.tintColor = .label
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(font: Theme.font(.caption1, .semibold))))
        chevron.tintColor = .secondaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(.horizontal, spacing: 12, alignment: .center, [icon, UILabel(title, font: Theme.font(.body)), UIView(), chevron])
        row.isUserInteractionEnabled = false
        control.addSubview(row)
        row.pin(to: control, insets: UIEdgeInsets(top: 18, left: 0, bottom: 18, right: 0))
        control.pressScale = 1
        control.onTap = action
        return control
    }

    /// Only the visible page keeps its timer and the detailed streams.
    func setVisible(_ value: Bool) {
        visible = value
        App.shared.core.setConnectionsStreamed(value)
        timer?.invalidate()
        timer = nil
        if value {
            // The first redraw in two steps: the graph and the session now, the
            // routes legend (views built) on the next turn of the run loop.
            graph.history = App.shared.core.history.value
            DispatchQueue.main.async { [weak self] in
                guard let self, self.visible else { return }
                self.show(App.shared.core.connections.value)
            }
            tick()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    private func tick() {
        let since = App.shared.tunnel.connectedSince.value
        session.text = L("Сеанс: ") + Format.duration(since.map { Int(Date().timeIntervalSince($0)) } ?? 0)
    }

    private func show(_ status: CoreStatus?) {
        download.value.text = Format.bytes(status?.downlinkTotal ?? 0)
        download.caption.text = Format.speed(status?.downlink ?? 0)
        upload.value.text = Format.bytes(status?.uplinkTotal ?? 0)
        upload.caption.text = Format.speed(status?.uplink ?? 0)
        memory.value.text = status.map { Format.bytes($0.memory) } ?? "—"
        memory.caption.text = status.map { "\($0.goroutines) goroutines" } ?? L("Ядро не запущено")
        graphHint.isHidden = status != nil
    }

    /// Names in the legend, in order; the rows are rebuilt only when they change.
    private var legendNames: [String] = []
    private var legendAmounts: [UILabel] = []
    /// Five rows fit beside the ring, so the card's height stays the same.
    private static let legendRows = 5

    private func show(_ connections: CoreConnections) {
        let tcpText = "\(connections.tcp)", udpText = "\(connections.udp)"
        if tcp.value.text != tcpText { tcp.value.text = tcpText }
        if udp.value.text != udpText { udp.value.text = udpText }
        let top = Array(connections.routes.sorted { $0.value > $1.value }.prefix(Self.legendRows))
        let shares = top.map(\.value)
        if donut.shares != shares { donut.shares = shares }
        let names = top.map(\.key)
        if names.isEmpty {
            if !legendNames.isEmpty || routesEmpty.superview == nil {
                legendNames = []
                legendAmounts = []
                legend.arrangedSubviews.forEach { $0.removeFromSuperview() }
                legend.addArrangedSubview(routesEmpty)
            }
            return
        }
        if names == legendNames, routesEmpty.superview == nil {
            for (label, route) in zip(legendAmounts, top) {
                let text = Format.bytes(route.value)
                if label.text != text { label.text = text }
            }
            return
        }
        legendNames = names
        legendAmounts = []
        legend.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, route) in top.enumerated() {
            let dot = UIView()
            dot.backgroundColor = DonutView.palette[index % DonutView.palette.count]
            dot.layer.cornerRadius = 3
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6)])
            let name = UILabel(route.key, font: Theme.font(.caption1))
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let amount = UILabel(Format.bytes(route.value), font: Theme.font(.caption1))
            amount.setContentHuggingPriority(.required, for: .horizontal)
            legendAmounts.append(amount)
            legend.addArrangedSubview(UIStackView(.horizontal, spacing: 10, alignment: .center, [dot, name, amount]))
        }
    }

    private func showDelay() {
        let library = App.shared.library
        if let subscription = library.activeSubscription, let node = library.activeNode,
           let entry = App.shared.latency.entry(subscription.id, node.id)
        {
            switch entry.result {
            case let .delay(value): delay.value.text = "\(value) MS"
            case let .failed(reason): delay.value.text = reason.title
            }
        } else {
            delay.value.text = "— MS"
        }
        delay.caption.text = Prefs.pingMode == "alternative" ? "HTTP" : "HTTPS"
    }
}

/// The TCP or UDP connections, as 1.5.0 showed them: a sheet with «Готово» and a
/// card per connection — a dot (green while open), where it goes, through which
/// server, and the bytes each way. Live: the core sends the list only while
/// this sheet is open (`CoreClient.listsConnections`).
final class ConnectionsViewController: UIViewController, UITableViewDataSource {
    private let udp: Bool
    private let table = UITableView(frame: .zero, style: .plain)
    private let empty = UILabel(L("Данные соединений пока недоступны"), font: Theme.font(.body), color: .secondaryLabel, lines: 0)
    private var items: [CoreConnection] = []

    static func wrapped(udp: Bool) -> UIViewController {
        let navigation = UINavigationController(rootViewController: ConnectionsViewController(udp: udp))
        navigation.modalPresentationStyle = .pageSheet
        return navigation
    }

    init(udp: Bool) {
        self.udp = udp
        super.init(nibName: nil, bundle: nil)
        title = udp ? "UDP" : "TCP"
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("Готово"), primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.allowsSelection = false
        table.dataSource = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 96
        table.contentInset = UIEdgeInsets(top: 10, left: 0, bottom: 30, right: 0)
        table.register(ConnectionCell.self, forCellReuseIdentifier: "connection")
        view.addSubview(table)
        table.pin(to: view)
        view.addSubview(empty)
        empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            empty.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            empty.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            empty.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        App.shared.core.connections.observe(self) { [weak self] in self?.show($0) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        App.shared.core.listsConnections = true
        show(App.shared.core.connections.value)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        App.shared.core.listsConnections = false
    }

    private func show(_ connections: CoreConnections) {
        let next = connections.open.filter { $0.udp == udp }.sorted { $0.createdAt > $1.createdAt }
        empty.isHidden = !next.isEmpty
        guard next != items else { return }
        let sameRows = next.map(\.id) == items.map(\.id)
        items = next
        if sameRows {
            // Only the numbers moved: update the cards in place, no reload flicker.
            for cell in table.visibleCells {
                guard let cell = cell as? ConnectionCell, let row = table.indexPath(for: cell)?.row, items.indices.contains(row) else { continue }
                cell.show(items[row])
            }
        } else {
            table.reloadData()
        }
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { items.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "connection", for: indexPath)
        (cell as? ConnectionCell)?.show(items[indexPath.row])
        return cell
    }
}

/// One connection card (1.5.0): dot and destination, the server, ↑ and ↓.
private final class ConnectionCell: UITableViewCell {
    private let dot = UIView()
    private let destination = UILabel(font: Theme.font(.callout), lines: 2)
    private let outbound = UILabel(font: Theme.font(.caption1), color: .secondaryLabel)
    private let traffic = UILabel(font: UIFont.monospacedDigitSystemFont(ofSize: Theme.font(.caption1).pointSize, weight: .regular))

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let card = AnalyticsCard(insets: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        card.stack.spacing = 8
        dot.backgroundColor = .systemGreen
        dot.layer.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7)])
        destination.lineBreakMode = .byTruncatingMiddle
        card.stack.addArrangedSubview(UIStackView(.horizontal, spacing: 8, alignment: .center, [dot, destination]))
        card.stack.addArrangedSubview(outbound)
        card.stack.addArrangedSubview(traffic)
        contentView.addSubview(card)
        card.pin(to: contentView, insets: UIEdgeInsets(top: 8, left: 20, bottom: 8, right: 20))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func show(_ item: CoreConnection) {
        destination.text = item.destination
        outbound.text = item.chain.isEmpty ? (item.outbound.isEmpty ? "—" : item.outbound) : item.chain.joined(separator: " → ")
        traffic.text = "↑ " + Format.bytes(item.uploadTotal) + "   ↓ " + Format.bytes(item.downloadTotal)
    }
}
