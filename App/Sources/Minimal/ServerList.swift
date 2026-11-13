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

    /// The system's own feel: opening is the "snappy" spring (a hint of bounce as the
    /// container lands), closing the "smooth" one (no bounce) and a little quicker.
    mutating func step(_ dt: CGFloat) {
        let opening = target > 0.5
        let response: CGFloat = opening ? 0.42 : 0.36
        let ratio: CGFloat = opening ? 0.86 : 1
        let omega = 2 * .pi / response
        let stiffness = omega * omega
        let damping = 2 * ratio * omega
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

/// An action behind a row: a capsule with its title and symbol.
struct SwipeAction {
    var symbol: String
    var color: UIColor
    var title: String
    var handler: () -> Void
}

/// One capsule of the actions. It is clipped to its current width and its content
/// sits at its right end, so as it widens the symbol shows first and the title
/// flows out after it (as in the Music app's queue).
private final class SwipePill: UIControl {
    let action: SwipeAction
    private let clip = UIView()
    private let content = UIStackView()
    private let icon = UIImageView()
    private let label = UILabel()
    let naturalWidth: CGFloat

    /// `titled`: the capsule at the edge carries its title; the others only a symbol
    /// (three titles do not fit beside a row).
    init(_ action: SwipeAction, titled: Bool) {
        self.action = action
        label.text = action.title
        label.font = Theme.font(15, .semibold)
        label.isHidden = !titled
        icon.image = UIImage(systemName: action.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        icon.contentMode = .center
        naturalWidth = titled ? 16 + ceil(label.intrinsicContentSize.width) + 7 + 20 + 14 : 46
        super.init(frame: .zero)
        clip.isUserInteractionEnabled = false
        clip.clipsToBounds = true
        clip.layer.cornerCurve = .continuous
        addSubview(clip)
        content.axis = .horizontal
        content.spacing = 7
        content.alignment = .center
        content.addArrangedSubview(label)
        content.addArrangedSubview(icon)
        content.isUserInteractionEnabled = false
        clip.addSubview(content)
        accessibilityLabel = action.title
        isAccessibilityElement = true
        accessibilityTraits = .button
        paint()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    /// The action's colour from the first point of the swipe; the symbol and the
    /// title are white.
    private func paint() {
        clip.backgroundColor = action.color
        let ink: UIColor = .white
        label.textColor = ink
        icon.tintColor = ink
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clip.frame = bounds
        clip.layer.cornerRadius = min(bounds.width, bounds.height) / 2
        // Content keeps its size at the right end; a narrow capsule shows its symbol first.
        let inset: CGFloat = label.isHidden ? 13 : 14
        let width = label.isHidden ? 20 : naturalWidth - 30
        content.frame = CGRect(x: bounds.width - inset - width, y: 0, width: width, height: bounds.height)
    }

    override var isHighlighted: Bool {
        didSet { UIView.animate(withDuration: 0.12) { self.clip.alpha = self.isHighlighted ? 0.75 : 1 } }
    }
}

/// A view whose `front` slides left to uncover its actions. A full swipe only
/// opens them: nothing is ever deleted by a swipe alone.
class SwipeRow: UIView, UIGestureRecognizerDelegate {
    let front = UIView()
    /// Height of the content; the view itself may be shorter while it is uncovered.
    var contentHeight: CGFloat = 63
    var onOpen: ((SwipeRow) -> Void)?
    private let rail = UIView()
    private var pills: [SwipePill] = []
    /// The actions are fully out (a light tap of the haptics when they get there).
    private var fullyOut = false
    private(set) var offset: CGFloat = 0
    private var panStart: CGFloat = 0
    private var animator: UIViewPropertyAnimator?
    private static let gap: CGFloat = 6
    private static let margin: CGFloat = 8

    /// The capsules are built when a swipe first needs them, not with the row:
    /// rows appear by the dozen as a subscription opens, and building three
    /// symbol buttons for each of them cost the first frames of the motion.
    var actions: [SwipeAction] = [] {
        didSet {
            railStale = true
            if !pills.isEmpty || offset != 0 { rebuildRail() }
        }
    }
    private var railStale = false

    /// How far the row moves to show every action at full width.
    private var railWidth: CGFloat {
        pills.isEmpty ? 0 : pills.reduce(0) { $0 + $1.naturalWidth } + CGFloat(pills.count - 1) * Self.gap + 2 * Self.margin
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
        railStale = false
        pills.forEach { $0.removeFromSuperview() }
        pills = actions.map { action in
            // All the same round symbol buttons, «Удалить» included (the title stays
            // for VoiceOver).
            let pill = SwipePill(action, titled: false)
            pill.addAction(UIAction { [weak self] _ in
                Haptics.tap()
                self?.close(animated: true)
                action.handler()
            }, for: .touchUpInside)
            rail.addSubview(pill)
            return pill
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        front.frame = CGRect(x: offset, y: 0, width: bounds.width, height: contentHeight)
        rail.frame = CGRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
        guard !pills.isEmpty else { return }
        let full = railWidth
        let pulled = max(0, -offset)
        let progress = full > 0 ? min(1, pulled / full) : 0
        // Past full width the last capsule (the one at the edge) stretches with the finger.
        let extra = max(0, pulled - full)
        let height = min(46, contentHeight - 16)
        var right = bounds.width - Self.margin * progress
        for (index, pill) in pills.enumerated().reversed() {
            var width = pill.naturalWidth * progress
            if index == pills.count - 1 { width += extra }
            let frame = CGRect(x: right - width, y: (contentHeight - height) / 2, width: width, height: height)
            if pill.frame != frame { pill.frame = frame }
            pill.isHidden = width < 1
            right -= width + Self.gap * progress
        }
        let out = progress > 0.97
        if out != fullyOut {
            fullyOut = out
            if out, panning { Haptics.soft(0.45) }
        }
    }

    var isOpen: Bool { offset < -1 }

    func close(animated: Bool) { set(offset: 0, animated: animated, velocity: 0) }

    private var panning = false

    private func set(offset target: CGFloat, animated: Bool, velocity: CGFloat) {
        animator?.stopAnimation(true)
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            offset = target
            setNeedsLayout()
            layoutIfNeeded()
            return
        }
        let distance = target - offset
        let relative = abs(distance) > 1 ? max(-30, min(30, velocity / distance)) : 0
        let timing = UISpringTimingParameters(dampingRatio: 0.88, initialVelocity: CGVector(dx: relative, dy: 0))
        let animator = UIViewPropertyAnimator(duration: 0.44, timingParameters: timing)
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
            if railStale { rebuildRail() }
            animator?.stopAnimation(true)
            panStart = offset
            panning = true
            onOpen?(self)
        case .changed:
            var next = panStart + pan.translation(in: self).x
            // Past the actions and past the resting place the row resists.
            if next < -width { next = -width - pow(-width - next, 0.8) }
            if next > 0 { next = pow(next, 0.7) }
            offset = next
            setNeedsLayout()
        case .ended, .cancelled:
            panning = false
            let velocity = pan.velocity(in: self).x
            let open = velocity < -350 || (velocity < 350 && offset < -width / 2)
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
    /// «Выбрать несколько»: the selection circle in front of the row.
    let mark = UIImageView()
    private(set) var key: (subscription: Int64, node: String) = (0, "")
    /// A single server shown on its own: the subscription surface is its card.
    var plain = false {
        didSet { card.backgroundColor = plain ? .clear : .secondarySystemGroupedBackground }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Clipped at the container's edge while uncovered; faded without an
        // offscreen group pass (each layer fades on its own).
        clipsToBounds = true
        layer.allowsGroupOpacity = false
        // A plain dim when pressed: the spreading shade is kept for the two big
        // buttons of Home (it cost frames as the list moved under it).
        card.pressScale = 1
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
        mark.contentMode = .center
        mark.isHidden = true
        mark.setContentHuggingPriority(.required, for: .horizontal)
        let row = PassThroughStackView(.horizontal, spacing: 12, alignment: .center, [mark, leading, text, pingButton])
        text.isUserInteractionEnabled = false
        leading.isUserInteractionEnabled = false
        card.addSubview(row)
        row.pin(to: card, insets: UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 16))
        NSLayoutConstraint.activate([pingButton.heightAnchor.constraint(equalTo: row.heightAnchor)])
    }

    func bind(_ subscription: Int64, _ node: String) { key = (subscription, node) }

    /// nil: not selecting; otherwise whether this row is selected.
    func setMark(_ selected: Bool?) {
        SelectionMark.apply(selected, to: mark)
    }

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
    let mark = UIImageView()
    /// The count's pill, a plain layer behind it (no masking).
    private let countPill = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentHeight = ServerListView.headerHeight
        tap.pressScale = 1
        front.addSubview(tap)
        pin.tintColor = Theme.accent
        pin.setContentHuggingPriority(.required, for: .horizontal)
        chevron.tintColor = .secondaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        count.textAlignment = .center
        countPill.layer.cornerRadius = 12
        countPill.isUserInteractionEnabled = false
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.hidesWhenStopped = true
        mark.contentMode = .center
        mark.isHidden = true
        mark.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(.horizontal, spacing: 8, alignment: .center, [mark, title, pin, UIView(), spinner, count, chevron])
        row.setCustomSpacing(12, after: count)
        row.isUserInteractionEnabled = false
        tap.addSubview(row)
        row.pin(to: tap, insets: UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20))
        NSLayoutConstraint.activate([count.heightAnchor.constraint(equalToConstant: 24), count.widthAnchor.constraint(greaterThanOrEqualToConstant: 34)])
        tap.insertSubview(countPill, at: 0)
        countPill.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            countPill.leadingAnchor.constraint(equalTo: count.leadingAnchor), countPill.trailingAnchor.constraint(equalTo: count.trailingAnchor),
            countPill.topAnchor.constraint(equalTo: count.topAnchor), countPill.bottomAnchor.constraint(equalTo: count.bottomAnchor),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tap.frame = front.bounds
    }

    func setMark(_ selected: Bool?) {
        SelectionMark.apply(selected, to: mark)
    }

    /// `progress`: how open the subscription is, 0…1, straight from the spring.
    func show(progress: CGFloat) {
        chevron.transform = CGAffineTransform(rotationAngle: .pi * progress)
        countPill.backgroundColor = SurfaceView.blend(UIColor.label.withAlphaComponent(0.06), Theme.accent.withAlphaComponent(0.14), progress, traits: traitCollection)
        count.textColor = SurfaceView.blend(.secondaryLabel, Theme.accent, progress, traits: traitCollection)
    }
}

/// The tags an open subscription can be narrowed by (protocol, security,
/// transport, Vision, Xray): «Все» and the subscription's own, several at once.
final class FilterBar: UIScrollView {
    var onPick: ((String?) -> Void)?
    private let stack = UIStackView(.horizontal, spacing: 6, alignment: .center, [])
    private var shown: (tags: [String], selected: Set<String>) = ([], [])

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        alwaysBounceHorizontal = true
        clipsToBounds = true
        contentInset = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor, constant: -4),
            stack.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func show(tags: [String], selected: Set<String>) {
        guard tags != shown.tags || selected != shown.selected else { return }
        shown = (tags, selected)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(chip(L("Все"), on: selected.isEmpty) { [weak self] in self?.onPick?(nil) })
        for tag in tags {
            stack.addArrangedSubview(chip(tag, on: selected.contains(tag)) { [weak self] in self?.onPick?(tag) })
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> UIView {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        configuration.baseBackgroundColor = on ? Theme.accent : UIColor.label.withAlphaComponent(0.06)
        configuration.baseForegroundColor = on ? .white : .label
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.font(14, .semibold)
            return attributes
        }
        button.configuration = configuration
        button.addAction(UIAction { _ in
            Haptics.selection()
            action()
        }, for: .touchUpInside)
        return button
    }
}

/// The circle «Выбрать несколько» puts in front of rows and subscriptions.
enum SelectionMark {
    static func apply(_ selected: Bool?, to view: UIImageView) {
        guard let selected else {
            view.isHidden = true
            return
        }
        view.isHidden = false
        view.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle", withConfiguration: UIImage.SymbolConfiguration(textStyle: .title3))
        view.tintColor = selected ? Theme.accent : .secondaryLabel
    }
}

/// The provider's line under an open subscription's head: traffic used of the
/// limit on the left, until when it is active on the right.
final class SubscriptionInfoStrip: UIView {
    private let traffic = UILabel(font: Theme.font(.footnote), color: .secondaryLabel)
    private let expiry = UILabel(font: Theme.font(.footnote), color: .secondaryLabel)
    private let trafficIcon = UIImageView(image: UIImage(systemName: "arrow.up.arrow.down", withConfiguration: UIImage.SymbolConfiguration(font: Theme.font(.caption1, .medium))))
    private let expiryIcon = UIImageView(image: UIImage(systemName: "calendar", withConfiguration: UIImage.SymbolConfiguration(font: Theme.font(.caption1, .medium))))
    private var shown: (String?, String?) = (nil, nil)

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        for icon in [trafficIcon, expiryIcon] {
            icon.tintColor = .secondaryLabel
            icon.contentMode = .center
            addSubview(icon)
        }
        for label in [traffic, expiry] {
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.8
            addSubview(label)
        }
        expiry.textAlignment = .right
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func show(traffic text: String?, expiry date: String?) {
        guard shown.0 != text || shown.1 != date else { return }
        shown = (text, date)
        traffic.text = text
        expiry.text = date
        trafficIcon.isHidden = text == nil
        expiryIcon.isHidden = date == nil
        accessibilityLabel = [text, date].compactMap { $0 }.joined(separator: ", ")
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 20, icon: CGFloat = 16, gap: CGFloat = 5
        let height: CGFloat = ServerListView.infoHeight
        let top: CGFloat = 0
        var left = inset
        let right = bounds.width - inset
        let both = shown.0 != nil && shown.1 != nil
        let half = (bounds.width - 2 * inset - 12) / 2
        if shown.0 != nil {
            let want = ceil(traffic.intrinsicContentSize.width)
            let width = min(want, (both ? half : bounds.width - 2 * inset) - icon - gap)
            trafficIcon.frame = CGRect(x: left, y: top, width: icon, height: height)
            traffic.frame = CGRect(x: left + icon + gap, y: top, width: width, height: height)
            left += icon + gap + width + 12
        }
        if shown.1 != nil {
            let want = ceil(expiry.intrinsicContentSize.width)
            let room = both ? max(half, right - left) : bounds.width - 2 * inset
            let width = min(want, room - icon - gap)
            expiry.frame = CGRect(x: right - width, y: top, width: width, height: height)
            expiryIcon.frame = CGRect(x: right - width - gap - icon, y: top, width: icon, height: height)
            if !both {
                // Alone it sits where the traffic would: on the left.
                expiryIcon.frame.origin.x = inset
                expiry.frame.origin.x = inset + icon + gap
            }
        }
    }
}

/// The surface of one subscription: the card when closed, the container when open.
/// It clips what it holds, so its moving bottom edge uncovers the server cards.
final class SurfaceView: UIView {
    let header = SubscriptionHeaderView()
    let info = SubscriptionInfoStrip()
    let filters = FilterBar()
    static let card = UIColor.secondarySystemGroupedBackground
    static let container = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.067, green: 0.067, blue: 0.075, alpha: 1) : UIColor(red: 0.914, green: 0.914, blue: 0.933, alpha: 1)
    }

    private var shownProgress: CGFloat = -1
    private var shownStandalone: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // No clipping: a rounded mask over moving content renders offscreen every
        // frame. The server rows clip themselves at the container's edge instead.
        layer.cornerCurve = .continuous
        addSubview(filters)
        addSubview(info)
        addSubview(header)
        filters.isHidden = true
        info.isHidden = true
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        shownProgress = -1
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    /// Restyles only when something changed: still subscriptions cost nothing per frame.
    func show(progress: CGFloat, standalone: Bool) {
        guard abs(progress - shownProgress) > 0.001 || standalone != shownStandalone else { return }
        shownProgress = progress
        shownStandalone = standalone
        header.isHidden = standalone
        backgroundColor = standalone ? Self.card : Self.blend(Self.card, Self.container, progress, traits: traitCollection)
        // The radius changes once, not every frame (a moving radius redraws the shape).
        let radius: CGFloat = progress > 0.001 ? 22 : 24
        if layer.cornerRadius != radius { layer.cornerRadius = radius }
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
        /// Tags to narrow the open subscription by; empty: no filter bar.
        var tags: [String] = []
        var selected: Set<String> = []
        /// What the provider reports: traffic used of the limit, and until when.
        var traffic: String?
        var expiry: String?

        var hasInfo: Bool { !standalone && (traffic != nil || expiry != nil) }
    }

    static let filterHeight: CGFloat = 44
    static let infoHeight: CGFloat = 22
    /// The provider's line rises into the head's lower padding, so it sits close
    /// under the title (the head is 66 pt with its title centred).
    static let infoRise: CGFloat = 18

    /// Height of the strip under the open head: the provider's line, then the filters.
    private func stripHeight(_ section: Section) -> CGFloat {
        (section.hasInfo ? Self.infoHeight - Self.infoRise : 0) + (section.tags.isEmpty ? 0 : Self.filterHeight)
    }

    /// Where the open subscription's server rows begin, under the head, its line and its filters.
    private func rowsTop(_ section: Section) -> CGFloat {
        Self.headerHeight + stripHeight(section)
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
    /// A filter tag tapped (nil: «Все»).
    var onFilter: ((Int64, String?) -> Void)?
    var onSelect: ((Int64, String) -> Void)?
    var onPing: ((Int64, String) -> Void)?
    /// What a long press lifts above the dim under the menu: a view and its part.
    typealias HoldSource = (view: UIView, rect: CGRect)
    /// A long press: the subscription, the server (nil for the head), the pressed
    /// row and how to undo the highlight.
    var onHold: ((Int64, String?, CGPoint, HoldSource?, @escaping () -> Void) -> Void)?

    private(set) var sections: [Section] = []
    private var springs: [Int64: DisclosureSpring] = [:]
    /// While a subscription moves, the distance its spring covers. Only what can be
    /// seen is animated: a list of 160 servers opens over the part of it that fits
    /// the screen, at the same pace as a list of five, and the rest is simply there.
    private var travel: [Int64: CGFloat] = [:]
    /// A closing subscription whose head was scrolled away brings the list back to it.
    private var anchors: [Int64: (offset: CGFloat, from: CGFloat)] = [:]
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
        panGestureRecognizer.addTarget(self, action: #selector(dragged(_:)))
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
            travel[id] = nil
            anchors[id] = nil
        }
        for section in next {
            let wanted: CGFloat = !section.standalone && open.contains(section.id) ? 1 : 0
            if springs[section.id] == nil { springs[section.id] = DisclosureSpring(wanted) }
            if springs[section.id]?.target != wanted, link == nil { springs[section.id] = DisclosureSpring(wanted) }
            if surfaces[section.id] == nil {
                let surface = SurfaceView()
                surface.header.tap.onTap = { [weak self] in self?.tappedHeader(section.id) }
                surface.filters.onPick = { [weak self] tag in self?.onFilter?(section.id, tag) }
                surface.header.onOpen = { [weak self] row in self?.swipeStarted(row) }
                insertSubview(surface, at: 0)
                surfaces[section.id] = surface
            }
        }
        for (key, row) in rows { recycle(row); rows[key] = nil }
        // Rows are built ahead, so the first frames of a disclosure only place them.
        while pool.count < 16 { pool.append(makeRow()) }
        reconfigureHeaders()
        layoutList()
    }

    /// Opens or closes a subscription with the spring.
    func setOpen(_ id: Int64, _ open: Bool) {
        guard var spring = springs[id], let section = sections.first(where: { $0.id == id }), let surface = surfaces[id] else { return }
        closeSwipe()
        if UIAccessibility.isReduceMotionEnabled {
            springs[id] = DisclosureSpring(open ? 1 : 0)
            travel[id] = nil
            layoutList()
            return
        }
        let body = bodyHeight(section)
        let shown = revealed(section)
        // What fits between the head and the bottom of the screen, and a little more
        // so that the edge is still moving when it leaves.
        let extent = max(160, contentOffset.y + bounds.height - surface.frame.minY - Self.headerHeight + 100)
        if open {
            let distance = max(1, min(body, max(extent, shown)))
            spring.value = shown / distance
            travel[id] = distance
            anchors[id] = nil
        } else {
            // Everything below the screen goes at once; the spring closes what is seen.
            let distance = max(1, min(shown, extent))
            if shown > distance { spring.velocity = 0 }
            spring.value = 1
            travel[id] = distance
            let top = surface.frame.minY - adjustedContentInset.top
            anchors[id] = contentOffset.y > top ? (contentOffset.y, distance) : nil
        }
        spring.target = open ? 1 : 0
        springs[id] = spring
        layoutList()
        startClock()
    }

    func reconfigureHeaders() {
        for section in sections {
            guard let surface = surfaces[section.id] else { continue }
            configureHeader?(surface.header, section.id)
            surface.header.actions = actionsForHeader?(section.id) ?? []
        }
    }

    /// Swipe actions again (none while selecting), for every row and head.
    func reloadActions() {
        closeSwipe()
        for row in rows.values { row.actions = actionsForRow?(row.key.subscription, row.key.node) ?? [] }
        reconfigureHeaders()
    }

    func reconfigureRows(_ match: (Int64, String) -> Bool = { _, _ in true }) {
        for row in rows.values where match(row.key.subscription, row.key.node) {
            configureRow?(row, row.key.subscription, row.key.node)
        }
    }

    func row(for subscription: Int64, node: String) -> ServerRowView? { rows[Self.key(subscription, node)] }

    /// The press shade takes the card's own shape: all corners round when closed,
    /// only the top ones when the subscription is open under it.
    func headerHeld(_ id: Int64, _ held: Bool) {
        guard let surface = surfaces[id] else { return }
        let front = surface.header.front
        front.layer.cornerRadius = surface.layer.cornerRadius
        front.layer.cornerCurve = .continuous
        front.layer.maskedCorners = isOpen(id) ? [.layerMinXMinYCorner, .layerMaxXMinYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        UIView.animate(withDuration: 0.18) { front.backgroundColor = held ? UIColor.label.withAlphaComponent(0.07) : .clear }
    }

    private static func key(_ subscription: Int64, _ node: String) -> String { "\(subscription):\(node)" }

    /// A drag completes every running disclosure at once (as 1.5.0 did): the list
    /// is then as long as it really is, and a flick right after opening carries on
    /// through the servers instead of stopping where the motion had got to.
    /// Only openings: a closing subscription keeps its motion. (A touch that stops
    /// the list's own scrolling also begins a drag; it used to end a closing at once.)
    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .began, link != nil else { return }
        // At the top a downward drag closes the sheet: nothing may move the list under it.
        if contentOffset.y <= -adjustedContentInset.top + 1, pan.velocity(in: self).y > 0 {
            finishAll()
            return
        }
        finishOpenings()
    }

    private func finishAll() {
        for (id, spring) in springs {
            springs[id] = DisclosureSpring(spring.target)
            travel[id] = nil
            anchors[id] = nil
        }
        link?.invalidate()
        link = nil
        layoutList()
    }

    private func finishOpenings() {
        var moving = false
        for (id, spring) in springs where !spring.isSettled || spring.value != spring.target {
            if spring.target > 0.5 {
                springs[id] = DisclosureSpring(spring.target)
                travel[id] = nil
                anchors[id] = nil
            } else {
                moving = true
            }
        }
        if !moving {
            link?.invalidate()
            link = nil
        }
        layoutList()
    }

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
            if spring.target == 0, spring.value < 0 { spring = DisclosureSpring(0) }
            springs[id] = spring
            if spring.isSettled { travel[id] = nil; anchors[id] = nil } else { moving = true }
        }
        layoutList()
        if !moving {
            link.invalidate()
            self.link = nil
        }
    }

    // MARK: Layout

    private func bodyHeight(_ section: Section) -> CGFloat {
        guard !section.standalone else { return 0 }
        let strip = stripHeight(section)
        if section.nodes.isEmpty { return strip }
        return strip + CGFloat(section.nodes.count) * Self.rowPitch + Self.tail
    }

    /// Height of the open part of a subscription right now.
    private func revealed(_ section: Section) -> CGFloat {
        let value = springs[section.id]?.value ?? 0
        let body = bodyHeight(section)
        if let distance = travel[section.id] { return max(0, min(body + 8, value * distance)) }
        return value > 0.5 ? body : 0
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
            let height = Self.headerHeight + revealed(section)
            let frame = CGRect(x: Self.margin, y: y, width: width, height: height)
            if surface.frame != frame { surface.frame = frame }
            let headerFrame = CGRect(x: 0, y: 0, width: width, height: Self.headerHeight)
            if surface.header.frame != headerFrame { surface.header.frame = headerFrame }
            // The provider's line and the filter bar are uncovered by the moving edge like the rows.
            let shown = height - Self.headerHeight
            let hasInfo = section.hasInfo && shown > 0.5
            surface.info.isHidden = !hasInfo
            var stripTop = Self.headerHeight
            if hasInfo {
                surface.info.show(traffic: section.traffic, expiry: section.expiry)
                let infoFrame = CGRect(x: 0, y: stripTop - Self.infoRise, width: width, height: Self.infoHeight)
                if surface.info.frame != infoFrame { surface.info.frame = infoFrame }
                surface.info.alpha = min(1, shown / (Self.infoHeight - Self.infoRise))
            }
            if section.hasInfo { stripTop += Self.infoHeight - Self.infoRise }
            let filtersShown = shown - (stripTop - Self.headerHeight)
            let hasFilters = !section.standalone && !section.tags.isEmpty && filtersShown > 0.5
            surface.filters.isHidden = !hasFilters
            if hasFilters {
                surface.filters.show(tags: section.tags, selected: section.selected)
                let filterFrame = CGRect(x: 0, y: stripTop, width: width, height: min(Self.filterHeight, filtersShown))
                if surface.filters.frame != filterFrame { surface.filters.frame = filterFrame }
                surface.filters.alpha = min(1, filtersShown / Self.filterHeight)
            }
            surface.show(progress: min(1, progress), standalone: section.standalone)
            y += height + Self.gap
        }
        let size = CGSize(width: bounds.width, height: max(0, y - Self.gap) + 24)
        if contentSize != size { contentSize = size }
        // A closing subscription near the end pulls the list back with it.
        let maxOffset = max(-adjustedContentInset.top, contentSize.height + adjustedContentInset.bottom - bounds.height)
        if contentOffset.y > maxOffset, !isDragging { contentOffset.y = maxOffset }
        if !isDragging, !isDecelerating {
            for (id, anchor) in anchors {
                guard let surface = surfaces[id], let section = sections.first(where: { $0.id == id }) else { continue }
                let wanted = max(surface.frame.minY - adjustedContentInset.top, anchor.offset - (anchor.from - revealed(section)))
                if wanted < contentOffset.y { contentOffset.y = wanted }
            }
        }
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
            let top0 = rowsTop(section)
            let firstTop = visible.minY - frame.minY - top0
            let lastBottom = min(visible.maxY - frame.minY, frame.height) - top0
            let first = max(0, Int(floor(firstTop / Self.rowPitch)))
            let last = min(section.nodes.count - 1, Int(ceil(lastBottom / Self.rowPitch)))
            guard first <= last else { continue }
            for index in first ... last {
                let top = top0 + 3 + CGFloat(index) * Self.rowPitch
                guard top < frame.height else { break }
                let row = rowView(section.id, section.nodes[index], in: surface, used: &used, plain: false)
                row.contentHeight = Self.rowHeight
                // The row clips itself at the container's moving edge (a plain
                // rectangle clip, cheap), so the surface needs no mask.
                let rowFrame = CGRect(x: Self.rowInset, y: top, width: width - 2 * Self.rowInset, height: max(0, min(Self.rowHeight, frame.height - top)))
                if row.frame != rowFrame { row.frame = rowFrame }
                // A card being uncovered settles into place: it fades in and comes
                // down the last few points as the edge passes it.
                let shown = max(0, min(1, (frame.height - top) / (Self.rowHeight + Self.tail + 3)))
                let eased = shown * shown * (3 - 2 * shown)
                if row.alpha != eased { row.alpha = eased }
                let transform = eased < 1 ? CGAffineTransform(translationX: 0, y: -8 * (1 - eased)).scaledBy(x: 0.98 + 0.02 * eased, y: 0.98 + 0.02 * eased) : .identity
                if row.front.transform != transform { row.front.transform = transform }
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
            let head = CGRect(x: 0, y: 0, width: surface.bounds.width, height: Self.headerHeight)
            if section.standalone, let node = section.nodes.first, let row = rows[Self.key(section.id, node)] {
                row.setHeld(true)
                onHold?(section.id, node, point, (view: surface as UIView, rect: head)) { [weak row] in row?.setHeld(false) }
            } else if local.y < Self.headerHeight {
                headerHeld(section.id, true)
                onHold?(section.id, nil, point, (view: surface as UIView, rect: head)) { [weak self] in self?.headerHeld(section.id, false) }
            } else if let row = rows.values.first(where: { $0.superview === surface && $0.frame.contains(local) }) {
                row.setHeld(true)
                onHold?(section.id, row.key.node, point, (view: row.card as UIView, rect: row.card.bounds)) { [weak row] in row?.setHeld(false) }
            }
            return
        }
    }
}
