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

/// Download and upload speed over the last two minutes.
final class SpeedGraphView: UIView {
    private let down = CAShapeLayer()
    private let up = CAShapeLayer()
    private let grid = CAShapeLayer()
    /// 3.5: a soft wash under the download line.
    private let wash = CAGradientLayer()
    private let washShape = CAShapeLayer()
    /// The dashed lines across; off where the graph stands without a card.
    var showsGrid = true { didSet { grid.isHidden = !showsGrid } }
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
        // Nothing is drawn outside the graph's own box.
        layer.masksToBounds = true
        wash.colors = [SpeedGraphView.downColor.withAlphaComponent(0.26).cgColor, SpeedGraphView.downColor.withAlphaComponent(0).cgColor]
        wash.mask = washShape
        layer.addSublayer(wash)
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
        let downPath = path(history.down, peak: peak)
        down.path = downPath
        up.path = path(history.up, peak: peak)
        wash.frame = bounds
        let area = UIBezierPath(cgPath: downPath)
        area.addLine(to: CGPoint(x: bounds.width, y: bounds.height))
        area.addLine(to: CGPoint(x: 0, y: bounds.height))
        area.close()
        washShape.path = area.cgPath
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
            let share = min(1, max(0, CGFloat(sample) / CGFloat(peak)))
            let y = base - share * (bounds.height - 6)
            path.addLine(to: CGPoint(x: CGFloat(offset + index) * step, y: y))
        }
        return path.cgPath
    }
}

/// A thin rounded bar split into coloured parts (3.5): what a number is made
/// of, at a glance — download against upload, TCP against UDP, the routes, how
/// full the core's memory is. Parts are laid out by frame; nothing is redrawn.
final class MeterBar: UIView {
    /// (share, colour); shares are relative to each other, or to `total` when set.
    var parts: [(value: Double, color: UIColor)] = [] { didSet { rebuild() } }
    /// With a total the bar is that long and the parts fill only their share of it.
    var total: Double? { didSet { setNeedsLayout() } }
    private var pieces: [UIView] = []
    private static let gap: CGFloat = 2

    init(height: CGFloat = 8) {
        super.init(frame: .zero)
        backgroundColor = UIColor.label.withAlphaComponent(0.07)
        layer.cornerRadius = height / 2
        layer.cornerCurve = .continuous
        clipsToBounds = true
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func rebuild() {
        if pieces.count != parts.count {
            pieces.forEach { $0.removeFromSuperview() }
            pieces = parts.map { _ in UIView() }
            pieces.forEach(addSubview)
        }
        for (piece, part) in zip(pieces, parts) { piece.backgroundColor = part.color }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let sum = parts.reduce(0) { $0 + max(0, $1.value) }
        let whole = max(sum, total ?? 0)
        guard whole > 0 else { pieces.forEach { $0.frame = .zero }; return }
        let shown = parts.filter { $0.value > 0 }.count
        let room = bounds.width - Self.gap * CGFloat(max(0, shown - 1))
        var x: CGFloat = 0
        for (piece, part) in zip(pieces, parts) {
            let width = part.value > 0 ? room * CGFloat(part.value / whole) : 0
            piece.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            if width > 0 { x += width + Self.gap }
        }
    }
}

/// A ring split between parts (3.5): the session's traffic, download against
/// upload, with the total in the middle.
final class RingChart: UIView {
    var parts: [(value: Double, color: UIColor)] = [] { didSet { setNeedsDisplay() } }
    var lineWidth: CGFloat = 11

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func draw(_: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let radius = min(bounds.width, bounds.height) / 2 - lineWidth / 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setStrokeColor(UIColor.label.withAlphaComponent(0.07).cgColor)
        context.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        context.strokePath()
        let shown = parts.filter { $0.value > 0 }
        let total = shown.reduce(0) { $0 + $1.value }
        guard total > 0 else { return }
        // A small gap between parts, where the round caps meet.
        let gap = shown.count > 1 ? lineWidth / radius * 1.1 : 0
        var angle = -CGFloat.pi / 2
        for part in shown {
            let sweep = CGFloat(part.value / total) * .pi * 2
            let drawn = max(0.001, sweep - gap)
            context.setStrokeColor(part.color.cgColor)
            context.addArc(center: center, radius: radius, startAngle: angle + gap / 2, endAngle: angle + gap / 2 + drawn, clockwise: false)
            context.strokePath()
            angle += sweep
        }
    }
}

/// A half-circle gauge (3.5): the connected server's delay. Its track is
/// tinted green, orange and red where those values lie; the arc fills up to the
/// value in its own colour and a dot marks the end.
final class GaugeView: UIView {
    /// The value and the scale's end; nil: no value (only the track).
    var value: Double? { didSet { setNeedsDisplay() } }
    var maximum: Double = 600
    /// Where the colours change, ascending, with the colour below each.
    var zones: [(upTo: Double, color: UIColor)] = [(150, .systemGreen), (400, .systemOrange), (.infinity, .systemRed)]
    var lineWidth: CGFloat = 10

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func color(for value: Double) -> UIColor {
        zones.first { value <= $0.upTo }?.color ?? .systemRed
    }

    override func draw(_: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let radius = min(bounds.width / 2, bounds.height) - lineWidth / 2 - 1
        let center = CGPoint(x: bounds.midX, y: bounds.maxY - 1)
        func angle(_ v: Double) -> CGFloat { .pi + CGFloat(min(max(v / maximum, 0), 1)) * .pi }
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        // The track, tinted by zone.
        var start = 0.0
        for zone in zones {
            let end = min(zone.upTo, maximum)
            guard end > start else { continue }
            context.setStrokeColor(zone.color.withAlphaComponent(0.16).cgColor)
            context.setLineCap(.butt)
            context.addArc(center: center, radius: radius, startAngle: angle(start), endAngle: angle(end), clockwise: false)
            context.strokePath()
            start = end
        }
        guard let value else { return }
        let tint = color(for: value)
        context.setLineCap(.round)
        context.setStrokeColor(tint.cgColor)
        context.addArc(center: center, radius: radius, startAngle: .pi, endAngle: max(.pi + 0.001, angle(value)), clockwise: false)
        context.strokePath()
        let tip = CGPoint(x: center.x + radius * cos(angle(value)), y: center.y + radius * sin(angle(value)))
        let dot = lineWidth * 0.42
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: tip.x - dot, y: tip.y - dot, width: dot * 2, height: dot * 2))
    }
}

/// An area line over time (3.5): the core's memory in the last two minutes,
/// scaled to the extension's limit, which shows as a dashed line when it is near.
final class SparklineView: UIView {
    var values: [Double] = [] { didSet { setNeedsDisplay() } }
    var capacity = 120
    var color: UIColor = .systemPurple { didSet { setNeedsDisplay() } }
    /// The top of the scale; the line of the limit is drawn when values reach half of it.
    var ceiling: Double = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func draw(_: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let peak = values.max() ?? 0
        // Scaled to what is drawn, with room above; the limit only when it matters.
        let top = max(peak * 1.25, ceiling * 0.5, 1)
        let showsLimit = peak > ceiling * 0.5
        let scale = showsLimit ? max(top, ceiling * 1.05) : top
        let height = bounds.height - 2
        func y(_ v: Double) -> CGFloat { bounds.height - 1 - CGFloat(v / scale) * height }
        if showsLimit {
            context.setStrokeColor(UIColor.systemRed.withAlphaComponent(0.5).cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [3, 3])
            context.move(to: CGPoint(x: 0, y: y(ceiling)))
            context.addLine(to: CGPoint(x: bounds.width, y: y(ceiling)))
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
        }
        guard values.count > 1 else { return }
        let step = bounds.width / CGFloat(max(1, capacity - 1))
        let offset = CGFloat(capacity - values.count) * step
        let line = UIBezierPath()
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: offset + CGFloat(index) * step, y: y(value))
            if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
        }
        let area = UIBezierPath(cgPath: line.cgPath)
        area.addLine(to: CGPoint(x: bounds.width, y: bounds.height))
        area.addLine(to: CGPoint(x: offset, y: bounds.height))
        area.close()
        context.saveGState()
        context.addPath(area.cgPath)
        context.clip()
        let colors = [color.withAlphaComponent(0.3).cgColor, color.withAlphaComponent(0).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: bounds.height), options: [])
        }
        context.restoreGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(2)
        context.setLineJoin(.round)
        context.addPath(line.cgPath)
        context.strokePath()
    }
}

/// Columns over time, two series stacked (3.5): the open TCP and UDP
/// connections in the last minute, a column every two seconds.
final class ColumnsView: UIView {
    var lower: [Int] = [] { didSet { setNeedsDisplay() } }
    var upper: [Int] = [] { didSet { setNeedsDisplay() } }
    var lowerColor: UIColor = .systemIndigo
    var upperColor: UIColor = .systemOrange
    var columns = 30

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func draw(_: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let count = min(lower.count, upper.count)
        let gap: CGFloat = 3
        let width = (bounds.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let peak = CGFloat(max(4, zip(lower, upper).map { $0 + $1 }.max() ?? 0))
        // Empty places first: the columns come in from the right.
        for slot in 0 ..< columns {
            let x = CGFloat(slot) * (width + gap)
            let index = count - columns + slot
            context.setFillColor(UIColor.label.withAlphaComponent(0.05).cgColor)
            context.addPath(UIBezierPath(roundedRect: CGRect(x: x, y: 0, width: width, height: bounds.height), cornerRadius: min(3, width / 2)).cgPath)
            context.fillPath()
            guard index >= 0 else { continue }
            let below = CGFloat(lower[index]) / peak * bounds.height
            let above = CGFloat(upper[index]) / peak * bounds.height
            let column = CGRect(x: x, y: bounds.height - below - above, width: width, height: below + above)
            guard column.height > 0.5 else { continue }
            context.saveGState()
            context.addPath(UIBezierPath(roundedRect: column, cornerRadius: min(3, width / 2)).cgPath)
            context.clip()
            context.setFillColor(upperColor.cgColor)
            context.fill(CGRect(x: x, y: column.minY, width: width, height: above))
            context.setFillColor(lowerColor.cgColor)
            context.fill(CGRect(x: x, y: bounds.height - below, width: width, height: below))
            context.restoreGState()
        }
    }
}

/// A grouped card of rows, as the settings draw them (3.5, the owner's
/// «вариант A»): a list a glance runs down, with small charts where they help.
final class AnalyticsGroup: UIView {
    let stack = UIStackView(.vertical, spacing: 0, alignment: .fill, [])

    init() {
        super.init(frame: .zero)
        backgroundColor = Theme.card
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        addSubview(stack)
        stack.pin(to: self, insets: UIEdgeInsets(top: 2, left: 16, bottom: 2, right: 16))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func add(_ views: [UIView]) {
        for view in views {
            if !stack.arrangedSubviews.isEmpty {
                let line = UIView()
                line.backgroundColor = UIColor.separator.withAlphaComponent(0.5)
                line.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
                stack.addArrangedSubview(line)
            }
            stack.addArrangedSubview(view)
        }
    }

    /// The caption above a group: small capitals in the secondary colour.
    static func caption(_ text: String) -> UIView {
        let label = UILabel(text.uppercased(), font: Theme.font(.footnote), color: .secondaryLabel)
        return Classic.padded(label, UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6))
    }
}

/// One row: a title and its value, a meter under them when it has one, and a
/// chevron when it opens something.
final class AnalyticsRow: UIView {
    let title = UILabel(font: Theme.font(.body))
    let value = UILabel(font: UIFont.monospacedDigitSystemFont(ofSize: Theme.font(.body).pointSize, weight: .regular), color: .secondaryLabel)
    let meter: MeterBar?
    private let press = TapControl()

    init(_ text: String, meter: Bool = false, dot: UIColor? = nil, onTap: (() -> Void)? = nil) {
        self.meter = meter ? MeterBar() : nil
        super.init(frame: .zero)
        title.text = text
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        value.textAlignment = .right
        value.setContentHuggingPriority(.required, for: .horizontal)
        var line: [UIView] = []
        if let dot {
            let mark = UIView()
            mark.backgroundColor = dot
            mark.layer.cornerRadius = 5
            mark.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([mark.widthAnchor.constraint(equalToConstant: 10), mark.heightAnchor.constraint(equalToConstant: 10)])
            line.append(mark)
        }
        line += [title, UIView(), value]
        if onTap != nil {
            let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(font: Theme.font(.footnote, .semibold))))
            chevron.tintColor = .tertiaryLabel
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            line.append(chevron)
        }
        let top = UIStackView(.horizontal, spacing: 10, alignment: .center, line)
        top.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        let column = UIStackView(.vertical, spacing: 9, alignment: .fill, [top] + (self.meter.map { [$0] } ?? []))
        column.isUserInteractionEnabled = false
        press.pressScale = 1
        press.onTap = onTap
        press.isEnabled = onTap != nil
        press.isAccessibilityElement = true
        press.accessibilityTraits = onTap != nil ? .button : .staticText
        addSubview(press)
        press.pin(to: self)
        press.addSubview(column)
        column.pin(to: press, insets: UIEdgeInsets(top: 13, left: 0, bottom: 13, right: 0))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override var accessibilityLabel: String? {
        get { [title.text, value.text].compactMap { $0 }.joined(separator: ", ") }
        set {}
    }
}

/// The second Home page (3.5: rebuilt as the owner's «вариант A» — the speed
/// large at the top over its graph, then lists with small charts; it was a grid
/// of cards).
final class MinimalAnalyticsViewController: UIViewController {
    private let scroll = HandoffScrollView()
    private let downSpeed = UILabel(font: UIFont.monospacedDigitSystemFont(ofSize: 40, weight: .semibold))
    private let downUnit = UILabel(font: Theme.font(17, .medium), color: .secondaryLabel)
    private let upSpeed = UILabel(font: UIFont.monospacedDigitSystemFont(ofSize: 40, weight: .semibold))
    private let upUnit = UILabel(font: Theme.font(17, .medium), color: .secondaryLabel)
    private let graph = SpeedGraphView()
    private let graphHint = UILabel(L("Данные появятся после подключения"), font: Theme.font(.caption1), color: .secondaryLabel)
    private let sessionRow = AnalyticsRow(L("Сеанс"))
    // 3.5: each measure drawn its own way — a ring, a gauge, a line, columns.
    private let trafficRing = RingChart()
    private let trafficTotal = UILabel(font: UIFont.monospacedDigitSystemFont(ofSize: Theme.font(.subheadline).pointSize, weight: .semibold))
    private let downTotal = UILabel(font: UIFont.monospacedDigitSystemFont(ofSize: Theme.font(.body).pointSize, weight: .semibold))
    private let upTotal = UILabel(font: UIFont.monospacedDigitSystemFont(ofSize: Theme.font(.body).pointSize, weight: .semibold))
    private let delayGauge = GaugeView()
    private let delayValue = UILabel(font: UIFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold))
    private let delayCaption = UILabel(font: Theme.font(.footnote), color: .secondaryLabel, lines: 2)
    private let memoryLine = SparklineView()
    private let memoryValue = UILabel(font: UIFont.monospacedDigitSystemFont(ofSize: Theme.font(.body).pointSize, weight: .regular), color: .secondaryLabel)
    private let columns = ColumnsView()
    private var tcpRow: AnalyticsRow!
    private var udpRow: AnalyticsRow!
    private let routesMeter = MeterBar()
    private let routes = AnalyticsGroup()
    private let routesEmpty = UILabel(L("Данные соединений пока недоступны"), font: Theme.font(.subheadline), color: .secondaryLabel, lines: 0)
    private var timer: Timer?
    private var visible = false

    static let tcpColor = UIColor.systemIndigo
    static let udpColor = UIColor.systemOrange
    static let routeColors: [UIColor] = [SpeedGraphView.downColor, UIColor(red: 0.37, green: 0.33, blue: 0.91, alpha: 1), .systemGreen, .systemOrange, .systemPink]
    /// The extension's limit, about 50 MiB: the memory meter fills against it.
    private static let memoryLimit: Double = 50 * 1024 * 1024

    /// 3.5: a change of style while the page shows: its clock stops with it.
    deinit { timer?.invalidate() }

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
        // 3.5: over Home's wallpaper when the owner chose one.
        view.backgroundColor = Wallpaper.active ? .clear : Theme.background
        Prefs.appearanceChanged.observe(self) { [weak self] in self?.view.backgroundColor = Wallpaper.active ? .clear : Theme.background }
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

        // The speed now, large, over the last two minutes.
        func speed(_ number: UILabel, _ unit: UILabel, _ symbol: String, _ caption: String, _ color: UIColor) -> UIView {
            number.adjustsFontSizeToFitWidth = true
            number.minimumScaleFactor = 0.6
            let figure = UIStackView(.horizontal, spacing: 6, alignment: .firstBaseline, [number, unit])
            let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: Theme.font(.subheadline, .semibold))))
            icon.tintColor = color
            let label = UIStackView(.horizontal, spacing: 4, alignment: .center, [icon, UILabel(caption, font: Theme.font(.subheadline, .medium), color: color)])
            return UIStackView(.vertical, spacing: 2, alignment: .leading, [figure, label])
        }
        let now = UILabel(L("СЕЙЧАС"), font: Theme.font(.caption1, .semibold), color: .secondaryLabel)
        let speeds = UIStackView(.horizontal, spacing: 32, alignment: .top, [
            speed(downSpeed, downUnit, "arrow.down", L("Загрузка"), SpeedGraphView.downColor),
            speed(upSpeed, upUnit, "arrow.up", L("Отдача"), SpeedGraphView.upColor), UIView(),
        ])
        // The graph runs from edge to edge of the screen, without a card.
        let graphHolder = UIView()
        graph.translatesAutoresizingMaskIntoConstraints = false
        graphHolder.addSubview(graph)
        NSLayoutConstraint.activate([
            graphHolder.heightAnchor.constraint(equalToConstant: 150),
            graph.topAnchor.constraint(equalTo: graphHolder.topAnchor), graph.bottomAnchor.constraint(equalTo: graphHolder.bottomAnchor),
            graph.leadingAnchor.constraint(equalTo: graphHolder.leadingAnchor, constant: -20),
            graph.trailingAnchor.constraint(equalTo: graphHolder.trailingAnchor, constant: 20),
        ])
        graph.showsGrid = false
        graphHint.textAlignment = .center
        graphHint.numberOfLines = 0
        graphHolder.addSubview(graphHint)
        graphHint.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            graphHint.centerYAnchor.constraint(equalTo: graphHolder.centerYAnchor), graphHint.leadingAnchor.constraint(equalTo: graphHolder.leadingAnchor),
            graphHint.trailingAnchor.constraint(equalTo: graphHolder.trailingAnchor),
        ])
        let axis = UIStackView(.horizontal, spacing: 0, alignment: .center, [
            UILabel(L("2 мин назад"), font: Theme.font(.caption2), color: .secondaryLabel), UIView(),
            UILabel(L("сейчас"), font: Theme.font(.caption2), color: .secondaryLabel),
        ])
        let hero = UIStackView(.vertical, spacing: 8, alignment: .fill, [Classic.padded(now, UIEdgeInsets(top: 0, left: 2, bottom: 0, right: 0)), speeds, graphHolder, axis])
        hero.setCustomSpacing(18, after: speeds)
        hero.setCustomSpacing(6, after: graphHolder)

        func block(_ views: [UIView], spacing: CGFloat = 10) -> UIView {
            Classic.padded(UIStackView(.vertical, spacing: spacing, alignment: .fill, views), UIEdgeInsets(top: 14, left: 0, bottom: 14, right: 0))
        }
        func small(_ text: String) -> UILabel { UILabel(text, font: Theme.font(.subheadline, .medium), color: .secondaryLabel) }
        func legend(_ symbol: String, _ caption: String, _ color: UIColor, _ amount: UILabel) -> UIView {
            let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: Theme.font(.footnote, .bold))))
            icon.tintColor = color
            let top = UIStackView(.horizontal, spacing: 4, alignment: .center, [icon, UILabel(caption, font: Theme.font(.footnote), color: .secondaryLabel)])
            return UIStackView(.vertical, spacing: 2, alignment: .leading, [top, amount])
        }

        // The session's traffic: a ring, the total inside.
        trafficRing.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([trafficRing.widthAnchor.constraint(equalToConstant: 92), trafficRing.heightAnchor.constraint(equalToConstant: 92)])
        trafficTotal.textAlignment = .center
        trafficTotal.adjustsFontSizeToFitWidth = true
        trafficTotal.minimumScaleFactor = 0.6
        trafficRing.addSubview(trafficTotal)
        trafficTotal.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            trafficTotal.centerXAnchor.constraint(equalTo: trafficRing.centerXAnchor), trafficTotal.centerYAnchor.constraint(equalTo: trafficRing.centerYAnchor),
            trafficTotal.widthAnchor.constraint(equalToConstant: 64),
        ])
        let trafficLegend = UIStackView(.vertical, spacing: 12, alignment: .leading, [
            legend("arrow.down", L("Загрузка"), SpeedGraphView.downColor, downTotal), legend("arrow.up", L("Отдача"), SpeedGraphView.upColor, upTotal),
        ])
        let traffic = block([small(L("Трафик за сеанс")), UIStackView(.horizontal, spacing: 22, alignment: .center, [trafficRing, trafficLegend, UIView()])])

        // The delay: a half-circle gauge.
        delayGauge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([delayGauge.widthAnchor.constraint(equalToConstant: 132), delayGauge.heightAnchor.constraint(equalToConstant: 70)])
        delayValue.adjustsFontSizeToFitWidth = true
        delayValue.minimumScaleFactor = 0.6
        let delayText = UIStackView(.vertical, spacing: 2, alignment: .leading, [delayValue, delayCaption])
        let delay = block([small(L("Задержка")), UIStackView(.horizontal, spacing: 16, alignment: .center, [delayText, UIView(), delayGauge])])

        let session = AnalyticsGroup()
        session.add([sessionRow, traffic, delay])

        // The core's memory: its line over two minutes.
        memoryLine.color = .systemPurple
        memoryLine.ceiling = Self.memoryLimit
        memoryLine.heightAnchor.constraint(equalToConstant: 64).isActive = true
        memoryValue.textAlignment = .right
        let core = AnalyticsGroup()
        core.add([block([UIStackView(.horizontal, spacing: 8, alignment: .center, [small(L("Память ядра")), UIView(), memoryValue]), memoryLine,
                         UILabel(L("За 2 минуты. Предел расширения — около 50 МБ."), font: Theme.font(.caption2), color: .secondaryLabel, lines: 0)])])

        // Connections: columns over the last minute, TCP under UDP.
        columns.lowerColor = Self.tcpColor
        columns.upperColor = Self.udpColor
        columns.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let connections = AnalyticsGroup()
        tcpRow = AnalyticsRow("TCP", dot: Self.tcpColor) { [weak self] in self?.present(ConnectionsViewController.wrapped(udp: false), animated: true) }
        udpRow = AnalyticsRow("UDP", dot: Self.udpColor) { [weak self] in self?.present(ConnectionsViewController.wrapped(udp: true), animated: true) }
        connections.add([block([columns, UILabel(L("Открытые соединения за минуту"), font: Theme.font(.caption2), color: .secondaryLabel)], spacing: 8), tcpRow, udpRow])

        routes.add([Classic.padded(routesMeter, UIEdgeInsets(top: 14, left: 0, bottom: 4, right: 0)), Classic.padded(routesEmpty, UIEdgeInsets(top: 10, left: 0, bottom: 12, right: 0))])
        if routes.stack.arrangedSubviews.count > 1 { routes.stack.arrangedSubviews[1].isHidden = true }
        let routesNote = Classic.padded(UILabel(L("Показаны только соединения, полученные от ядра во время наблюдения; это не весь трафик сеанса."), font: Theme.font(.caption2), color: .secondaryLabel, lines: 0),
                                        UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6))

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

        let content = UIStackView(.vertical, spacing: 8, alignment: .fill, [
            header, hero,
            AnalyticsGroup.caption(L("Сеанс")), session,
            AnalyticsGroup.caption(L("Ядро")), core,
            AnalyticsGroup.caption(L("Соединения")), connections,
            AnalyticsGroup.caption(L("Маршруты")), routes, routesNote,
            links,
        ])
        content.setCustomSpacing(10, after: header)
        for view in [hero, session, core, connections, routesNote] { content.setCustomSpacing(26, after: view) }
        scroll.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])

        let client = App.shared.core
        client.status.observe(self) { [weak self] in self?.show($0) }
        client.history.observe(self) { [weak self] history in
            guard let self, self.visible else { return }
            self.graph.history = history
        }
        client.samples.observe(self) { [weak self] samples in
            guard let self, self.visible else { return }
            self.show(samples)
        }
        client.connections.observe(self) { [weak self] connections in
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

    /// Only the visible page keeps its timer and redraws the graph and the lists.
    func setVisible(_ value: Bool) {
        visible = value
        // 3.5: the connections are streamed for the whole Home (MinimalHome), not
        // from the moment this page shows: the first visit after a launch showed an
        // empty page for a second while the stream started again.
        timer?.invalidate()
        timer = nil
        if value {
            // The first redraw in two steps: the graph and the session now, the
            // lists (views built) on the next turn of the run loop.
            graph.history = App.shared.core.history.value
            show(App.shared.core.samples.value)
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
        let text = Format.duration(since.map { Int(Date().timeIntervalSince($0)) } ?? 0)
        if sessionRow.value.text != text { sessionRow.value.text = text }
    }

    /// «130 KB/с» → «130», «KB/с».
    private static func split(_ text: String) -> (String, String) {
        guard let space = text.firstIndex(of: " ") else { return (text, "") }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }

    private func show(_ status: CoreStatus?) {
        let down = Self.split(Format.speed(max(1, status?.downlink ?? 0)))
        let up = Self.split(Format.speed(max(1, status?.uplink ?? 0)))
        downSpeed.text = status == nil ? "—" : ((status?.downlink ?? 0) > 0 ? down.0 : "0")
        downUnit.text = down.1
        upSpeed.text = status == nil ? "—" : ((status?.uplink ?? 0) > 0 ? up.0 : "0")
        upUnit.text = up.1
        let down = status?.downlinkTotal ?? 0, up = status?.uplinkTotal ?? 0
        downTotal.text = status == nil ? "—" : Format.bytes(down)
        upTotal.text = status == nil ? "—" : Format.bytes(up)
        trafficTotal.text = status == nil ? "—" : Format.bytes(down + up)
        trafficRing.parts = [(Double(down), SpeedGraphView.downColor), (Double(up), SpeedGraphView.upColor)]
        memoryValue.text = status.map { Format.bytes($0.memory) + " · \($0.goroutines) goroutines" } ?? L("Ядро не запущено")
        graphHint.isHidden = status != nil
    }

    /// Names of the route rows, in order; the rows are rebuilt only when they change.
    private var routeNames: [String] = []
    private var routeRows: [AnalyticsRow] = []
    private static let routeRowsShown = 5

    private func show(_ connections: CoreConnections) {
        let tcpText = "\(connections.tcp)", udpText = "\(connections.udp)"
        if tcpRow.value.text != tcpText { tcpRow.value.text = tcpText }
        if udpRow.value.text != udpText { udpRow.value.text = udpText }
        let top = Array(connections.routes.sorted { $0.value > $1.value }.prefix(Self.routeRowsShown))
        routesMeter.parts = top.enumerated().map { (Double($1.value), Self.routeColors[$0 % Self.routeColors.count]) }
        let names = top.map(\.key)
        if names == routeNames, !routeRows.isEmpty || names.isEmpty {
            for (row, route) in zip(routeRows, top) {
                let text = Format.bytes(route.value)
                if row.value.text != text { row.value.text = text }
            }
            routesEmpty.superview?.isHidden = !names.isEmpty
            return
        }
        routeNames = names
        // Rows after the meter and the «no data» line go; the new ones come in order.
        let keep = Array(routes.stack.arrangedSubviews.prefix(3))
        for view in routes.stack.arrangedSubviews where !keep.contains(view) { view.removeFromSuperview() }
        routeRows = top.enumerated().map { index, route in
            let row = AnalyticsRow(route.key, dot: Self.routeColors[index % Self.routeColors.count])
            row.value.text = Format.bytes(route.value)
            return row
        }
        routes.add(routeRows)
        // The first route row follows the meter without a line.
        if routes.stack.arrangedSubviews.count > 3 { routes.stack.arrangedSubviews[3].isHidden = true }
        routesEmpty.superview?.isHidden = !names.isEmpty
    }

    /// The memory line and the connection columns (a column per two seconds).
    private func show(_ samples: CoreSamples) {
        memoryLine.values = samples.memory.map(Double.init)
        let count = samples.tcp.count
        let picked = stride(from: count % 2 == 0 ? 1 : 0, to: count, by: 2).map { $0 }.suffix(columns.columns)
        columns.lower = picked.map { samples.tcp[$0] }
        columns.upper = picked.map { samples.udp[$0] }
    }

    private func showDelay() {
        let library = App.shared.library
        let kind = Prefs.pingMode == "alternative" ? "HTTP" : "HTTPS"
        if let subscription = library.activeSubscription, let node = library.activeNode,
           let entry = App.shared.latency.entry(subscription.id, node.id)
        {
            let name = App.shared.store.label(of: node, in: subscription).text
            switch entry.result {
            case let .delay(value):
                delayValue.text = "\(value) ms"
                delayValue.textColor = delayGauge.color(for: Double(value))
                delayGauge.value = Double(value)
            case let .failed(reason):
                delayValue.text = reason.title
                delayValue.textColor = .systemRed
                delayGauge.value = nil
            }
            delayCaption.text = Lf("%@ до «%@»", kind, name)
        } else {
            delayValue.text = "—"
            delayValue.textColor = .label
            delayGauge.value = nil
            delayCaption.text = kind
        }
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
