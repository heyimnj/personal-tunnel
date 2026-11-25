import TunnelCore
import UIKit

/// A rounded card of the analytics page.
final class AnalyticsCard: UIView {
    let stack = UIStackView(.vertical, spacing: 10, alignment: .leading, [])

    init(insets: UIEdgeInsets = UIEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)) {
        super.init(frame: .zero)
        backgroundColor = Theme.card
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous
        addSubview(stack)
        stack.pin(to: self, insets: insets)
        Prefs.appearanceChanged.observe(self) { [weak self] in self?.backgroundColor = Theme.card }
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
///
/// 3.5 (the owner: the graph kept the old look while everything round it
/// changed): drawn as the core's memory line is — smooth lines over soft washes
/// of their own colour, no grid, a dot where each line ends now. It runs from
/// edge to edge of its card, under the figures.
final class SpeedGraphView: UIView {
    private let down = CAShapeLayer()
    private let up = CAShapeLayer()
    private let downWash = CAGradientLayer()
    private let downWashShape = CAShapeLayer()
    private let upWash = CAGradientLayer()
    private let upWashShape = CAShapeLayer()
    private let downDot = CAShapeLayer()
    private let upDot = CAShapeLayer()
    static let downColor = UIColor(red: 0.33, green: 0.75, blue: 0.91, alpha: 1)
    static let upColor = UIColor(red: 0.93, green: 0.26, blue: 0.36, alpha: 1)
    /// 3.5.28 (the owner): the line «сейчас» under the session's columns is neutral —
    /// the download in the text's colour, the upload grey and dashed — so the
    /// columns above keep the blue and red to themselves.
    static let liveDownColor = UIColor.label
    static let liveUpColor = UIColor.secondaryLabel
    var history = TrafficHistory() { didSet { drawnSize = nil; setNeedsLayout() } }
    /// 3.5.10: the size the lines were last built for; a layout pass that changes
    /// nothing (the page moving, its insets settling) builds nothing.
    private var drawnSize: CGSize?
    /// The highest speed shown, bytes per second (for the caption).
    private(set) var peak: Int64 = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        for (wash, shape) in [(downWash, downWashShape), (upWash, upWashShape)] {
            wash.mask = shape
            layer.addSublayer(wash)
        }
        for line in [down, up] {
            line.fillColor = nil
            line.lineWidth = 1.8
            line.lineJoin = .round
            line.lineCap = .round
            layer.addSublayer(line)
        }
        up.lineDashPattern = [4, 3]
        for dot in [downDot, upDot] {
            dot.lineWidth = 1.5
            layer.addSublayer(dot)
        }
        paint()
        // Nothing is drawn outside the graph's own box.
        layer.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    /// The neutral colours follow the theme (layers keep a resolved colour).
    private func paint() {
        let downColor = Self.liveDownColor.resolvedColor(with: traitCollection)
        let upColor = Self.liveUpColor.resolvedColor(with: traitCollection)
        downWash.colors = [downColor.withAlphaComponent(0.12).cgColor, downColor.withAlphaComponent(0).cgColor]
        upWash.colors = [upColor.withAlphaComponent(0).cgColor, upColor.withAlphaComponent(0).cgColor]
        down.strokeColor = downColor.cgColor
        up.strokeColor = upColor.cgColor
        downDot.fillColor = downColor.cgColor
        upDot.fillColor = upColor.cgColor
        let ring = (traitCollection.userInterfaceStyle == .dark ? UIColor.black : UIColor.white).withAlphaComponent(0.9)
        downDot.strokeColor = ring.cgColor
        upDot.strokeColor = ring.cgColor
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previous) { paint() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard drawnSize != bounds.size else { return }
        drawnSize = bounds.size
        peak = max(0, (history.down + history.up).max() ?? 0)
        let scale = max(1, peak)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let series: [([Int64], CAShapeLayer, CAGradientLayer, CAShapeLayer, CAShapeLayer)] = [
            (history.down, down, downWash, downWashShape, downDot), (history.up, up, upWash, upWashShape, upDot),
        ]
        for (samples, line, wash, shape, dot) in series {
            let points = self.points(samples, peak: scale)
            let path = Self.smooth(points)
            line.path = path
            wash.frame = bounds
            let area = UIBezierPath(cgPath: path)
            area.addLine(to: CGPoint(x: bounds.width, y: bounds.height))
            area.addLine(to: CGPoint(x: points.first?.x ?? 0, y: bounds.height))
            area.close()
            shape.path = area.cgPath
            if let last = points.last, samples.count > 1 {
                let x = min(last.x, bounds.width - 5)
                dot.path = UIBezierPath(ovalIn: CGRect(x: x - 3.5, y: last.y - 3.5, width: 7, height: 7)).cgPath
            } else {
                dot.path = nil
            }
        }
        CATransaction.commit()
    }

    private func points(_ samples: [Int64], peak: Int64) -> [CGPoint] {
        let count = TrafficHistory.capacity
        let step = bounds.width / CGFloat(max(1, count - 1))
        // Room for the end dots at the top and the bottom.
        let base = bounds.height - 4
        let room = max(1, bounds.height - 9)
        let offset = count - samples.count
        var points: [CGPoint] = []
        if offset > 0 { points.append(CGPoint(x: 0, y: base)) }
        for (index, sample) in samples.enumerated() {
            let share = min(1, max(0, CGFloat(sample) / CGFloat(peak)))
            points.append(CGPoint(x: CGFloat(offset + index) * step, y: base - share * room))
        }
        return points
    }

    /// Through the midpoints, each point a control: the curve never leaves the
    /// range of its points (no dip under the floor, no peak over the top).
    static func smooth(_ points: [CGPoint]) -> CGPath {
        let path = UIBezierPath()
        guard let first = points.first else { return path.cgPath }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path.cgPath
        }
        for index in 1 ..< points.count - 1 {
            let point = points[index], next = points[index + 1]
            path.addQuadCurve(to: CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2), controlPoint: point)
        }
        path.addLine(to: points[points.count - 1])
        return path.cgPath
    }
}

/// A ring split between parts (3.5): the session's traffic, download against
/// upload, with the total in the middle.
final class RingChart: UIView {
    /// 3.5.10: redrawn only when a value changed (it was redrawn every second).
    var parts: [(value: Double, color: UIColor)] = [] {
        didSet {
            guard parts.map(\.value) != oldValue.map(\.value) || parts.map(\.color) != oldValue.map(\.color) else { return }
            setNeedsDisplay()
        }
    }
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
        // 3.5.11 (the owner: the gaps between download and upload looked like
        // something missing): the parts meet edge to edge, square where they join.
        context.setLineCap(.butt)
        var angle = -CGFloat.pi / 2
        for part in shown {
            let sweep = CGFloat(part.value / total) * .pi * 2
            context.setStrokeColor(part.color.cgColor)
            context.addArc(center: center, radius: radius, startAngle: angle, endAngle: angle + sweep, clockwise: false)
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
    var value: Double? { didSet { if value != oldValue { setNeedsDisplay() } } }
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
            // 3.5.28 (the owner): the three zones are seen on the track (0.16 was lost).
            context.setStrokeColor(zone.color.withAlphaComponent(0.38).cgColor)
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
    var values: [Double] = [] { didSet { if values != oldValue { setNeedsDisplay() } } }
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

/// 3.5.23: the session's traffic over time, a column per span: download below,
/// upload on it, one shape with one rounding (the owner: the two parts must meet,
/// not stand apart), a thin line of the card's tone between them.
final class TimelineBarsView: UIView {
    var buckets: [TrafficTimeline.Bucket] = [] { didSet { if buckets != oldValue { setNeedsDisplay() } } }
    /// 3.5.25: columns the card has room for — the session fills them from the left
    /// (one column at the start of a session no longer took the whole card).
    var slots = 30 { didSet { if slots != oldValue { setNeedsDisplay() } } }
    /// 3.5.25: the height a full column stands for, at least: a few kilobytes no
    /// longer fill the card to the top.
    var minimumPeak: Int64 = 1 { didSet { if minimumPeak != oldValue { setNeedsDisplay() } } }
    var separator: UIColor = .secondarySystemBackground

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func draw(_: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), bounds.width > 4, bounds.height > 4 else { return }
        let height = bounds.height - 1
        // 3.5.26 (the owner): no guide lines — as clean as the live graph.
        guard !buckets.isEmpty else { return }
        let peak = max(minimumPeak, buckets.map(\.total).max() ?? 1)
        let count = CGFloat(max(slots, buckets.count))
        let gap: CGFloat = count > 40 ? 2 : 4
        let width = max(1.5, (bounds.width - gap * (count - 1)) / count)
        // 3.6 (the owner: the red top looked blurred over the blue, the ring's join is
        // sharp): every edge on the screen's pixel grid, and the two colours meet
        // directly, as in the ring — no blended separator line between them.
        let scale = max(1, window?.screen.scale ?? traitCollection.displayScale)
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        for (index, bucket) in buckets.enumerated() {
            let left = snap(CGFloat(index) * (width + gap))
            let right = snap(CGFloat(index) * (width + gap) + width)
            let barWidth = max(1 / scale, right - left)
            let raw = max(bucket.total > 0 ? 2 : 1.5, height * CGFloat(bucket.total) / CGFloat(peak))
            let top = snap(height - raw)
            let total = height - top
            let shape = CGRect(x: left, y: top, width: barWidth, height: total)
            let radius = min(barWidth / 2, 4)
            context.saveGState()
            UIBezierPath(roundedRect: shape, cornerRadius: radius).addClip()
            // The upload is at least as tall as the corner (a thinner sliver was cut into
            // a crescent), and a column too low for two parts is one colour.
            let low = total < radius * 2 + 4
            let upShare = bucket.total > 0 ? CGFloat(bucket.up) / CGFloat(bucket.total) : 0
            let base: UIColor = bucket.total == 0 ? UIColor.label.withAlphaComponent(0.1)
                : (low && upShare > 0.5 ? SpeedGraphView.upColor : SpeedGraphView.downColor)
            context.setFillColor(base.cgColor)
            context.fill(shape)
            if bucket.up > 0, !low {
                let up = upShare >= 1 ? total : snap(min(total - radius - 2, max(radius + 1, total * upShare)))
                context.setFillColor(SpeedGraphView.upColor.cgColor)
                context.fill(CGRect(x: left, y: top, width: barWidth, height: up))
            }
            context.restoreGState()
        }
    }
}

/// Routes as rings, one inside the other (3.5): each route its own track, its
/// arc as long as its share of the traffic seen; the largest outside.
final class RouteRingsView: UIView {
    var parts: [(value: Double, color: UIColor)] = [] {
        didSet {
            guard parts.map(\.value) != oldValue.map(\.value) || parts.map(\.color) != oldValue.map(\.color) else { return }
            setNeedsDisplay()
        }
    }

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
        let side = min(bounds.width, bounds.height)
        guard side > 8 else { return }
        // 3.5.3: as many rings as routes (empty tracks inside looked unfinished).
        let rings = max(1, parts.count)
        let line = max(4, min(10, side / CGFloat(max(3, rings) * 2 + 3)))
        let gap = line * 0.45
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let total = parts.reduce(0) { $0 + max(0, $1.value) }
        context.setLineWidth(line)
        context.setLineCap(.round)
        for ring in 0 ..< rings {
            let radius = side / 2 - line / 2 - CGFloat(ring) * (line + gap)
            guard radius > line / 2 else { break }
            context.setStrokeColor(UIColor.label.withAlphaComponent(0.07).cgColor)
            context.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            context.strokePath()
            guard ring < parts.count, total > 0, parts[ring].value > 0 else { continue }
            let share = CGFloat(parts[ring].value / total)
            let start = -CGFloat.pi / 2
            context.setStrokeColor(parts[ring].color.cgColor)
            context.addArc(center: center, radius: radius, startAngle: start, endAngle: start + max(0.02, share * .pi * 2 - 0.001), clockwise: false)
            context.strokePath()
        }
    }
}

/// Columns over time, two series stacked (3.5): the open TCP and UDP
/// connections in the last minute, a column every two seconds.
final class ColumnsView: UIView {
    var lower: [Int] = [] { didSet { if lower != oldValue { setNeedsDisplay() } } }
    var upper: [Int] = [] { didSet { if upper != oldValue { setNeedsDisplay() } } }
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
        var highest = 4
        for (a, b) in zip(lower, upper) { highest = max(highest, a + b) }
        let peak = CGFloat(highest)
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
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous
        addSubview(stack)
        stack.pin(to: self, insets: UIEdgeInsets(top: 2, left: 14, bottom: 2, right: 14))
        Prefs.appearanceChanged.observe(self) { [weak self] in self?.backgroundColor = Theme.card }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    /// 3.5 beta 4 (the owner): no lines between the parts.
    func add(_ views: [UIView]) {
        for view in views { stack.addArrangedSubview(view) }
    }

    /// The caption above a group: small capitals in the secondary colour.
    static func caption(_ text: String) -> UIView {
        let label = UILabel(text.uppercased(), font: Theme.font(.caption1), color: .secondaryLabel)
        return Classic.padded(label, UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6))
    }
}

/// One row: a title and its value, and a
/// chevron when it opens something.
final class AnalyticsRow: UIView {
    let title = UILabel(font: Theme.font(.subheadline))
    let value = UILabel(font: Theme.digits(Theme.font(.subheadline).pointSize, .regular), color: .secondaryLabel)
    private let press = TapControl()

    init(_ text: String, dot: UIColor? = nil, onTap: (() -> Void)? = nil) {
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
            mark.layer.cornerRadius = 4
            mark.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([mark.widthAnchor.constraint(equalToConstant: 8), mark.heightAnchor.constraint(equalToConstant: 8)])
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
        top.heightAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
        let column = UIStackView(.vertical, spacing: 8, alignment: .fill, [top])
        column.isUserInteractionEnabled = false
        press.pressScale = 1
        press.onTap = onTap
        press.isEnabled = onTap != nil
        press.isAccessibilityElement = true
        press.accessibilityTraits = onTap != nil ? .button : .staticText
        addSubview(press)
        press.pin(to: self)
        press.addSubview(column)
        column.pin(to: press, insets: UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override var accessibilityLabel: String? {
        get { [title.text, value.text].compactMap { $0 }.joined(separator: ", ") }
        set {}
    }
}

/// The second Home page (3.5: the owner's «вариант A» — the speed large at the
/// top over its graph, then tiles). 3.5 (release, the owner: the page was too
/// busy): the session's two square tiles; 3.5.2: routes (4:2), connections as in
/// beta 4 (columns and two rows), the core's memory (4:2).
final class MinimalAnalyticsViewController: UIViewController, UIGestureRecognizerDelegate {
    private let scroll = HandoffScrollView()
    // 3.5 beta 2 (the owner: the page was larger than the rest of the app): smaller
    // figures, charts and rows throughout.
    // 3.5.28 (the owner): the speed now is the small part under the session's
    // columns.
    private let downSpeed = UILabel(font: Theme.digits(20, .semibold), color: SpeedGraphView.liveDownColor)
    private let downUnit = UILabel(font: Theme.font(12, .medium), color: .secondaryLabel)
    private let upSpeed = UILabel(font: Theme.digits(20, .semibold), color: SpeedGraphView.liveUpColor)
    private let upUnit = UILabel(font: Theme.font(12, .medium), color: .secondaryLabel)
    private let graph = SpeedGraphView()
    private let graphPeak = UILabel(font: Theme.digits(Theme.font(.caption2).pointSize, .medium), color: .secondaryLabel)
    private let graphHint = UILabel(L("Данные появятся после подключения"), font: Theme.font(.caption1), color: .secondaryLabel)
    private let sessionRow = AnalyticsRow(L("Сеанс"))
    /// 3.5.26 (the owner): the session under the page's title, small: «● Сеанс 00:39:22».
    private let sessionLine = UILabel(font: Theme.digits(Theme.font(.footnote).pointSize, .regular), color: .secondaryLabel)
    private let sessionDot = UIView()
    /// 3.5.26: «● TCP 3   ● UDP 0» under the columns.
    private let tcpCount = UILabel(font: Theme.digits(Theme.font(.subheadline).pointSize, .regular))
    private let udpCount = UILabel(font: Theme.digits(Theme.font(.subheadline).pointSize, .regular))
    // 3.5: each measure drawn its own way — a ring, a gauge, rings, a line.
    private let trafficRing = RingChart()
    private let trafficTotal = UILabel(font: Theme.digits(Theme.font(.footnote).pointSize, .semibold))
    private let downTotal = UILabel(font: Theme.digits(Theme.font(.subheadline).pointSize, .semibold))
    private let upTotal = UILabel(font: Theme.digits(Theme.font(.subheadline).pointSize, .semibold))
    private let delayGauge = GaugeView()
    private let delayValue = UILabel(font: Theme.digits(22, .semibold))
    private let delayCaption = UILabel(font: Theme.font(.footnote), color: .secondaryLabel, lines: 2)
    private let memoryLine = SparklineView()
    private let memoryValue = UILabel(font: Theme.digits(20, .semibold))
    private let memoryDetail = UILabel(font: Theme.digits(Theme.font(.caption2).pointSize, .regular), color: .secondaryLabel)
    private let columns = ColumnsView()
    private let columnsPeak = UILabel(font: Theme.digits(Theme.font(.caption2).pointSize, .medium), color: .secondaryLabel)
    private var tcpRow: AnalyticsRow!
    private var udpRow: AnalyticsRow!
    private let routeRings = RouteRingsView()
    /// 3.5.23: «Трафик по времени».
    private let timelineBars = TimelineBarsView()
    /// 3.5.28 (the owner: the «Сейчас | Сеанс» switch did not fit): one card, the
    /// session's columns large above, the speed now small below — no switch.
    private let timelineBox = UIStackView(.vertical, spacing: 4, alignment: .fill, [])
    private let sessionPeak = UILabel(font: Theme.digits(Theme.font(.caption2).pointSize, .medium), color: .secondaryLabel)
    private let timelineAxis = [UILabel(font: Theme.digits(Theme.font(.caption2).pointSize, .regular), color: .secondaryLabel),
                                UILabel(font: Theme.digits(Theme.font(.caption2).pointSize, .regular), color: .secondaryLabel),
                                UILabel(font: Theme.digits(Theme.font(.caption2).pointSize, .regular), color: .secondaryLabel)]
    private var timelineShownAt: Date?
    private let routeLegend = UIStackView(.vertical, spacing: 3, alignment: .fill, [])
    private let routesEmpty = UILabel(L("Данные соединений пока недоступны"), font: Theme.font(.footnote), color: .secondaryLabel, lines: 0)
    private var timer: Timer?
    private var visible = false

    static let tcpColor = UIColor.systemIndigo
    static let udpColor = UIColor.systemOrange
    /// 3.5.28 (the owner: too much blue and red): the servers in turquoise and the
    /// colours after it; the rest by what they are.
    static let serverColors: [UIColor] = [UIColor(red: 0.25, green: 0.82, blue: 0.72, alpha: 1), .systemGreen, .systemYellow, .systemTeal]
    static let directColor = UIColor(red: 0.43, green: 0.39, blue: 0.94, alpha: 1)
    /// The extension's limit, about 50 MiB: the memory line shows it when near.
    private static let memoryLimit: Double = 50 * 1024 * 1024
    /// Routes in the card: a ring and a line of the legend each.
    private static let routesShown = 4

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

    /// Whether the list may take a drag now (Home: only while this page stands
    /// on screen; a swipe during the page's move is the pager's).
    var acceptsDrag: ((_ upward: Bool) -> Bool)? {
        get { scroll.acceptsDrag }
        set { scroll.acceptsDrag = newValue }
    }

    /// Stops a fling of the list where it is (the page is leaving).
    func stopScrolling() {
        guard scroll.isDecelerating || scroll.isDragging else { return }
        let top = -scroll.adjustedContentInset.top
        let bottom = max(top, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        scroll.setContentOffset(CGPoint(x: 0, y: min(max(top, scroll.contentOffset.y), bottom)), animated: false)
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
    /// 3.5.7: on a quick spring (see ScrollTopSpring).
    /// 3.5.13 (the owner: one stutter left, at the start of the way up from low
    /// down the page): a Core Animation spring, run by the render server — the
    /// tab bar's own work on the tap no longer costs its first frames (the
    /// per-frame spring ran on the main thread). As calm as 3.5.12. A finger on
    /// the list stops it where it shows.
    func scrollToTop() {
        stopScrollingToTop()
        let top = -scroll.adjustedContentInset.top
        // A fling still running ends here.
        scroll.setContentOffset(scroll.contentOffset, animated: false)
        guard abs(scroll.contentOffset.y - top) > 0.5 else { return }
        let timing = UISpringTimingParameters(dampingRatio: 1, initialVelocity: CGVector(dx: 0, dy: 0.4))
        let animator = UIViewPropertyAnimator(duration: 0.55, timingParameters: timing)
        animator.addAnimations { [weak self] in
            self?.scroll.contentOffset = CGPoint(x: 0, y: top)
        }
        animator.addCompletion { [weak self, weak animator] _ in
            guard let self, let animator, self.topAnimator === animator else { return }
            self.topAnimator = nil
        }
        topAnimator = animator
        animator.startAnimation()
    }

    private var topAnimator: UIViewPropertyAnimator?

    private func stopScrollingToTop() {
        guard let animator = topAnimator else { return }
        topAnimator = nil
        animator.stopAnimation(true)
    }

    @objc private func listTouched(_ press: UILongPressGestureRecognizer) {
        if press.state == .began { stopScrollingToTop() }
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool { true }

    /// The list is on its way to the top after a tap on the tab.
    var isScrollingToTop: Bool { topAnimator != nil }

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
        // 3.5.7 (the owner): no scroll bar — at the page change it jumped in length
        // as the list met its top and the page's insets settled.
        scroll.showsVerticalScrollIndicator = false
        let press = UILongPressGestureRecognizer(target: self, action: #selector(listTouched(_:)))
        press.minimumPressDuration = 0
        press.cancelsTouchesInView = false
        press.delaysTouchesBegan = false
        press.delaysTouchesEnded = false
        press.delegate = self
        scroll.addGestureRecognizer(press)
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
        sessionDot.layer.cornerRadius = 3.5
        sessionDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([sessionDot.widthAnchor.constraint(equalToConstant: 7), sessionDot.heightAnchor.constraint(equalToConstant: 7)])
        let sessionStack = UIStackView(.horizontal, spacing: 6, alignment: .center, [sessionDot, sessionLine])
        sessionStack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(sessionStack)
        NSLayoutConstraint.activate([
            // 3.5.26 (the owner): the session line right under the title, the cards right
            // under it — the header ends at the line.
            title.centerXAnchor.constraint(equalTo: header.centerXAnchor), title.centerYAnchor.constraint(equalTo: header.topAnchor, constant: 24),
            sessionStack.centerXAnchor.constraint(equalTo: header.centerXAnchor), sessionStack.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            sessionStack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            more.trailingAnchor.constraint(equalTo: header.trailingAnchor), more.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            more.widthAnchor.constraint(equalToConstant: 44), more.heightAnchor.constraint(equalToConstant: 44),
            moreGlass.centerXAnchor.constraint(equalTo: more.centerXAnchor), moreGlass.centerYAnchor.constraint(equalTo: more.centerYAnchor),
            moreGlass.widthAnchor.constraint(equalToConstant: 44), moreGlass.heightAnchor.constraint(equalToConstant: 44),
        ])

        let hero = makeHero()

        func small(_ text: String) -> UILabel { UILabel(text, font: Theme.font(.footnote, .medium), color: .secondaryLabel) }
        func tile() -> AnalyticsCard {
            let card = AnalyticsCard(insets: UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
            card.stack.alignment = .center
            card.stack.distribution = .equalSpacing
            return card
        }

        // The session's traffic: a ring, the total inside.
        trafficRing.translatesAutoresizingMaskIntoConstraints = false
        trafficRing.lineWidth = 9
        NSLayoutConstraint.activate([trafficRing.widthAnchor.constraint(equalToConstant: 76), trafficRing.heightAnchor.constraint(equalToConstant: 76)])
        trafficTotal.textAlignment = .center
        trafficTotal.adjustsFontSizeToFitWidth = true
        trafficTotal.minimumScaleFactor = 0.6
        trafficRing.addSubview(trafficTotal)
        trafficTotal.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            trafficTotal.centerXAnchor.constraint(equalTo: trafficRing.centerXAnchor), trafficTotal.centerYAnchor.constraint(equalTo: trafficRing.centerYAnchor),
            trafficTotal.widthAnchor.constraint(equalToConstant: 54),
        ])
        // In the tile: «↓ 1.6 MB   ↑ 988 KB» on one line under the ring.
        func amount(_ symbol: String, _ color: UIColor, _ label: UILabel) -> UIView {
            let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: Theme.font(.caption1, .bold))))
            icon.tintColor = color
            icon.setContentHuggingPriority(.required, for: .horizontal)
            label.font = Theme.digits(Theme.font(.footnote).pointSize, .semibold)
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.7
            return UIStackView(.horizontal, spacing: 3, alignment: .center, [icon, label])
        }
        let tileLegend = UIStackView(.horizontal, spacing: 10, alignment: .center, [
            amount("arrow.down", SpeedGraphView.downColor, downTotal), amount("arrow.up", SpeedGraphView.upColor, upTotal),
        ])
        let traffic = tile()
        let trafficTitle = small(L("Трафик за сеанс"))
        for item in [trafficTitle, trafficRing, tileLegend] as [UIView] { traffic.stack.addArrangedSubview(item) }
        trafficTitle.widthAnchor.constraint(equalTo: traffic.stack.widthAnchor).isActive = true

        // The delay: a half-circle gauge. 3.5: a tap tests the connected server again.
        delayGauge.translatesAutoresizingMaskIntoConstraints = false
        delayGauge.lineWidth = 8
        NSLayoutConstraint.activate([delayGauge.widthAnchor.constraint(equalToConstant: 110), delayGauge.heightAnchor.constraint(equalToConstant: 58)])
        delayValue.adjustsFontSizeToFitWidth = true
        delayValue.minimumScaleFactor = 0.6
        delayValue.textAlignment = .center
        delayCaption.textAlignment = .center
        delayCaption.font = Theme.font(.caption1)
        let delay = tile()
        let delayTitle = small(L("Задержка"))
        let refresh = UIImageView(image: UIImage(systemName: "arrow.clockwise", withConfiguration: UIImage.SymbolConfiguration(font: Theme.font(.caption1, .semibold))))
        refresh.tintColor = .tertiaryLabel
        refresh.setContentHuggingPriority(.required, for: .horizontal)
        let delayHead = UIStackView(.horizontal, spacing: 6, alignment: .center, [delayTitle, UIView(), refresh])
        let reading = UIStackView(.vertical, spacing: 4, alignment: .center, [delayGauge, delayValue, delayCaption])
        for item in [delayHead, reading, UIView()] as [UIView] { delay.stack.addArrangedSubview(item) }
        for item in [delayHead, reading] { item.widthAnchor.constraint(equalTo: delay.stack.widthAnchor).isActive = true }
        delayCaption.widthAnchor.constraint(equalTo: reading.widthAnchor).isActive = true
        let delayButton = pressable(delay, label: L("Задержка")) { [weak self] in self?.testConnected() }
        delayButton.accessibilityHint = L("Проверить пинг")

        let tiles = UIStackView(.horizontal, spacing: 12, alignment: .fill, [traffic, delayButton])
        tiles.distribution = .fillEqually
        // Square: as tall as each tile is wide.
        traffic.heightAnchor.constraint(equalTo: traffic.widthAnchor).isActive = true

        let session = AnalyticsGroup()
        session.add([sessionRow])

        // Connections (3.5.2, the owner: back as in beta 4): columns of the open
        // TCP and UDP connections over the last minute, then a row for each that
        // opens its list. The highest column's count stands on the right.
        columns.lowerColor = Self.tcpColor
        columns.upperColor = Self.udpColor
        columns.heightAnchor.constraint(equalToConstant: 40).isActive = true
        columnsPeak.textAlignment = .right
        columnsPeak.setContentHuggingPriority(.required, for: .horizontal)
        // 3.5.26 (the owner): one compact card — the title, the columns, «● TCP 3  ● UDP 0 ›»;
        // a tap opens the open connections.
        func count(_ color: UIColor, _ label: UILabel) -> UIView {
            let dot = UIView()
            dot.backgroundColor = color
            dot.layer.cornerRadius = 4
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])
            return UIStackView(.horizontal, spacing: 7, alignment: .center, [dot, label])
        }
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(font: Theme.font(.footnote, .semibold))))
        chevron.tintColor = .tertiaryLabel
        let countsRow = UIStackView(.horizontal, spacing: 18, alignment: .center, [count(Self.tcpColor, tcpCount), count(Self.udpColor, udpCount), UIView(), chevron])
        let connectionsHead = UIStackView(.horizontal, spacing: 8, alignment: .center, [small(L("Соединения")), UIView(), columnsPeak])
        let connectionsCard = AnalyticsCard(insets: UIEdgeInsets(top: 14, left: 14, bottom: 12, right: 14))
        connectionsCard.stack.alignment = .fill
        connectionsCard.stack.spacing = 10
        for item in [connectionsHead, columns, countsRow] as [UIView] { connectionsCard.stack.addArrangedSubview(item) }
        let connections = pressable(connectionsCard, label: L("Открытые соединения")) { [weak self] in
            self?.present(ConnectionsViewController.wrapped(udp: nil), animated: true)
        }
        connections.pressScale = 0.98

        // Routes (4:2): the rings on the left, the largest routes beside them.
        let routes = AnalyticsCard(insets: UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
        routes.stack.alignment = .fill
        routes.stack.spacing = 10
        routeRings.setContentHuggingPriority(.defaultLow, for: .vertical)
        routeRings.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        routeRings.widthAnchor.constraint(equalTo: routeRings.heightAnchor).isActive = true
        routesEmpty.textAlignment = .left
        routeLegend.spacing = 6
        routeLegend.addArrangedSubview(routesEmpty)
        let above = UIView(), below = UIView()
        let legendColumn = UIStackView(.vertical, spacing: 0, alignment: .fill, [above, routeLegend, below])
        above.heightAnchor.constraint(equalTo: below.heightAnchor).isActive = true
        let routesBody = UIStackView(.horizontal, spacing: 16, alignment: .fill, [routeRings, legendColumn])
        // 3.5.26 (the owner): no note for the routes at all.
        for item in [small(L("Маршруты за сеанс")), routesBody] as [UIView] { routes.stack.addArrangedSubview(item) }

        // The core's memory (4:2): the figure, then its line over two minutes,
        // drawn to whatever room the card leaves (scaled inside its own box).
        memoryLine.color = .systemPurple
        memoryLine.ceiling = Self.memoryLimit
        memoryLine.clipsToBounds = true
        memoryLine.setContentHuggingPriority(.defaultLow, for: .vertical)
        memoryLine.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        memoryLine.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        memoryValue.adjustsFontSizeToFitWidth = true
        memoryValue.minimumScaleFactor = 0.6
        memoryDetail.textAlignment = .right
        memoryDetail.setContentHuggingPriority(.required, for: .horizontal)
        let memoryNote = UILabel(L("2 мин · предел ≈ 50 МБ"), font: Theme.font(.caption2), color: .secondaryLabel)
        let memory = AnalyticsCard(insets: UIEdgeInsets(top: 14, left: 14, bottom: 12, right: 14))
        memory.stack.alignment = .fill
        memory.stack.spacing = 4
        // 3.5.26 (the owner): one line — «Память ядра   31.0 MB · 49 goroutines».
        memoryValue.font = Theme.digits(Theme.font(.subheadline).pointSize, .regular)
        memoryValue.textColor = .secondaryLabel
        _ = memoryNote
        let memoryRow = UIStackView(.horizontal, spacing: 6, alignment: .firstBaseline, [UILabel(L("Память ядра"), font: Theme.font(.subheadline)), UIView(), memoryValue, memoryDetail])
        memory.stack.addArrangedSubview(memoryRow)

        let routesNote = Classic.padded(UILabel(L("Маршруты — куда ушёл трафик сеанса: через какой сервер или напрямую. «Без разбивки» — трафик, пока приложение было закрыто: ядро сохраняет только последние соединения."), font: Theme.font(.caption2), color: .secondaryLabel, lines: 0),
                                        UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6))

        let links = AnalyticsCard(insets: UIEdgeInsets(top: 0, left: 18, bottom: 0, right: 18))
        links.stack.alignment = .fill
        links.stack.spacing = 0
        // 3.5.24 (the owner): «Проверка соединения» moved to the log's tools.
        links.stack.addArrangedSubview(link("doc.text.magnifyingglass", L("Журнал службы")) { [weak self] in
            self?.navigationController?.pushViewController(ServiceLogViewController(), animated: true)
        })

        _ = session
        _ = routesNote
        let content = UIStackView(.vertical, spacing: 8, alignment: .fill, [
            header, hero, tiles,
            routes, connections, memory,
            links,
        ])
        // 4:2 — as tall as the square tiles. Only now: the views must already share
        // a parent (3.5 (271) tied two of them earlier and crashed at launch).
        routes.heightAnchor.constraint(equalTo: traffic.heightAnchor).isActive = true
        // 3.5.26 (the owner): the session line close to the cards; even gaps between them.
        content.setCustomSpacing(4, after: header)
        for view in [hero, tiles, routes, connections] { content.setCustomSpacing(12, after: view) }
        content.setCustomSpacing(12, after: memory)
        scroll.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
        ])

        let client = App.shared.core
        // 3.5.11 (the owner: since 3.5 the page changes and the way up stutter; 3.2.11
        // did not): what comes from the core only marks the page as behind; it is
        // drawn once a second, all at once, and never while anything moves (see
        // `flush`). 3.2.11 changed a few labels a second; 3.5 redraws charts and
        // lays out a much larger page, twice a second (the status and the
        // connections come apart) — at 120 Hz that cost a frame in any motion.
        client.status.observe(self, fireNow: false) { [weak self] value in
            if value == nil { self?.firstPending = true }
            self?.arrived()
        }
        client.history.observe(self, fireNow: false) { [weak self] _ in self?.behind = true }
        client.samples.observe(self, fireNow: false) { [weak self] _ in self?.behind = true }
        client.connections.observe(self, fireNow: false) { [weak self] _ in self?.behind = true }
        App.shared.latency.changed.observe(self) { [weak self] _ in self?.showDelay() }
        App.shared.tunnel.connectedSince.observe(self) { [weak self] _ in self?.arrived() }
        showDelay()
        show(client.status.value)
        // 3.5.12: kept ready off screen from the start (see `everySecond`), and drawn
        // once soon after the app comes back, when the core's data flows again.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.everySecond() }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.firstPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self?.flush() }
        }
    }

    /// 3.5.14 (the owner: up to 3.2.x analytics opened ready at once; now, right
    /// after a launch, it showed «—» for a second or two): the first data after a
    /// launch, a return to the app or a new session is drawn the moment it comes,
    /// not at the next off-screen turn (every two seconds) or when the page stops.
    private var firstPending = true

    private func arrived() {
        behind = true
        // On the next turn: the history and the samples come right after the status.
        if firstPending { DispatchQueue.main.async { [weak self] in self?.flush() } }
    }

    /// A finger came down on Home (3.5.14): what came since the last turn is drawn
    /// now, before the page starts to move, so it slides in with today's figures.
    func aboutToShow() {
        guard !visible else { return }
        flush()
    }

    /// Something came from the core since the page was last drawn.
    private var behind = true
    /// Home's page is moving (set by Home).
    var moving = false
    /// The list itself moves, or a finger is on it.
    private var listMoving: Bool { scroll.isTracking || scroll.isDragging || scroll.isDecelerating || topAnimator != nil }

    /// Draws what came, if the page is on screen and nothing moves; otherwise the
    /// next second's turn does. `force`: the session clock is due too.
    private func flush(force: Bool = false) {
        guard !moving, !listMoving, behind || force else { return }
        behind = false
        measured { refresh() }
        if App.shared.core.status.value != nil, App.shared.tunnel.connectedSince.value != nil { firstPending = false }
    }

    /// 3.5.12 (the owner: as before 3.5, the page must be ready before it is
    /// opened, with no loading seen): off screen, while Home stands still, the page
    /// is drawn every two seconds, so it shows fresh the moment it slides in.
    /// Not under another tab (Home is out of the window then) or in the background.
    private var offscreenTurn = false

    private func everySecond() {
        if visible {
            flush(force: true)
            return
        }
        offscreenTurn.toggle()
        guard offscreenTurn, viewIfLoaded?.window != nil, UIApplication.shared.applicationState == .active else { return }
        flush()
    }

    /// Everything as it is now, at once.
    private func refresh() {
        let client = App.shared.core
        show(client.status.value)
        showTimeline()
        showGraph(client.history.value)
        show(client.samples.value)
        show(client.connections.value)
        tick()
    }

    /// 3.5.10 diagnostics (read by Home after each page change): layout passes of
    /// this page and the time its updates took.
    private(set) var layoutPasses = 0
    private(set) var updates = 0
    private(set) var updateTime: CFTimeInterval = 0

    func resetCounters() {
        layoutPasses = 0
        updates = 0
        updateTime = 0
    }

    private func measured(_ work: () -> Void) {
        let start = CACurrentMediaTime()
        work()
        updates += 1
        updateTime += CACurrentMediaTime() - start
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPasses += 1
    }

    /// 3.5.28 (the owner): the session's columns large at the top; under a thin rule
    /// the speed now, small — figures and the last two minutes' line.
    private func makeHero() -> UIView {
        func speed(_ number: UILabel, _ unit: UILabel, _ symbol: String, _ color: UIColor) -> UIView {
            number.adjustsFontSizeToFitWidth = true
            number.minimumScaleFactor = 0.6
            let icon = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(font: Theme.font(.footnote, .semibold))))
            icon.tintColor = color
            let figure = UIStackView(.horizontal, spacing: 3, alignment: .firstBaseline, [number, unit])
            let row = UIStackView(.horizontal, spacing: 4, alignment: .center, [icon, figure])
            row.setContentHuggingPriority(.required, for: .horizontal)
            row.setContentCompressionResistancePriority(.required, for: .horizontal)
            return row
        }
        func caption(_ text: String) -> UILabel { UILabel(text, font: Theme.font(.caption1, .medium), color: .secondaryLabel) }
        func small(_ text: String) -> UILabel { UILabel(text, font: Theme.font(.footnote, .medium), color: .secondaryLabel) }
        for label in [sessionPeak, graphPeak] {
            label.textAlignment = .right
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.7
        }
        let top = UIStackView(.horizontal, spacing: 8, alignment: .center, [small(L("Трафик по времени")), UIView(), sessionPeak])
        // The session's columns with their time axis.
        timelineBars.separator = Theme.card
        timelineBars.heightAnchor.constraint(equalToConstant: 92).isActive = true
        timelineAxis[1].textAlignment = .center
        timelineAxis[2].textAlignment = .right
        let axis = UIStackView(.horizontal, spacing: 0, alignment: .fill, timelineAxis)
        axis.distribution = .fillEqually
        timelineBox.addArrangedSubview(timelineBars)
        timelineBox.addArrangedSubview(axis)
        let rule = UIView()
        rule.backgroundColor = UIColor.separator.withAlphaComponent(0.35)
        rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        let nowTop = UIStackView(.horizontal, spacing: 8, alignment: .center, [caption(L("сейчас")), UIView(), graphPeak])
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let now = UIStackView(.horizontal, spacing: 16, alignment: .bottom, [
            speed(downSpeed, downUnit, "arrow.down", SpeedGraphView.liveDownColor),
            speed(upSpeed, upUnit, "arrow.up", SpeedGraphView.liveUpColor), graph,
        ])
        let hero = AnalyticsCard(insets: UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
        hero.stack.alignment = .fill
        hero.stack.spacing = 10
        for item in [top, timelineBox, rule, nowTop, now] as [UIView] { hero.stack.addArrangedSubview(item) }
        hero.stack.setCustomSpacing(12, after: timelineBox)
        hero.stack.setCustomSpacing(12, after: rule)
        hero.stack.setCustomSpacing(6, after: nowTop)
        graph.widthAnchor.constraint(greaterThanOrEqualTo: now.widthAnchor, multiplier: 0.36).isActive = true
        graphHint.textAlignment = .center
        graphHint.numberOfLines = 0
        graphHint.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(graphHint)
        NSLayoutConstraint.activate([
            graphHint.centerYAnchor.constraint(equalTo: timelineBars.centerYAnchor),
            graphHint.leadingAnchor.constraint(equalTo: timelineBars.leadingAnchor), graphHint.trailingAnchor.constraint(equalTo: timelineBars.trailingAnchor),
        ])
        return hero
    }

    /// Wraps a tile so the whole of it is one button.
    private func pressable(_ content: UIView, label: String, action: @escaping () -> Void) -> TapControl {
        let control = TapControl()
        content.isUserInteractionEnabled = false
        control.addSubview(content)
        content.pin(to: control)
        control.onTap = action
        control.isAccessibilityElement = true
        control.accessibilityTraits = .button
        control.accessibilityLabel = label
        return control
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
        // Drawn now (Home calls this once the page stands still); the timer runs
        // all the time (see `everySecond`).
        if value { flush(force: true) }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.everySecond()
            }
        }
    }

    private func tick() {
        let since = App.shared.tunnel.connectedSince.value
        let text = Format.duration(since.map { Int(Date().timeIntervalSince($0)) } ?? 0)
        if sessionRow.value.text != text { sessionRow.value.text = text }
        sessionLine.showText(L("Сеанс") + " " + text)
        let on = since != nil
        let dotColor: UIColor = on ? .systemGreen : .tertiaryLabel
        if sessionDot.backgroundColor != dotColor { sessionDot.backgroundColor = dotColor }
    }

    /// «130 KB/с» → «130», «KB/с».
    private static func split(_ text: String) -> (String, String) {
        guard let space = text.firstIndex(of: " ") else { return (text, "") }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }

    private func showGraph(_ history: TrafficHistory) {
        graph.history = history
        let peak = max(0, (history.down + history.up).max() ?? 0)
        let text = peak > 0 ? Lf("пик %@", Format.speed(peak)) : ""  // the last two minutes, not the session
        if graphPeak.text != text { graphPeak.text = text }
    }

    /// «Трафик по времени»: the extension's points (stored with its memory sample,
    /// at most ten minutes old) and the app's own totals now. Drawn every ten
    /// seconds at most: it changes by the two minutes.
    private func showTimeline() {
        if let shown = timelineShownAt, Date().timeIntervalSince(shown) < 10 { return }
        timelineShownAt = Date()
        guard let since = App.shared.tunnel.connectedSince.value, App.shared.core.status.value != nil else {
            timelineBars.buckets = []
            for label in timelineAxis { label.showText("") }
            sessionPeak.showText("")
            return
        }
        let timeline = AppGroup.defaults.data(forKey: SharedKey.trafficTimeline).flatMap(TrafficTimeline.init(encoded:)) ?? TrafficTimeline()
        let totals = App.shared.core.coreTotals
        let now = Int64(Date().timeIntervalSince1970)
        let start = Int64(since.timeIntervalSince1970)
        let fine = timeline.buckets(from: start, width: 120, now: .init(time: now, up: totals.up, down: totals.down))
        let (buckets, width) = TrafficTimeline.coarsened(fine, width: 120, limit: 40)
        // 3.5.25: an hour of two-minute columns at least, filled from the left; a full
        // column is at least a megabyte a minute.
        let slots = max(30, buckets.count)
        timelineBars.slots = slots
        timelineBars.minimumPeak = width * 1_000_000 / 60
        timelineBars.buckets = buckets
        let minutes = Lf("%@ мин", "\(width / 60)")

        let clock = DateFormatter()
        clock.locale = Language.locale
        clock.dateFormat = "HH:mm"
        let end = start + Int64(slots) * width
        let times = [start, start + (end - start) / 2, end].map { clock.string(from: Date(timeIntervalSince1970: TimeInterval($0))) }
        timelineAxis[0].showText(times[0])
        timelineAxis[1].showText(Lf("столбик = %@", minutes))
        timelineAxis[2].showText(times[2])
        if let busiest = buckets.max(by: { $0.total < $1.total }), busiest.total > 0 {
            let at = clock.string(from: Date(timeIntervalSince1970: TimeInterval(busiest.start)))
            // 3.5.25: how much, not a speed rounded down to «≈0 KB/s».
            sessionPeak.showText(Lf("больше всего %@", at + " · " + Format.bytes(busiest.total)))
        } else {
            sessionPeak.showText(L("Трафика пока нет"))
        }
    }

    private func show(_ status: CoreStatus?) {
        let down = Self.split(Format.speed(max(1, status?.downlink ?? 0)))
        let up = Self.split(Format.speed(max(1, status?.uplink ?? 0)))
        // 3.5.11: a label is touched only when its text changes (each change lays
        // the page out again).
        downSpeed.showText(status == nil ? "—" : ((status?.downlink ?? 0) > 0 ? down.0 : "0"))
        downUnit.showText(down.1)
        upSpeed.showText(status == nil ? "—" : ((status?.uplink ?? 0) > 0 ? up.0 : "0"))
        upUnit.showText(up.1)
        let downBytes: Int64 = status?.downlinkTotal ?? 0
        let upBytes: Int64 = status?.uplinkTotal ?? 0
        downTotal.showText(status == nil ? "—" : Format.bytes(downBytes))
        upTotal.showText(status == nil ? "—" : Format.bytes(upBytes))
        trafficTotal.showText(status == nil ? "—" : Format.bytes(downBytes + upBytes))
        trafficRing.parts = [(value: Double(downBytes), color: SpeedGraphView.downColor), (value: Double(upBytes), color: SpeedGraphView.upColor)]
        memoryValue.showText(status.map { Format.bytes($0.memory) } ?? "—")
        memoryDetail.showText(status.map { "· \($0.goroutines) goroutines" } ?? "")
        if graphHint.isHidden != (status != nil) { graphHint.isHidden = status != nil }
    }

    /// Names in the routes legend, in order; its lines are rebuilt only when they change.
    private var routeNames: [String] = []
    private var routeValues: [UILabel] = []

    private func show(_ connections: CoreConnections) {
        let tcpText = "\(connections.tcp)", udpText = "\(connections.udp)"
        tcpCount.showText("TCP " + tcpText)
        udpCount.showText("UDP " + udpText)
        // 3.5.14: the session's routes, «direct» by name; what the app could not
        // attribute (connections it never saw) makes up the session's total.
        func title(_ key: String) -> String {
            switch key {
            case CoreConnections.direct: return L("Напрямую")
            case CoreConnections.probes: return L("Проверки серверов")
            case CoreConnections.dns: return "DNS"
            default: return key
            }
        }
        var routes = connections.routes.map { (key: title($0.key), value: $0.value) }
            .sorted { $0.value > $1.value }
        if routes.count > Self.routesShown {
            let rest = routes[(Self.routesShown - 1)...].reduce(0) { $0 + $1.value }
            routes = Array(routes.prefix(Self.routesShown - 1)) + [(key: L("Остальные"), value: rest)]
        }
        if let status = App.shared.core.status.value {
            let unseen = status.uplinkTotal + status.downlinkTotal - routes.reduce(0) { $0 + $1.value }
            // Only a share worth telling (2 %), not the bytes of a second's lag.
            if unseen > 0, unseen * 50 > status.uplinkTotal + status.downlinkTotal {
                if routes.count >= Self.routesShown {
                    let last = routes.removeLast()
                    routes.append((key: L("Остальные"), value: last.value + unseen))
                } else {
                    routes.append((key: L("Без разбивки"), value: unseen))
                }
            }
        }
        let top = routes
        var servers = 0
        let colors: [UIColor] = top.map { route in
            switch route.key {
            case L("Напрямую"): return Self.directColor
            case "DNS": return .systemPink
            case L("Проверки серверов"): return .systemOrange
            case L("Без разбивки"): return .systemGray
            case L("Остальные"): return .systemGray2
            default:
                defer { servers += 1 }
                return Self.serverColors[servers % Self.serverColors.count]
            }
        }
        routeRings.parts = zip(top, colors).map { route, color in (value: Double(route.value), color: color) }
        let names = top.map(\.key)
        if names == routeNames, !routeValues.isEmpty || names.isEmpty {
            for (label, route) in zip(routeValues, top) {
                let text = Format.bytes(route.value)
                if label.text != text { label.text = text }
            }
            routesEmpty.isHidden = !names.isEmpty
            return
        }
        routeNames = names
        for view in routeLegend.arrangedSubviews where view !== routesEmpty { view.removeFromSuperview() }
        routeValues = []
        for (index, route) in top.enumerated() {
            let dot = UIView()
            dot.backgroundColor = colors[index]
            dot.layer.cornerRadius = 4
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])
            let name = UILabel(route.key, font: Theme.font(.footnote))
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let value = UILabel(Format.bytes(route.value), font: Theme.digits(Theme.font(.footnote).pointSize, .regular), color: .secondaryLabel)
            value.setContentHuggingPriority(.required, for: .horizontal)
            value.setContentCompressionResistancePriority(.required, for: .horizontal)
            routeLegend.addArrangedSubview(UIStackView(.horizontal, spacing: 7, alignment: .center, [dot, name, UIView(), value]))
            routeValues.append(value)
        }
        routesEmpty.isHidden = !names.isEmpty
    }

    /// The memory line and the connection columns (a column per two seconds).
    private func show(_ samples: CoreSamples) {
        memoryLine.values = samples.memory.map { Double($0) }
        // A column per two seconds, the latest last.
        let count = min(samples.tcp.count, samples.udp.count)
        var indices: [Int] = []
        var index = count - 1
        while index >= 0, indices.count < columns.columns {
            indices.insert(index, at: 0)
            index -= 2
        }
        columns.lower = indices.map { samples.tcp[$0] }
        columns.upper = indices.map { samples.udp[$0] }
        let peak = zip(columns.lower, columns.upper).map { $0 + $1 }.max() ?? 0
        let text = peak > 0 ? Lf("пик %@", "\(peak)") : ""
        if columnsPeak.text != text { columnsPeak.text = text }
    }

    /// 3.5: the delay tile tests the connected server again.
    private func testConnected() {
        let library = App.shared.library
        guard let subscription = library.activeSubscription, let node = library.activeNode else { return }
        guard !App.shared.latency.isTesting(subscription.id, node.id) else { return }
        Haptics.tap()
        App.shared.ping(node: node, in: subscription)
        showDelay()
    }

    private var delayPulsing = false

    private func showDelay() {
        let library = App.shared.library
        let kind = Prefs.pingMode == "alternative" ? "HTTP" : "HTTPS"
        var testing = false
        if let subscription = library.activeSubscription, let node = library.activeNode {
            testing = App.shared.latency.isTesting(subscription.id, node.id)
            let name = App.shared.store.label(of: node, in: subscription).text
            if let entry = App.shared.latency.entry(subscription.id, node.id) {
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
            } else {
                delayValue.text = "—"
                delayValue.textColor = .label
                delayGauge.value = nil
            }
            delayCaption.text = testing ? L("Проверка") + "…" : Lf("%@ до «%@»", kind, name)
        } else {
            delayValue.text = "—"
            delayValue.textColor = .label
            delayGauge.value = nil
            delayCaption.text = kind
        }
        setDelayPulse(testing)
    }

    /// The gauge breathes while its server is being tested.
    private func setDelayPulse(_ on: Bool) {
        guard on != delayPulsing else { return }
        delayPulsing = on
        let layer = delayGauge.layer
        if on, !UIAccessibility.isReduceMotionEnabled {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: "testing")
        } else {
            layer.removeAnimation(forKey: "testing")
        }
    }
}

/// The TCP or UDP connections, as 1.5.0 showed them: a sheet with «Готово» and a
/// card per connection — a dot (green while open), where it goes, through which
/// server, and the bytes each way. Live: the core sends the list only while
/// this sheet is open (`CoreClient.listsConnections`).
final class ConnectionsViewController: UIViewController, UITableViewDataSource {
    /// nil: both kinds (3.5.2: the columns open the list with a switch on top).
    private var udp: Bool?
    private let switchable: Bool
    private weak var kinds: UISegmentedControl?

    /// A swipe left: the next of «Все», TCP, UDP; right: the one before.
    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        guard let kinds else { return }
        let step = gesture.direction == .left ? 1 : -1
        let next = kinds.selectedSegmentIndex + step
        guard next >= 0, next < kinds.numberOfSegments else { return }
        Haptics.selection()
        kinds.selectedSegmentIndex = next
        choose(next, from: gesture.direction)
    }

    /// Shows «Все», TCP or UDP; from a swipe, the list slides in from that side.
    private func choose(_ index: Int, from direction: UISwipeGestureRecognizer.Direction?) {
        let choices: [Bool?] = [nil, false, true]
        udp = choices[max(0, min(2, index))]
        items = []
        table.reloadData()
        show(App.shared.core.connections.value)
        guard let direction else { return }
        let transition = CATransition()
        transition.type = .push
        transition.subtype = direction == .left ? .fromRight : .fromLeft
        transition.duration = 0.25
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        table.layer.add(transition, forKey: "kind")
    }
    private let table = UITableView(frame: .zero, style: .plain)
    private let empty = UILabel(L("Данные соединений пока недоступны"), font: Theme.font(.body), color: .secondaryLabel, lines: 0)
    private var items: [CoreConnection] = []

    /// `udp` nil: every open connection, with «Все / TCP / UDP» to narrow it.
    static func wrapped(udp: Bool?) -> UIViewController {
        let navigation = UINavigationController(rootViewController: ConnectionsViewController(udp: udp))
        navigation.modalPresentationStyle = .pageSheet
        return navigation
    }

    init(udp: Bool?) {
        self.udp = udp
        switchable = udp == nil
        super.init(nibName: nil, bundle: nil)
        title = udp.map { $0 ? "UDP" : "TCP" } ?? L("Соединения")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("Готово"), primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        if switchable {
            let kinds = UISegmentedControl(items: [L("Все"), "TCP", "UDP"])
            kinds.selectedSegmentIndex = 0
            kinds.addAction(UIAction { [weak self, weak kinds] _ in
                guard let self, let kinds else { return }
                self.choose(kinds.selectedSegmentIndex, from: nil)
            }, for: .valueChanged)
            self.kinds = kinds
            // 3.6 (the owner): a swipe left or right moves between «Все», TCP and UDP.
            for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
                swipe.direction = direction
                view.addGestureRecognizer(swipe)
            }
            // 3.5.27 (the owner): three equal parts — «Все» was narrower than TCP and UDP.
            kinds.apportionsSegmentWidthsByContent = false
            for index in 0 ..< kinds.numberOfSegments { kinds.setWidth(72, forSegmentAt: index) }
            navigationItem.titleView = kinds
        }
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
        let next = connections.open.filter { udp == nil || $0.udp == udp }.sorted { $0.createdAt > $1.createdAt }
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
    private let traffic = UILabel(font: Theme.digits(Theme.font(.caption1).pointSize, .regular))

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

extension UILabel {
    /// 3.5.11: sets the text only when it differs (a new text lays the page out again).
    func showText(_ text: String?) {
        if self.text != text { self.text = text }
    }
}
