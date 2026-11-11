import TunnelCore
import UIKit

// The list of the «Серверы» panel, laid out by hand so that opening and closing a
// subscription is one motion computed every frame (1.5.0 did the same): a spring
// drives how much of the subscription is open, and from that single value follow
// the container's height, the subscriptions below it, the server cards it
// uncovers, the surface colour and the chevron. Server rows are reused and exist
// only for the visible part of the list.

// MARK: - Spring

/// A damped spring towards `target`, stepped by the display link.
struct DisclosureSpring {
    var value: CGFloat
    var velocity: CGFloat = 0
    var target: CGFloat

    init(_ value: CGFloat) {
        self.value = value
        target = value
    }

    var isSettled: Bool { abs(value - target) < 0.0005 && abs(velocity) < 0.002 }

    /// Opening is a touch quicker than closing; neither overshoots, so the container
    /// never shows an empty band below its last server.
    mutating func step(_ dt: CGFloat) {
        let opening = target > value
        let response: CGFloat = opening ? 0.46 : 0.56
        let stiffness = pow(2 * .pi / response, 2)
        let damping = 4 * .pi / response
        var left = min(dt, 1.0 / 30)
        while left > 0 {
            let h = min(left, 1.0 / 240)
            velocity += (stiffness * (target - value) - damping * velocity) * h
            value += velocity * h
            left -= h
        }
        if isSettled {
            value = target
            velocity = 0
        }
    }
}

// MARK: - Swipe

/// A round action behind a row.
struct SwipeAction {
    var symbol: String
    var color: UIColor
    var title: String
    var handler: () -> Void
}

/// A view whose `front` slides left to show round actions behind it. A full swipe
/// only opens the actions: nothing is ever deleted by a swipe alone.
class SwipeRow: UIView, UIGestureRecognizerDelegate {
    let front = UIView()
    /// Height of the content; the view itself may be shorter while it is uncovered.
    var contentHeight: CGFloat = 63
    var onOpen: ((SwipeRow) -> Void)?
    private let rail = UIView()
    private var buttons: [UIButton] = []
    private(set) var offset: CGFloat = 0
    private var panStart: CGFloat = 0
    private var animator: UIViewPropertyAnimator?

    var actions: [SwipeAction] = [] {
        didSet { rebuildRail() }
    }

    private var railWidth: CGFloat {
        actions.isEmpty ? 0 : CGFloat(actions.count) * 44 + CGFloat(actions.count - 1) * 10 + 16
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(rail)
        addSubview(front)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func rebuildRail() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = actions.map { action in
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: action.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
            button.tintColor = .white
            button.backgroundColor = action.color
            button.layer.cornerRadius = 22
            button.accessibilityLabel = action.title
            button.addAction(UIAction { [weak self] _ in
                Haptics.tap()
                self?.close(animated: true)
                action.handler()
            }, for: .touchUpInside)
            rail.addSubview(button)
            return button
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        front.frame = CGRect(x: offset, y: 0, width: bounds.width, height: contentHeight)
        let width = railWidth
        rail.frame = CGRect(x: bounds.width - width, y: 0, width: width, height: contentHeight)
        let shown = width > 0 ? min(1, -offset / width) : 0
        for (index, button) in buttons.enumerated() {
            button.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
            button.center = CGPoint(x: 8 + 22 + CGFloat(index) * 54, y: contentHeight / 2)
            // Each button grows in as the row uncovers it.
            let scale = 0.5 + 0.5 * min(1, max(0, shown * 1.4 - CGFloat(buttons.count - 1 - index) * 0.15))
            button.transform = CGAffineTransform(scaleX: scale, y: scale)
            button.alpha = min(1, shown * 1.6)
        }
    }

    var isOpen: Bool { offset < -1 }

    func close(animated: Bool) { set(offset: 0, animated: animated, velocity: 0) }

    private func set(offset target: CGFloat, animated: Bool, velocity: CGFloat) {
        animator?.stopAnimation(true)
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            offset = target
            setNeedsLayout()
            layoutIfNeeded()
            return
        }
        let distance = target - offset
        let relative = abs(distance) > 1 ? velocity / distance : 0
        let timing = UISpringTimingParameters(dampingRatio: 0.86, initialVelocity: CGVector(dx: relative, dy: 0))
        let animator = UIViewPropertyAnimator(duration: 0.42, timingParameters: timing)
        offset = target
        animator.addAnimations { self.setNeedsLayout(); self.layoutIfNeeded() }
        animator.startAnimation()
        self.animator = animator
    }

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer, !actions.isEmpty else { return false }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y) * 1.2 && (velocity.x < 0 || isOpen)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let width = railWidth
        switch pan.state {
        case .began:
            animator?.stopAnimation(true)
            panStart = offset
            onOpen?(self)
        case .changed:
            var next = panStart + pan.translation(in: self).x
            // Past the actions and past the resting place the row resists.
            if next < -width { next = -width - pow(-width - next, 0.7) }
            if next > 0 { next = pow(next, 0.7) }
            offset = next
            setNeedsLayout()
        case .ended, .cancelled:
            let velocity = pan.velocity(in: self).x
            let open = velocity < -350 || (velocity < 350 && offset < -width / 2)
            if open, offset > -width - 1 || velocity < 0 { Haptics.soft(0.4) }
            set(offset: open ? -width : 0, animated: true, velocity: velocity)
        default: break
        }
    }
}

// MARK: - Rows

/// Lets touches between its controls through to the view behind (the row's card).
final class PassThroughStackView: UIStackView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// One server: flag, name, protocol badges and the latency (tap it to test again).
final class ServerRowView: SwipeRow {
    let card = TapControl()
    let flag = UILabel(font: .systemFont(ofSize: 22))
    let globe = UIImageView(image: UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20)))
    let name = UILabel(font: Theme.font(17, .medium))
    let badges = BadgeRow()
    let check = UIImageView(image: UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)))
    let ping = UILabel(font: Theme.font(13), color: .secondaryLabel)
    let spinner = UIActivityIndicatorView(style: .medium)
    let pingButton = TapControl()
    private(set) var key: (subscription: Int64, node: String) = (0, "")
    /// A single server shown on its own: the subscription surface is its card.
    var plain = false {
        didSet { card.backgroundColor = plain ? .clear : .secondarySystemGroupedBackground }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.ripple = true
        card.rippleCornerRadius = 14
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        front.addSubview(card)
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
        let row = PassThroughStackView(.horizontal, spacing: 12, alignment: .center, [leading, text, pingButton])
        text.isUserInteractionEnabled = false
        leading.isUserInteractionEnabled = false
        card.addSubview(row)
        row.pin(to: card, insets: UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 16))
        NSLayoutConstraint.activate([pingButton.heightAnchor.constraint(equalTo: row.heightAnchor)])
    }

    func bind(_ subscription: Int64, _ node: String) { key = (subscription, node) }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = front.bounds
    }

    func setHeld(_ held: Bool) {
        UIView.animate(withDuration: 0.18) {
            self.card.backgroundColor = held ? UIColor.label.withAlphaComponent(0.09) : (self.plain ? .clear : .secondarySystemGroupedBackground)
        }
    }
}

/// The head of a subscription: name, pin, refresh spinner, server count, chevron.
final class SubscriptionHeaderView: SwipeRow {
    let tap = TapControl()
    let title = UILabel(font: Theme.font(17, .semibold))
    let pin = UIImageView(image: UIImage(systemName: "pin.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
    let count = UILabel(font: Theme.font(13, .medium), color: .secondaryLabel)
    let chevron = UIImageView(image: UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
    let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentHeight = ServerListView.headerHeight
        tap.ripple = true
        tap.rippleCornerRadius = 24
        tap.pressScale = 1
        front.addSubview(tap)
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
        row.isUserInteractionEnabled = false
        tap.addSubview(row)
        row.pin(to: tap, insets: UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20))
        NSLayoutConstraint.activate([count.heightAnchor.constraint(equalToConstant: 24), count.widthAnchor.constraint(greaterThanOrEqualToConstant: 34)])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tap.frame = front.bounds
    }

    /// `progress`: how open the subscription is, 0…1, straight from the spring.
    func show(progress: CGFloat) {
        chevron.transform = CGAffineTransform(rotationAngle: .pi * progress)
        count.backgroundColor = SurfaceView.blend(UIColor.label.withAlphaComponent(0.06), Theme.accent.withAlphaComponent(0.14), progress, traits: traitCollection)
        count.textColor = SurfaceView.blend(.secondaryLabel, Theme.accent, progress, traits: traitCollection)
    }
}

/// The surface of one subscription: the card when closed, the container when open.
/// It clips what it holds, so its moving bottom edge uncovers the server cards.
final class SurfaceView: UIView {
    let header = SubscriptionHeaderView()
    static let card = UIColor.secondarySystemGroupedBackground
    static let container = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.067, green: 0.067, blue: 0.075, alpha: 1) : UIColor(red: 0.914, green: 0.914, blue: 0.933, alpha: 1)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerCurve = .continuous
        addSubview(header)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func show(progress: CGFloat, standalone: Bool) {
        header.isHidden = standalone
        backgroundColor = standalone ? Self.card : Self.blend(Self.card, Self.container, progress, traits: traitCollection)
        layer.cornerRadius = 24 - 2 * progress
        if !standalone { header.show(progress: progress) }
    }

    static func blend(_ from: UIColor, _ to: UIColor, _ t: CGFloat, traits: UITraitCollection) -> UIColor {
        var a = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0)), b = a
        from.resolvedColor(with: traits).getRed(&a.r, green: &a.g, blue: &a.b, alpha: &a.a)
        to.resolvedColor(with: traits).getRed(&b.r, green: &b.g, blue: &b.b, alpha: &b.a)
        let t = max(0, min(1, t))
        return UIColor(red: a.r + (b.r - a.r) * t, green: a.g + (b.g - a.g) * t, blue: a.b + (b.b - a.b) * t, alpha: a.a + (b.a - a.a) * t)
    }
}

// MARK: - List

final class ServerListView: UIScrollView {
    struct Section: Equatable {
        var id: Int64
        var standalone: Bool
        var nodes: [String]
    }

    static let margin: CGFloat = 16
    static let headerHeight: CGFloat = 66
    static let rowPitch: CGFloat = 69
    static let rowHeight: CGFloat = 63
    static let rowInset: CGFloat = 8
    static let tail: CGFloat = 5
    static let gap: CGFloat = 10

    var configureHeader: ((SubscriptionHeaderView, Int64) -> Void)?
    var configureRow: ((ServerRowView, Int64, String) -> Void)?
    var actionsForHeader: ((Int64) -> [SwipeAction])?
    var actionsForRow: ((Int64, String) -> [SwipeAction])?
    var onToggle: ((Int64) -> Void)?
    var onSelect: ((Int64, String) -> Void)?
    var onPing: ((Int64, String) -> Void)?
    /// A long press: the subscription, the server (nil for the head) and how to undo the highlight.
    var onHold: ((Int64, String?, CGPoint, @escaping () -> Void) -> Void)?

    private(set) var sections: [Section] = []
    private var springs: [Int64: DisclosureSpring] = [:]
    private var surfaces: [Int64: SurfaceView] = [:]
    private var rows: [String: ServerRowView] = [:]
    private var pool: [ServerRowView] = []
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private weak var openSwipe: SwipeRow?

    override init(frame: CGRect) {
        super.init(frame: frame)
        alwaysBounceVertical = true
        delaysContentTouches = false
        backgroundColor = .clear
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.4
        addGestureRecognizer(hold)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    deinit { link?.invalidate() }

    /// A horizontal drag belongs to the row under it (its actions), not to the list.
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        if gesture === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            if abs(velocity.x) > abs(velocity.y) * 1.2 { return false }
        }
        return super.gestureRecognizerShouldBegin(gesture)
    }

    override func touchesShouldCancel(in view: UIView) -> Bool { true }

    // MARK: Data

    func isOpen(_ id: Int64) -> Bool { (springs[id]?.target ?? 0) > 0.5 }

    /// New content without animation; open subscriptions stay open.
    func set(_ next: [Section], open: Set<Int64>) {
        sections = next
        let ids = Set(next.map(\.id))
        for id in Array(surfaces.keys) where !ids.contains(id) {
            surfaces[id]?.removeFromSuperview()
            surfaces[id] = nil
            springs[id] = nil
        }
        for section in next {
            let wanted: CGFloat = !section.standalone && open.contains(section.id) ? 1 : 0
            if springs[section.id] == nil { springs[section.id] = DisclosureSpring(wanted) }
            if springs[section.id]?.target != wanted, link == nil { springs[section.id] = DisclosureSpring(wanted) }
            if surfaces[section.id] == nil {
                let surface = SurfaceView()
                surface.header.tap.onTap = { [weak self] in self?.tappedHeader(section.id) }
                surface.header.onOpen = { [weak self] row in self?.swipeStarted(row) }
                insertSubview(surface, at: 0)
                surfaces[section.id] = surface
            }
        }
        for (key, row) in rows { recycle(row); rows[key] = nil }
        reconfigureHeaders()
        layoutList()
    }

    /// Opens or closes a subscription with the spring.
    func setOpen(_ id: Int64, _ open: Bool) {
        guard var spring = springs[id] else { return }
        closeSwipe()
        spring.target = open ? 1 : 0
        springs[id] = spring
        if UIAccessibility.isReduceMotionEnabled {
            springs[id] = DisclosureSpring(spring.target)
            layoutList()
            return
        }
        startClock()
    }

    func reconfigureHeaders() {
        for section in sections {
            guard let surface = surfaces[section.id] else { continue }
            configureHeader?(surface.header, section.id)
            surface.header.actions = actionsForHeader?(section.id) ?? []
        }
    }

    func reconfigureRows(_ match: (Int64, String) -> Bool = { _, _ in true }) {
        for row in rows.values where match(row.key.subscription, row.key.node) {
            configureRow?(row, row.key.subscription, row.key.node)
        }
    }

    func row(for subscription: Int64, node: String) -> ServerRowView? { rows[Self.key(subscription, node)] }

    func headerHeld(_ id: Int64, _ held: Bool) {
        UIView.animate(withDuration: 0.18) { self.surfaces[id]?.header.front.backgroundColor = held ? UIColor.label.withAlphaComponent(0.07) : .clear }
    }

    private static func key(_ subscription: Int64, _ node: String) -> String { "\(subscription):\(node)" }

    // MARK: Clock

    private func startClock() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        }
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTick = CACurrentMediaTime()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = CGFloat(max(0, now - lastTick))
        lastTick = now
        var moving = false
        for (id, var spring) in springs where !spring.isSettled || spring.value != spring.target {
            spring.step(dt)
            springs[id] = spring
            if !spring.isSettled { moving = true }
        }
        layoutList()
        if !moving {
            link.invalidate()
            self.link = nil
        }
    }

    // MARK: Layout

    private func bodyHeight(_ section: Section) -> CGFloat {
        section.standalone || section.nodes.isEmpty ? 0 : CGFloat(section.nodes.count) * Self.rowPitch + Self.tail
    }

    private var laidOutWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != laidOutWidth {
            laidOutWidth = bounds.width
            layoutList()
        } else if link == nil {
            // Scrolling only needs rows placed for the new visible part.
            placeRows()
        }
    }

    private func layoutList() {
        let width = bounds.width - 2 * Self.margin
        var y: CGFloat = 0
        for section in sections {
            guard let surface = surfaces[section.id] else { continue }
            let progress = max(0, springs[section.id]?.value ?? 0)
            let height = Self.headerHeight + bodyHeight(section) * progress
            surface.frame = CGRect(x: Self.margin, y: y, width: width, height: height)
            surface.header.frame = CGRect(x: 0, y: 0, width: width, height: Self.headerHeight)
            surface.show(progress: min(1, progress), standalone: section.standalone)
            y += height + Self.gap
        }
        let size = CGSize(width: bounds.width, height: max(0, y - Self.gap) + 24)
        if contentSize != size { contentSize = size }
        // A closing subscription near the end pulls the list back with it.
        let maxOffset = max(-adjustedContentInset.top, contentSize.height + adjustedContentInset.bottom - bounds.height)
        if contentOffset.y > maxOffset, !isDragging { contentOffset.y = maxOffset }
        placeRows()
    }

    /// Creates, reuses and positions the server rows that are on screen.
    private func placeRows() {
        let visible = CGRect(x: 0, y: contentOffset.y - 120, width: bounds.width, height: bounds.height + 240)
        var used = Set<String>()
        for section in sections {
            guard let surface = surfaces[section.id] else { continue }
            let frame = surface.frame
            guard frame.intersects(visible) else { continue }
            let width = frame.width
            if section.standalone {
                guard let node = section.nodes.first else { continue }
                let row = rowView(section.id, node, in: surface, used: &used, plain: true)
                row.frame = CGRect(x: 0, y: 0, width: width, height: Self.headerHeight)
                row.contentHeight = Self.headerHeight
                row.alpha = 1
                row.front.transform = .identity
                continue
            }
            let revealed = frame.height - Self.headerHeight
            guard revealed > 0.5 else { continue }
            let firstTop = visible.minY - frame.minY - Self.headerHeight
            let lastBottom = min(visible.maxY - frame.minY, frame.height) - Self.headerHeight
            let first = max(0, Int(floor(firstTop / Self.rowPitch)))
            let last = min(section.nodes.count - 1, Int(ceil(lastBottom / Self.rowPitch)))
            guard first <= last else { continue }
            for index in first ... last {
                let top = Self.headerHeight + 3 + CGFloat(index) * Self.rowPitch
                guard top < frame.height else { break }
                let row = rowView(section.id, section.nodes[index], in: surface, used: &used, plain: false)
                row.contentHeight = Self.rowHeight
                row.frame = CGRect(x: Self.rowInset, y: top, width: width - 2 * Self.rowInset, height: Self.rowHeight)
                // A card being uncovered settles into place: it fades in and comes
                // down the last few points as the edge passes it.
                let shown = max(0, min(1, (frame.height - top) / (Self.rowHeight + Self.tail + 3)))
                let eased = shown * shown * (3 - 2 * shown)
                row.alpha = eased
                row.front.transform = eased < 1 ? CGAffineTransform(translationX: 0, y: -10 * (1 - eased)).scaledBy(x: 0.97 + 0.03 * eased, y: 0.97 + 0.03 * eased) : .identity
            }
        }
        for (key, row) in rows where !used.contains(key) {
            recycle(row)
            rows[key] = nil
        }
    }

    private func rowView(_ subscription: Int64, _ node: String, in surface: SurfaceView, used: inout Set<String>, plain: Bool) -> ServerRowView {
        let key = Self.key(subscription, node)
        used.insert(key)
        if let row = rows[key] {
            if row.superview !== surface { surface.addSubview(row) }
            return row
        }
        let row = pool.popLast() ?? makeRow()
        row.bind(subscription, node)
        row.plain = plain
        row.close(animated: false)
        configureRow?(row, subscription, node)
        row.actions = actionsForRow?(subscription, node) ?? []
        surface.addSubview(row)
        rows[key] = row
        return row
    }

    private func makeRow() -> ServerRowView {
        let row = ServerRowView()
        row.card.onTap = { [weak self, weak row] in
            guard let self, let row else { return }
            if self.closeSwipe() { return }
            self.onSelect?(row.key.subscription, row.key.node)
        }
        row.pingButton.onTap = { [weak self, weak row] in
            guard let self, let row else { return }
            if self.closeSwipe() { return }
            self.onPing?(row.key.subscription, row.key.node)
        }
        row.onOpen = { [weak self] row in self?.swipeStarted(row) }
        return row
    }

    private func recycle(_ row: ServerRowView) {
        row.removeFromSuperview()
        row.close(animated: false)
        row.alpha = 1
        row.front.transform = .identity
        if openSwipe === row { openSwipe = nil }
        pool.append(row)
    }

    // MARK: Interaction

    private func tappedHeader(_ id: Int64) {
        if closeSwipe() { return }
        onToggle?(id)
    }

    private func swipeStarted(_ row: SwipeRow) {
        if let open = openSwipe, open !== row { open.close(animated: true) }
        openSwipe = row
    }

    /// Closes an open swipe; true when there was one (the tap only closes it).
    @discardableResult
    func closeSwipe() -> Bool {
        guard let open = openSwipe, open.isOpen else { return false }
        open.close(animated: true)
        openSwipe = nil
        return true
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        closeSwipe()
        super.touchesBegan(touches, with: event)
    }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: self)
        for section in sections {
            guard let surface = surfaces[section.id], surface.frame.contains(point) else { continue }
            let local = convert(point, to: surface)
            if section.standalone, let node = section.nodes.first, let row = rows[Self.key(section.id, node)] {
                row.setHeld(true)
                onHold?(section.id, node, point) { [weak row] in row?.setHeld(false) }
            } else if local.y < Self.headerHeight {
                headerHeld(section.id, true)
                onHold?(section.id, nil, point) { [weak self] in self?.headerHeld(section.id, false) }
            } else if let row = rows.values.first(where: { $0.superview === surface && $0.frame.contains(local) }) {
                row.setHeld(true)
                onHold?(section.id, row.key.node, point) { [weak row] in row?.setHeld(false) }
            }
            return
        }
    }
}
