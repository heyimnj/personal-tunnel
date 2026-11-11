import TunnelCore
import UIKit

/// A rounded card of the analytics page.
final class AnalyticsCard: UIView {
    let stack = UIStackView(.vertical, spacing: 10, alignment: .leading, [])

    init() {
        super.init(frame: .zero)
        backgroundColor = Theme.card
        layer.cornerRadius = 28
        layer.cornerCurve = .continuous
        addSubview(stack)
        stack.pin(to: self, insets: UIEdgeInsets(top: 18, left: 18, bottom: 18, right: 18))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    static func title(_ symbol: String, _ text: String, tint: UIColor = .label, size: CGFloat = 15) -> UIStackView {
        let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular)))
        icon.tintColor = tint
        icon.setContentHuggingPriority(.required, for: .horizontal)
        return UIStackView(.horizontal, spacing: 8, alignment: .center, [icon, UILabel(text, font: Theme.font(size == 15 ? 13 : 17, .medium))])
    }
}

/// Small stat card: title, big value, grey caption.
final class StatCard: UIView {
    private let card = AnalyticsCard()
    let value = UILabel(font: Theme.font(24, .bold))
    let caption = UILabel(font: Theme.font(13), color: .secondaryLabel)

    init(symbol: String, title: String, tint: UIColor) {
        super.init(frame: .zero)
        addSubview(card)
        card.pin(to: self)
        card.stack.spacing = 14
        card.stack.addArrangedSubview(AnalyticsCard.title(symbol, title, tint: tint))
        card.stack.addArrangedSubview(value)
        card.stack.addArrangedSubview(caption)
        heightAnchor.constraint(equalToConstant: 134).isActive = true
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
    private let download = StatCard(symbol: "arrow.down", title: "Загрузка", tint: SpeedGraphView.downColor)
    private let upload = StatCard(symbol: "arrow.up", title: "Отдача", tint: SpeedGraphView.upColor)
    private let tcp = StatCard(symbol: "arrow.left.arrow.right", title: "TCP", tint: .systemIndigo)
    private let udp = StatCard(symbol: "arrow.up.arrow.down", title: "UDP", tint: .systemOrange)
    private let memory = StatCard(symbol: "memorychip", title: "Память ядра", tint: .systemPurple)
    private let delay = StatCard(symbol: "waveform", title: "Задержка", tint: .systemTeal)
    private let graph = SpeedGraphView()
    private let graphHint = UILabel("Данные появятся после подключения", font: Theme.font(13), color: .secondaryLabel)
    private let donut = DonutView()
    private let legend = UIStackView(.vertical, spacing: 10, alignment: .fill, [])
    private let session = UILabel(font: Theme.font(14), color: .secondaryLabel)
    private var timer: Timer?
    private var visible = false

    var isAtTop: Bool { scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 1 }
    func scrollToTop() { scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: true) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = true
        view.addSubview(scroll)
        scroll.pin(to: view)

        let title = UILabel("Аналитика", font: Theme.font(17, .semibold))
        title.textAlignment = .center
        let more = UIButton(type: .system)
        more.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold)), for: .normal)
        more.tintColor = Theme.accent
        more.showsMenuAsPrimaryAction = true
        more.menu = UIMenu(children: [UIAction(title: "Сбросить статистику") { _ in App.shared.core.resetStatistics() }])
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
        graphCard.stack.addArrangedSubview(AnalyticsCard.title("waveform.path.ecg", "Скорость за последние 2 минуты", size: 17))
        graph.heightAnchor.constraint(equalToConstant: 140).isActive = true
        graphCard.stack.addArrangedSubview(graph)
        func key(_ text: String, _ color: UIColor) -> UIView {
            let dot = UIView()
            dot.backgroundColor = color
            dot.layer.cornerRadius = 6
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 12), dot.heightAnchor.constraint(equalToConstant: 12)])
            return UIStackView(.horizontal, spacing: 8, alignment: .center, [dot, UILabel(text, font: Theme.font(13), color: color)])
        }
        graphCard.stack.addArrangedSubview(UIStackView(.horizontal, spacing: 14, alignment: .center, [key("Загрузка", SpeedGraphView.downColor), key("Отдача", SpeedGraphView.upColor), UIView()]))
        graphCard.stack.addArrangedSubview(graphHint)

        let routes = AnalyticsCard()
        routes.stack.alignment = .fill
        routes.stack.addArrangedSubview(AnalyticsCard.title("chart.pie", "Маршруты наблюдаемых соединений", size: 17))
        donut.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([donut.widthAnchor.constraint(equalToConstant: 104), donut.heightAnchor.constraint(equalToConstant: 104)])
        routes.stack.addArrangedSubview(UIStackView(.horizontal, spacing: 20, alignment: .center, [donut, legend]))
        routes.stack.addArrangedSubview(UILabel("Показаны только соединения, полученные от ядра во время наблюдения; это не весь трафик сеанса.", font: Theme.font(12), color: .secondaryLabel, lines: 0))

        func pair(_ left: UIView, _ right: UIView) -> UIStackView {
            let row = UIStackView(.horizontal, spacing: 14, alignment: .fill, [left, right])
            row.distribution = .fillEqually
            return row
        }
        let links = AnalyticsCard()
        links.stack.alignment = .fill
        links.stack.spacing = 0
        links.stack.addArrangedSubview(link("stethoscope", "Проверка соединения") { [weak self] in
            self?.navigationController?.pushViewController(DiagnosticsViewController(), animated: true)
        })
        let divider = UIView()
        divider.backgroundColor = .separator
        divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        links.stack.addArrangedSubview(divider)
        links.stack.addArrangedSubview(link("doc.text.magnifyingglass", "Журнал службы") { [weak self] in
            self?.navigationController?.pushViewController(ServiceLogViewController(), animated: true)
        })

        let content = UIStackView(.vertical, spacing: 16, alignment: .fill, [
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
        tcp.caption.text = "Активные соединения"
        udp.caption.text = "Активные соединения"

        let core = App.shared.core
        core.status.observe(self) { [weak self] in self?.show($0) }
        core.history.observe(self) { [weak self] history in
            guard let self, self.visible else { return }
            self.graph.history = history
        }
        core.connections.observe(self) { [weak self] in self?.show($0) }
        App.shared.latency.changed.observe(self) { [weak self] _ in self?.showDelay() }
        App.shared.tunnel.connectedSince.observe(self) { [weak self] _ in self?.tick() }
        showDelay()
    }

    private func link(_ symbol: String, _ title: String, action: @escaping () -> Void) -> UIView {
        let control = TapControl()
        let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19)))
        icon.tintColor = .label
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)))
        chevron.tintColor = .tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(.horizontal, spacing: 12, alignment: .center, [icon, UILabel(title, font: Theme.font(19)), UIView(), chevron])
        row.isUserInteractionEnabled = false
        control.addSubview(row)
        row.pin(to: control)
        control.heightAnchor.constraint(equalToConstant: 56).isActive = true
        control.onTap = action
        return control
    }

    /// Only the visible page keeps its timer and the detailed streams.
    func setVisible(_ value: Bool) {
        visible = value
        App.shared.core.setDetails(value)
        timer?.invalidate()
        timer = nil
        if value {
            graph.history = App.shared.core.history.value
            tick()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    private func tick() {
        let since = App.shared.tunnel.connectedSince.value
        session.text = "Сеанс: " + Format.duration(since.map { Int(Date().timeIntervalSince($0)) } ?? 0)
    }

    private func show(_ status: CoreStatus?) {
        download.value.text = Format.bytes(status?.downlinkTotal ?? 0)
        download.caption.text = Format.speed(status?.downlink ?? 0)
        upload.value.text = Format.bytes(status?.uplinkTotal ?? 0)
        upload.caption.text = Format.speed(status?.uplink ?? 0)
        memory.value.text = status.map { Format.bytes($0.memory) } ?? "—"
        memory.caption.text = status.map { "\($0.goroutines) goroutines" } ?? "Ядро не запущено"
        graphHint.isHidden = status != nil
    }

    private func show(_ connections: CoreConnections) {
        tcp.value.text = "\(connections.tcp)"
        udp.value.text = "\(connections.udp)"
        let top = connections.routes.sorted { $0.value > $1.value }.prefix(6)
        donut.shares = top.map(\.value)
        legend.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if top.isEmpty {
            legend.addArrangedSubview(UILabel("Данные соединений пока отсутствуют", font: Theme.font(13), color: .secondaryLabel, lines: 0))
        }
        for (index, route) in top.enumerated() {
            let dot = UIView()
            dot.backgroundColor = DonutView.palette[index % DonutView.palette.count]
            dot.layer.cornerRadius = 3
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6)])
            let name = UILabel(route.key, font: Theme.font(14))
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let amount = UILabel(Format.bytes(route.value), font: Theme.font(14))
            amount.setContentHuggingPriority(.required, for: .horizontal)
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
