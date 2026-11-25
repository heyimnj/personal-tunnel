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

/// An action behind a row: a round button with its symbol (the title is for VoiceOver).
struct SwipeAction {
    var symbol: String
    var color: UIColor
    var title: String
    var handler: () -> Void
}

/// One action on the plate: its symbol in the action's colour over a slot of
/// the plate's full height.
final class PlateButton: UIControl {
    /// Replaced in place when the list hands the row the same actions again (3.1.7).
    var action: SwipeAction
    private let icon = UIImageView()
    private let shade = UIView()
    static let width: CGFloat = 50

    /// 3.1.6: symbols are drawn once and kept. The first swipe built them while
    /// the finger moved and the drop stuttered; the list warms them up front.
    private static var symbols: [String: UIImage] = [:]
    /// Draws the list's action symbols once, off screen (the sheet calls it as it opens).
    static func warmUp(_ names: [String] = ["pencil", "arrow.clockwise", "trash", "waveform.path.ecg"]) {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
        _ = renderer.image { _ in
            for name in names { symbol(name)?.withTintColor(.label).draw(in: CGRect(x: 0, y: 0, width: 24, height: 24)) }
        }
    }

    static func symbol(_ name: String) -> UIImage? {
        if let image = symbols[name] { return image }
        let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        symbols[name] = image
        return image
    }

    init(_ action: SwipeAction) {
        self.action = action
        super.init(frame: .zero)
        shade.isUserInteractionEnabled = false
        shade.backgroundColor = action.color.withAlphaComponent(0.18)
        shade.layer.cornerCurve = .continuous
        shade.alpha = 0
        addSubview(shade)
        icon.image = Self.symbol(action.symbol)
        icon.contentMode = .center
        icon.tintColor = action.color
        icon.isUserInteractionEnabled = false
        addSubview(icon)
        accessibilityLabel = action.title
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    /// 3.2.7: the press is a whole round button around the symbol — a circle
    /// centred on it, as wide as the plate allows — not a tall tinted strip cut
    /// from the plate (the owner: «как будто обрывок»).
    override func layoutSubviews() {
        super.layoutSubviews()
        icon.bounds = CGRect(origin: .zero, size: bounds.size)
        icon.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let side = max(0, min(bounds.width - 4, bounds.height - 12, 44))
        shade.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        shade.center = icon.center
        shade.layer.cornerRadius = side / 2
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            if isHighlighted {
                // Grows out of the symbol, which sinks a little under the finger.
                if shade.alpha < 0.05 { shade.transform = CGAffineTransform(scaleX: 0.55, y: 0.55) }
                UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0,
                               options: [.beginFromCurrentState, .allowUserInteraction]) {
                    self.shade.alpha = 1
                    self.shade.transform = .identity
                    self.icon.transform = CGAffineTransform(scaleX: 0.86, y: 0.86)
                }
            } else {
                // Lets go: the symbol springs back, the circle swells slightly and fades.
                UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0,
                               options: [.beginFromCurrentState, .allowUserInteraction]) {
                    self.icon.transform = .identity
                }
                UIView.animate(withDuration: 0.26, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
                    self.shade.alpha = 0
                    self.shade.transform = CGAffineTransform(scaleX: 1.08, y: 1.08)
                }
            }
        }
    }
}

/// The actions behind a row (3.1.2): one plate of the card's colour, height and
/// rounding that comes out of the card's right side as the card moves away —
/// a thin capsule first, then wider with the finger. The symbols sit at their
/// final places against the right end and are uncovered as the plate widens
/// (it clips them), as in the reference the owner gave.
private final class ActionPlate: UIView {
    private(set) var buttons: [PlateButton] = []
    /// The card's colour. 3.5 beta 4 (the owner): the plate takes it gradually over
    /// the swipe, as the open head's card does (`SurfaceView.cardShown`), not at once.
    var tint: UIColor = .secondarySystemGroupedBackground {
        didSet { shownTint = -1 }
    }
    private var shownTint: CGFloat = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    var fullWidth: CGFloat { CGFloat(buttons.count) * PlateButton.width + 8 }

    /// 3.1.7: the same actions again (every ping or traffic update hands them
    /// over) keep the buttons that are already built and drawn; only their
    /// handlers change.
    func set(_ actions: [SwipeAction], tap: @escaping (SwipeAction) -> Void) {
        if buttons.count == actions.count, zip(buttons, actions).allSatisfy({ Self.same($0.action, $1) }) {
            for (button, action) in zip(buttons, actions) { button.action = action }
            return
        }
        buttons.forEach { $0.removeFromSuperview() }
        buttons = actions.map { action in
            let button = PlateButton(action)
            button.addAction(UIAction { [weak button] _ in
                if let button { tap(button.action) }
            }, for: .touchUpInside)
            addSubview(button)
            return button
        }
    }

    private static func same(_ a: SwipeAction, _ b: SwipeAction) -> Bool {
        a.symbol == b.symbol && a.title == b.title && a.color == b.color
    }

    /// The plate's frame for this frame of the swipe; the buttons keep their
    /// places against its right end.
    ///
    /// 3.1.5: while it is narrower than the card is tall, the plate is a drop —
    /// a circle as tall as it is wide, centred on the card — so it flows out of
    /// the card's edge round, grows into a capsule and then into the full plate,
    /// and goes back the same way. A full-height sliver had no room to round
    /// its ends and looked like a sharp-edged strip.
    func place(_ frame: CGRect, radius: CGFloat) {
        let full = frame.height
        let height = min(full, max(0, frame.width))
        let shaped = CGRect(x: frame.minX, y: frame.minY + (full - height) / 2, width: frame.width, height: height)
        if self.frame != shaped { self.frame = shaped }
        // 3.1.9: the rounding goes from the capsule's (half the height) to the
        // card's over the rest of the opening. It used to drop to the card's at
        // once when the drop reached full height: the plate's ends took their
        // final corners while its left side was still growing, and the first
        // opening looked as if the whole plate had appeared at once.
        // (A plate of one action is narrower than the card is tall: it rounds
        // off over its second half.)
        let start = min(full, fullWidth / 2)
        let corner: CGFloat
        if frame.width <= start {
            corner = height / 2
        } else {
            let t = max(0, min(1, (frame.width - start) / max(1, fullWidth - start)))
            let eased = t * t * (3 - 2 * t)
            corner = min(height / 2, height / 2 + (radius - height / 2) * eased)
        }
        if layer.cornerRadius != corner { layer.cornerRadius = corner }
        // The first points come in as the drop grows, not as a hard-edged speck.
        let fade = max(0, min(1, frame.width / 14))
        if alpha != fade { alpha = fade }
        // Its colour comes in over two thirds of the way out, with the same easing
        // as the open head's card.
        let colour = SurfaceView.cardShown(frame.width, travel: fullWidth)
        if abs(colour - shownTint) > 0.004 {
            shownTint = colour
            backgroundColor = tint.withAlphaComponent(colour)
        }
        var right = frame.width - 4
        for button in buttons.reversed() {
            // The symbols keep their place on the card while the drop is shorter.
            let slot = CGRect(x: right - PlateButton.width, y: -(full - height) / 2, width: PlateButton.width, height: full)
            if button.frame != slot { button.frame = slot }
            // A symbol shows once most of its slot is uncovered (3.5 beta 4: back as
            // it was — beta 2 lit it earlier and a cut sliver of it showed).
            let shown = max(0, min(1, (slot.maxX - max(0, slot.minX)) / PlateButton.width))
            let alpha = max(0, min(1, (shown - 0.45) / 0.45))
            if button.alpha != alpha { button.alpha = alpha }
            right -= PlateButton.width
        }
        let hidden = frame.width < 1
        if isHidden != hidden { isHidden = hidden }
    }
}

/// A row whose card moves aside for its actions. A full swipe only opens them:
/// nothing is ever deleted by a swipe alone.
///
/// The motion is one spring stepped every frame (`SpringDriver`, 3.0.4), so a
/// row caught mid-way continues from where it is, with the finger's speed both
/// ways.
///
/// 3.1.2: the card moves left as a whole (it slides under the edge of the
/// subscription, or of the screen), and the actions come out of its right side
/// as one plate of its own colour, height and rounding (`ActionPlate`): a thin
/// capsule that widens with the finger and uncovers the symbols, which wait at
/// their places against its right end. 3.0.6 shrank the card and grew round
/// buttons beside it; 3.0.5 slid only the content; 3.0.4 slid the card with
/// circles behind it.
class SwipeRow: UIView, UIGestureRecognizerDelegate {
    /// What stays in place: it holds `host` (the card, or the head's tap area).
    /// The list scales it while a card is being uncovered.
    let front = UIView()
    /// The card or tap area in `front`: it moves aside as a whole.
    var host: UIView? {
        didSet {
            guard host !== oldValue else { return }
            clip.removeFromSuperview()
            host?.addSubview(clip)
            setNeedsLayout()
        }
    }
    /// The content of the card; subclasses put it here.
    let sliding = PassThroughView()
    /// Keeps the content inside the card (a plain rectangle).
    private let clip = PassThroughView()
    /// Height of the content; the view itself may be shorter while it is uncovered.
    var contentHeight: CGFloat = 63
    /// The card's distance from the row's sides: a row spans its whole
    /// subscription, so a card moving aside slides under the subscription's edge.
    var cardInset: CGFloat = 0 {
        didSet { if cardInset != oldValue { setNeedsLayout() } }
    }
    /// The card's rounding, which the plate takes.
    var tileRadius: CGFloat = 14
    /// The card's colour, which the plate takes.
    var tileColor: UIColor = .secondarySystemGroupedBackground {
        didSet { plate.tint = tileColor }
    }
    var onOpen: ((SwipeRow) -> Void)?
    /// Every placement (the swipe offset), on every frame: the list moves the
    /// surface with a card that has none of its own.
    var onSlide: ((CGFloat) -> Void)?
    /// The actions' plate, beside the card; touches outside it reach the row.
    private let rail = PassThroughView()
    private let plate = ActionPlate()
    /// The actions are fully out (a light tap of the haptics when they get there).
    private var fullyOut = false
    private(set) var offset: CGFloat = 0
    private var panStart: CGFloat = 0
    private lazy var spring = SpringDriver { [weak self] value in
        guard let self else { return }
        self.offset = value
        self.placeFront()
    }
    private static let gap: CGFloat = 6

    /// The buttons are built when a swipe first needs them, not with the row: rows
    /// appear by the dozen as a subscription opens.
    var actions: [SwipeAction] = [] {
        didSet {
            railStale = true
            if !plate.buttons.isEmpty || offset != 0 {
                let built = plate.buttons
                rebuildRail()
                // New buttons (other actions) are drawn once before they are swiped.
                if offset == 0, !plate.buttons.isEmpty, plate.buttons.map(ObjectIdentifier.init) != built.map(ObjectIdentifier.init) {
                    prepared = false
                    prepareSoon()
                }
            } else if !actions.isEmpty {
                prepareSoon()
            }
        }
    }

    /// 3.1.6: the plate is built just after the row appears, between frames of
    /// nothing, so the first swipe only moves views that already exist.
    private var preparing = false
    /// The current buttons have been drawn once.
    private var prepared = false
    private func prepareSoon() {
        guard !preparing else { return }
        preparing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.preparing = false
            guard self.window != nil, !self.actions.isEmpty, self.offset == 0, !self.panning else { return }
            if self.railStale { self.rebuildRail() }
            guard !self.prepared else { return }
            self.prepared = true
            self.warmPlate()
        }
    }

    /// 3.1.7: the plate is really drawn once before the first swipe, at full width
    /// and all but transparent, for one frame. 3.1.6 laid it out and hid it again
    /// in the same transaction, so nothing reached the screen: the first swipe
    /// still made Core Animation render the plate, its rounded clip and the
    /// symbols for the first time, and the drop jumped. The second swipe was smooth.
    private func warmPlate() {
        plate.place(CGRect(x: rail.bounds.width - railWidth, y: 0, width: railWidth, height: contentHeight), radius: tileRadius)
        plate.alpha = 0.012
        plate.isUserInteractionEnabled = false
        plate.layoutIfNeeded()
        // A few frames later, unless a swipe has taken the plate meanwhile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.plate.isUserInteractionEnabled = true
            guard !self.panning, !self.spring.isRunning else { return }
            self.placeFront()
        }
    }
    private var railStale = false

    /// How far the card moves to show every action: the plate and the gap before it.
    var railWidth: CGFloat {
        plate.buttons.isEmpty ? 0 : plate.fullWidth + Self.gap
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(front)
        // Above the card: it lets every touch outside the plate through.
        addSubview(rail)
        plate.tint = tileColor
        plate.isHidden = true
        rail.addSubview(plate)
        clip.clipsToBounds = true
        clip.addSubview(sliding)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func rebuildRail() {
        railStale = false
        plate.set(actions) { [weak self] action in
            Haptics.tap()
            self?.close(animated: true)
            action.handler()
        }
        setNeedsLayout()
    }

    /// The card's place in the row when it is at rest.
    private var cardRect: CGRect {
        CGRect(x: cardInset, y: 0, width: max(0, bounds.width - 2 * cardInset), height: contentHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = cardRect
        if rail.frame != rect { rail.frame = rect }
        // bounds and center, never frame: the list scales the front of a card being
        // uncovered, and a frame set under a transform moves it.
        let size = CGRect(origin: .zero, size: rect.size)
        if front.bounds != size { front.bounds = size }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if front.center != center { front.center = center }
        if let host {
            if host.bounds != size { host.bounds = size }
            let middle = CGPoint(x: size.midX, y: size.midY)
            if host.center != middle { host.center = middle }
        }
        if clip.frame != size { clip.frame = size }
        if sliding.frame != size { sliding.frame = size }
        placeFront()
    }

    /// The card at the offset and the plate in the room it leaves. Called on every
    /// frame of a swipe: a transform and the plate's frame change, nothing else.
    private func placeFront() {
        let move = offset == 0 ? CGAffineTransform.identity : CGAffineTransform(translationX: offset, y: 0)
        if let host, host.transform != move { host.transform = move }
        onSlide?(offset)
        guard !plate.buttons.isEmpty else { return }
        let pulled = max(0, -offset)
        let full = railWidth
        // The gap opens with the swipe, so the plate starts as a sliver right away.
        let gap = Self.gap * min(1, pulled / max(1, full))
        let width = max(0, pulled - gap)
        let height = contentHeight
        plate.place(CGRect(x: rail.bounds.width - width, y: 0, width: width, height: height), radius: tileRadius)
        let out = pulled > full - 2
        if out != fullyOut {
            fullyOut = out
            if out, panning { Haptics.soft(0.45) }
        }
    }

    var isOpen: Bool { offset < -1 || (spring.isRunning && spring.target < -1) }

    func close(animated: Bool) { set(offset: 0, animated: animated, velocity: 0) }

    private var panning = false

    private func set(offset target: CGFloat, animated: Bool, velocity: CGFloat) {
        pendingOffset = nil
        guard animated, window != nil else {
            spring.stop()
            offset = target
            placeFront()
            return
        }
        // Opening lands with a hint of give; closing glides home without it.
        spring.run(from: offset, to: target, velocity: velocity, feel: target < 0 ? .snappy : .smooth)
    }

    /// The finger's latest place, applied by the pacer on the next frame.
    private var pendingOffset: CGFloat?
    private lazy var pacer = FramePacer { [weak self] in
        guard let self else { return false }
        if let pending = self.pendingOffset {
            self.pendingOffset = nil
            self.offset = pending
            self.placeFront()
            return true
        }
        return self.panning
    }

    /// 3.1.9: the display is brought to 120 Hz as the finger lands on a row with
    /// actions, before the swipe is even recognised; it falls back on its own
    /// when the touch turns out to be a tap or a scroll.
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive _: UITouch) -> Bool {
        if gesture is UIPanGestureRecognizer, !actions.isEmpty, !UIAccessibility.isReduceMotionEnabled { pacer.start() }
        return true
    }

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer, !actions.isEmpty else { return false }
        // A swipe from the very edge of the screen belongs to the sheet (it closes
        // it), while that gesture is on.
        if MinimalServersViewController.edgeCloseEnabled, let window {
            let edge = MinimalServersViewController.edgeWidth
            let start = pan.location(in: window).x - pan.translation(in: window).x
            if start < edge || start > window.bounds.width - edge { return false }
        }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y) * 1.2 && (velocity.x < 0 || isOpen)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let width = railWidth
        switch pan.state {
        case .began:
            if railStale { rebuildRail() }
            Haptics.prepare()
            // Caught mid-way: the finger takes the row where it shows.
            spring.stop()
            panStart = offset
            // 3.1.7: the pan is recognised only after the finger has gone some way
            // (more on the first touch of a list); that distance used to land in one
            // frame and the card jumped. The card now starts from where it is.
            pan.setTranslation(.zero, in: self)
            panning = true
            onOpen?(self)
        case .changed:
            var next = panStart + pan.translation(in: self).x
            // Past the actions and past the resting place the row resists, softly.
            if next < -width { next = -width - rubber(-width - next, limit: 90) }
            if next > 0 { next = rubber(next, limit: 30) }
            // 3.1.9: placed on the display's next frame, at 120 Hz (`FramePacer`).
            pendingOffset = next
            pacer.start()
        case .ended, .cancelled:
            panning = false
            if let pending = pendingOffset {
                pendingOffset = nil
                offset = pending
                placeFront()
            }
            pacer.stop()
            let velocity = pan.velocity(in: self).x
            // Where a free flick would come to rest decides, as the system's lists do.
            let projected = offset + velocity * 0.1
            let open = pan.state == .ended && (velocity < -500 || (velocity < 500 && projected < -width / 2))
            set(offset: open ? -width : 0, animated: true, velocity: velocity)
        default: break
        }
    }

    /// iOS's rubber band: the further past, the less it follows, never beyond `limit`.
    private func rubber(_ distance: CGFloat, limit: CGFloat) -> CGFloat {
        guard distance > 0 else { return 0 }
        return limit * (1 - 1 / (distance * 0.55 / limit + 1))
    }
}

// MARK: - Rows

/// Holds other views without taking touches itself: those between its
/// subviews reach the view behind (the row's card).
final class PassThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

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
    /// The plate takes the subscription's rounding then (3.1.2), and the row lets
    /// the card's content move out past its sides with the surface.
    var plain = false {
        didSet {
            card.backgroundColor = plain ? .clear : .secondarySystemGroupedBackground
            tileRadius = plain ? 24 : 14
            clipsToBounds = !plain
        }
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
        host = card
        globe.tintColor = .label
        check.tintColor = Theme.accent
        check.setContentHuggingPriority(.required, for: .horizontal)
        // 3.1.12: a long name gives way (…) and the checkmark stays whole beside it.
        check.setContentCompressionResistancePriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        let latency = UIStackView(.horizontal, spacing: 0, alignment: .center, [ping, spinner])
        latency.isUserInteractionEnabled = false
        pingButton.addSubview(latency)
        // 3.5.19 (the owner: a tap meant for the ping chose the server): the button
        // reaches the card's right edge and is wider; the figure stays where it was.
        latency.pin(to: pingButton, insets: UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 16))
        pingWidth = pingButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96)
        pingWidth?.isActive = true
        pingButton.setContentHuggingPriority(.required, for: .horizontal)
        pingButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        mark.contentMode = .center
        mark.isHidden = true
        mark.setContentHuggingPriority(.required, for: .horizontal)
        let row = PassThroughStackView(.horizontal, spacing: 12, alignment: .center, [mark, leading, text, pingButton])
        text.isUserInteractionEnabled = false
        leading.isUserInteractionEnabled = false
        sliding.addSubview(row)
        row.pin(to: sliding, insets: UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 0))
        NSLayoutConstraint.activate([pingButton.heightAnchor.constraint(equalTo: row.heightAnchor)])
    }

    func bind(_ subscription: Int64, _ node: String) { key = (subscription, node) }

    private var pingWidth: NSLayoutConstraint?

    /// nil: not selecting; otherwise whether this row is selected. 3.5.21: while
    /// selecting the ping column gives up its extra tap room to the circle, so
    /// the name keeps its width (it shrank at the end of the way in).
    func setMark(_ selected: Bool?) {
        SelectionMark.apply(selected, to: mark)
        pingWidth?.constant = selected != nil ? 60 : 96
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
    /// The open head's card while it is swiped (3.1.2): it moves with the head.
    private let headCard = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentHeight = ServerListView.headerHeight
        tap.pressScale = 1
        front.addSubview(tap)
        host = tap
        headCard.isUserInteractionEnabled = false
        headCard.backgroundColor = SurfaceView.card
        headCard.layer.cornerRadius = 22
        headCard.layer.cornerCurve = .continuous
        headCard.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        headCard.alpha = 0
        tap.insertSubview(headCard, at: 0)
        // While open, the head keeps what moves inside the container's rounded top.
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
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
        row.setCustomSpacing(6, after: mark)
        headRow = row
        row.isUserInteractionEnabled = false
        sliding.addSubview(row)
        row.pin(to: sliding, insets: UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20))
        NSLayoutConstraint.activate([count.heightAnchor.constraint(equalToConstant: 24), count.widthAnchor.constraint(greaterThanOrEqualToConstant: 34)])
        // With the count it belongs to: both move with the card.
        sliding.insertSubview(countPill, at: 0)
        tileRadius = 24
        countPill.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            countPill.leadingAnchor.constraint(equalTo: count.leadingAnchor), countPill.trailingAnchor.constraint(equalTo: count.trailingAnchor),
            countPill.topAnchor.constraint(equalTo: count.topAnchor), countPill.bottomAnchor.constraint(equalTo: count.bottomAnchor),
        ])
    }

    private weak var headRow: UIStackView?

    /// 3.5.21 (the owner: the name shrank at the end of the way into a selection):
    /// while selecting the chevron gives its room to the circle — a tap selects
    /// there, it does not open — so the name keeps its width.
    func setMark(_ selected: Bool?) {
        SelectionMark.apply(selected, to: mark)
        chevron.isHidden = selected != nil
        headRow?.setCustomSpacing(selected != nil ? 0 : 12, after: count)
    }

    /// `alpha`: the open head's own card (0 hides it); `clipped`: the head keeps
    /// what moves inside the container (open), or lets it out with the card (closed).
    func showCard(_ alpha: CGFloat, clipped: Bool) {
        if headCard.frame != tap.bounds { headCard.frame = tap.bounds }
        if headCard.alpha != alpha { headCard.alpha = alpha }
        if clipsToBounds != clipped { clipsToBounds = clipped }
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

/// The provider's line under an open subscription's head, one line from the
/// left: «⇅ 84.1 GB из ∞ | 📅 Активна до 28.11.2026 (16 дней)». It slides with
/// the head when the head is swiped (`slide`), clipped at the card's edge.
final class SubscriptionInfoStrip: UIView {
    private let label = UILabel()
    private var shown: (String?, String?) = (nil, nil)

    /// The open head's swipe offset (≤ 0): the line moves with the head's card
    /// (3.1.2), so the plate beside the head never stands over it.
    var slide: CGFloat = 0 {
        didSet { if slide != oldValue { placeLabel() } }
    }

    /// Vertical offset while the subscription opens or closes (≤ 0: tucked under the title).
    var lift: CGFloat = 0 {
        didSet { if lift != oldValue { placeLabel() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func show(traffic text: String?, expiry date: String?) {
        guard shown.0 != text || shown.1 != date else { return }
        shown = (text, date)
        let font = Theme.font(.footnote)
        let color = UIColor.secondaryLabel
        let line = NSMutableAttributedString()
        func part(_ symbol: String, _ value: String) {
            let configuration = UIImage.SymbolConfiguration(font: Theme.font(.caption1, .medium))
            if let image = UIImage(systemName: symbol, withConfiguration: configuration)?.withTintColor(color, renderingMode: .alwaysOriginal) {
                let attachment = NSTextAttachment(image: image)
                line.append(NSAttributedString(attachment: attachment))
                line.append(NSAttributedString(string: " "))
            }
            line.append(NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color]))
        }
        if let text { part("arrow.up.arrow.down", text) }
        if text != nil, date != nil {
            line.append(NSAttributedString(string: "  |  ", attributes: [.font: font, .foregroundColor: UIColor.tertiaryLabel]))
        }
        if let date { part("calendar", date) }
        label.attributedText = line
        accessibilityLabel = [text, date].compactMap { $0 }.joined(separator: ", ")
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeLabel()
    }

    /// Only the label moves (a transform), so following the spring and the swipe
    /// costs no text layout per frame.
    private func placeLabel() {
        let inset: CGFloat = 20
        let frame = CGRect(x: inset, y: 0, width: max(0, bounds.width - 2 * inset), height: ServerListView.infoHeight)
        if label.bounds.size != frame.size || label.center != CGPoint(x: frame.midX, y: frame.midY) {
            label.bounds = CGRect(origin: .zero, size: frame.size)
            label.center = CGPoint(x: frame.midX, y: frame.midY)
        }
        let transform = CGAffineTransform(translationX: slide, y: lift)
        if label.transform != transform { label.transform = transform }
    }
}

/// The surface of one subscription: the card when closed, the container when open.
/// It clips what it holds, so its moving bottom edge uncovers the server cards.
final class SurfaceView: UIView {
    let header = SubscriptionHeaderView()
    let info = SubscriptionInfoStrip()
    let filters = FilterBar()
    private let swipeClip = UIView()
    private let swipeCard = UIView()

    /// 3.5.3 (the owner): what lights when an open subscription is held or
    /// swiped — the title and the provider's line, down to the filters.
    var headLightHeight: CGFloat {
        if !filters.isHidden, filters.frame.height > 1 { return max(ServerListView.headerHeight, filters.frame.minY) }
        if !info.isHidden { return max(ServerListView.headerHeight, info.frame.maxY) }
        return ServerListView.headerHeight
    }
    static let card = UIColor.secondarySystemGroupedBackground
    static let container = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.067, green: 0.067, blue: 0.075, alpha: 1) : UIColor(red: 0.914, green: 0.914, blue: 0.933, alpha: 1)
    }

    private var shownProgress: CGFloat = -1
    private var shownStandalone: Bool?
    /// 3.5.11 (the owner's video): the subscription is folding shut. The fold's
    /// spring runs on for about a second with the body all but gone, and a swipe
    /// then took the open head's way: the surface stood whole behind the actions,
    /// with no gap between them and the card. Folding, it gives way as a closed card.
    private var shownClosing = false
    /// The surface's colour and shape, apart from the view: a closed subscription
    /// or a lone server is a card that moves aside for its actions (3.1.2) while
    /// what it holds stays where the list put it.
    private let plate = UIView()
    private var plateColor = SurfaceView.card
    /// How far the card has moved aside (≥ 0).
    private(set) var pull: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        // No clipping: a rounded mask over moving content renders offscreen every
        // frame. The server rows clip themselves at the container's edge instead.
        layer.cornerCurve = .continuous
        plate.isUserInteractionEnabled = false
        plate.layer.cornerCurve = .continuous
        addSubview(plate)
        // 3.5.3: an open head swiped lights as a card from its title to the
        // provider's line (not the filters), clipped at the surface's edge.
        swipeClip.isUserInteractionEnabled = false
        swipeClip.clipsToBounds = true
        swipeClip.isHidden = true
        swipeCard.backgroundColor = Self.card
        swipeCard.layer.cornerRadius = 22
        swipeCard.layer.cornerCurve = .continuous
        swipeClip.addSubview(swipeCard)
        addSubview(swipeClip)
        addSubview(filters)
        addSubview(header)
        // Over the head (it takes no touches): the open head's own card, while it
        // is swiped, lies under the provider's line, not over it.
        addSubview(info)
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
    func show(progress: CGFloat, standalone: Bool, closing: Bool = false) {
        guard abs(progress - shownProgress) > 0.001 || standalone != shownStandalone || closing != shownClosing else { return }
        shownProgress = progress
        shownStandalone = standalone
        shownClosing = closing
        header.isHidden = standalone
        plateColor = standalone ? Self.card : Self.blend(Self.card, Self.container, progress, traits: traitCollection)
        plate.backgroundColor = plateColor
        // 3.5.3 (the owner's video): the radius follows the fold, 24 closed to 22
        // open. It used to change once, at the end of the spring: the closed card
        // seemed to shrink a little in its last frame as its corners rounded at once.
        let radius: CGFloat = standalone ? 24 : ((24 - 2 * max(0, min(1, progress))) * 4).rounded() / 4
        if layer.cornerRadius != radius { layer.cornerRadius = radius; plate.layer.cornerRadius = radius }
        if !standalone { header.show(progress: progress) }
        placePlates()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placePlates()
    }

    /// Sets how far the card gives way; every frame of a swipe.
    func setPull(_ value: CGFloat) {
        let value = max(0, value)
        guard value != pull else { return }
        pull = value
        placePlates()
    }

    private func placePlates() {
        let open = shownStandalone == false && shownProgress > 0.001 && !shownClosing
        // Closed (or a lone server): the whole card moves aside, out past the
        // surface's side (the list clips it at the screen's edge).
        let shift = open ? 0 : pull
        let plateFrame = CGRect(x: -shift, y: 0, width: bounds.width, height: bounds.height)
        if plate.frame != plateFrame { plate.frame = plateFrame }
        // Open: the head becomes a card of its own as it moves, inside the
        // container, and the provider's line goes with it.
        // Clipped only while it moves: a rounded clip at rest would cost every frame
        // of a scroll for nothing.
        // 3.5: the head's card comes in over most of the swipe, not in its first
        // 24 points: at an ordinary speed that was two frames, and the colour seemed to jump.
        let shown = open ? Self.cardShown(pull, travel: header.railWidth) : 0
        // The head's own card covers the title only; the taller one below it
        // takes the provider's line too (3.5.3).
        header.showCard(0, clipped: open && pull > 0.5)
        info.slide = open ? -pull : 0
        if shown > 0.001 {
            let height = headLightHeight
            let clip = CGRect(x: 0, y: 0, width: bounds.width, height: height)
            if swipeClip.frame != clip { swipeClip.frame = clip }
            swipeCard.frame = CGRect(x: -pull, y: 0, width: bounds.width, height: height)
            swipeClip.alpha = shown
            swipeClip.isHidden = false
        } else if !swipeClip.isHidden {
            swipeClip.isHidden = true
        }
    }

    /// How much of the open head's card shows at `pull`: eased in over the first
    /// two thirds of the way to the actions.
    static func cardShown(_ pull: CGFloat, travel: CGFloat) -> CGFloat {
        let t = max(0, min(1, pull / max(48, travel * 0.66)))
        return t * t * (3 - 2 * t)
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
    /// under the title (the head is 66 pt with its 17 pt title centred: about 5 pt between them).
    static let infoRise: CGFloat = 21
    /// Over how much of the opening body the provider's line fades in (about the
    /// first server card, so the two come and go together).
    static let infoFade: CGFloat = 54

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

    /// Room above the first subscription (the search field lives there).
    var leading: CGFloat = 0 {
        didSet { if leading != oldValue { layoutList() } }
    }

    var configureHeader: ((SubscriptionHeaderView, Int64) -> Void)?
    var configureRow: ((ServerRowView, Int64, String) -> Void)?
    var actionsForHeader: ((Int64) -> [SwipeAction])?
    var actionsForRow: ((Int64, String) -> [SwipeAction])?
    var onToggle: ((Int64) -> Void)?
    /// A filter tag tapped (nil: «Все»).
    var onFilter: ((Int64, String?) -> Void)?
    var onSelect: ((Int64, String) -> Void)?
    var onPing: ((Int64, String) -> Void)?
    /// What a long press lifts above the dim under the menu: a view, the pressed
    /// part (the menu is placed by it) and the part kept bright (`.null`: nothing
    /// dims). A subscription keeps its whole card bright (3.5.14).
    typealias HoldSource = (view: UIView, rect: CGRect, lift: CGRect)
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

    /// The same subscriptions and servers in another order (3.3 beta 3: the
    /// connected server rises and goes back, a connected subscription rises).
    static func isReorder(_ old: [Section], _ new: [Section]) -> Bool {
        guard old.count == new.count, old.map(\.id) != new.map(\.id) || zip(old, new).contains(where: { $0.nodes != $1.nodes }) else { return false }
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return new.allSatisfy { section in
            guard let previous = before[section.id] else { return false }
            return previous.standalone == section.standalone && previous.nodes.count == section.nodes.count && Set(previous.nodes) == Set(section.nodes)
        }
    }

    /// New content; open subscriptions stay open. 3.3 beta 3: when only the order
    /// changes, subscriptions and servers glide from where they were (a short
    /// spring); anything else is shown at once.
    func set(_ next: [Section], open: Set<Int64>) {
        // 3.3 beta 4: the same content again (the list is told twice about one
        // choice: the library and the order) keeps its rows and any glide under
        // way. Recycling them mid-glide sent cards under other servers' names
        // and left gaps and overlaps on the device.
        let unchanged = next == sections && next.allSatisfy { section in
            springs[section.id]?.target == (!section.standalone && open.contains(section.id) ? 1 : 0)
        }
        let reorder = !unchanged && window != nil && link == nil && !UIAccessibility.isReduceMotionEnabled && Self.isReorder(sections, next)
        // Where things are on screen now: a glide that is still running starts
        // the next one from its current point, not from where it was going.
        func shown(_ view: UIView) -> CGFloat { view.layer.presentation()?.frame.minY ?? view.frame.minY }
        let oldSurfaceY = surfaces.mapValues { shown($0) }
        var oldRowY: [String: CGFloat] = [:]
        if reorder {
            for section in sections where !section.standalone {
                let top = rowsTop(section) + 3
                for (index, node) in section.nodes.enumerated() { oldRowY[Self.key(section.id, node)] = top + CGFloat(index) * Self.rowPitch }
            }
            for (key, row) in rows { oldRowY[key] = shown(row) }
        }
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
                // The head's card gives way to its buttons: the surface when the
                // subscription is closed, the head's own card when it is open.
                surface.header.onSlide = { [weak surface] offset in surface?.setPull(-offset) }
                insertSubview(surface, at: 0)
                surfaces[section.id] = surface
            }
        }
        if !reorder, !unchanged {
            for (key, row) in rows { recycle(row); rows[key] = nil }
            for surface in surfaces.values { surface.layer.removeAllAnimations() }
        }
        // Rows are built ahead, so the first frames of a disclosure only place them.
        while pool.count < 16 { pool.append(makeRow()) }
        reconfigureHeaders()
        if unchanged {
            reconfigureRows()
            for row in rows.values { row.actions = actionsForRow?(row.key.subscription, row.key.node) ?? [] }
            return
        }
        layoutList()
        guard reorder else { return }
        // Everything is in its new place: put it back where it was and let it glide.
        reconfigureRows()
        let surfaceTargets = surfaces.mapValues(\.frame)
        let rowTargets = rows.mapValues(\.frame)
        for (id, surface) in surfaces {
            surface.layer.removeAllAnimations()
            if let y = oldSurfaceY[id], y != surface.frame.minY { surface.frame.origin.y = y }
        }
        for (key, row) in rows {
            row.layer.removeAllAnimations()
            if let y = oldRowY[key], y != row.frame.minY { row.frame.origin.y = y }
        }
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                       options: [.allowUserInteraction]) {
            for (id, frame) in surfaceTargets { self.surfaces[id]?.frame = frame }
            for (key, frame) in rowTargets { self.rows[key]?.frame = frame }
        }
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

    /// The subscription's head in its surface: the title, and when open the
    /// provider's line and the filters under it.
    private func headRect(_ id: Int64) -> CGRect {
        guard let surface = surfaces[id] else { return .zero }
        var height = Self.headerHeight
        if isOpen(id), let section = sections.first(where: { $0.id == id }), !section.standalone {
            height = min(surface.bounds.height, rowsTop(section))
        }
        return CGRect(x: 0, y: 0, width: surface.bounds.width, height: max(Self.headerHeight, height))
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
        var y: CGFloat = leading
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
                // 3.0.4: the line takes only 1 pt of the body (it rises into the
                // head), so it used to stay fully drawn until that last point and
                // vanish after the servers had gone. Now it follows the first
                // server card: it fades and settles in over the same distance the
                // card is uncovered in, and leaves with it when closing.
                let reveal = max(0, min(1, shown / Self.infoFade))
                let eased = reveal * reveal * (3 - 2 * reveal)
                if surface.info.alpha != eased { surface.info.alpha = eased }
                surface.info.lift = -4 * (1 - eased)
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
            surface.show(progress: min(1, progress), standalone: section.standalone, closing: !isOpen(section.id))
            // 3.5.3 (the owner's video): while the card folds, the filters reach its
            // bottom and the last, half-shown tag stuck out past its round corner;
            // there the bar takes the card's bottom corners.
            if hasFilters {
                let atBottom = surface.filters.frame.maxY >= surface.bounds.height - 0.5
                let corner = atBottom ? surface.layer.cornerRadius : 0
                if surface.filters.layer.cornerRadius != corner {
                    surface.filters.layer.cornerRadius = corner
                    surface.filters.layer.cornerCurve = .continuous
                    surface.filters.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                }
            }
            y += height + Self.gap
        }
        var height = max(0, y - Self.gap) + 24
        // With room above (the search), a short list is still long enough to tuck
        // that room under the bar.
        if leading > 0 { height = max(height, bounds.height - adjustedContentInset.top - adjustedContentInset.bottom + leading) }
        let size = CGSize(width: bounds.width, height: height)
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
                row.cardInset = 0
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
                // 3.1.2: the row spans the container and the card sits inset in it, so
                // a card moving aside slides under the container's edge.
                row.cardInset = Self.rowInset
                let rowFrame = CGRect(x: 0, y: top, width: width, height: max(0, min(Self.rowHeight, frame.height - top)))
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
        // A lone server has no card of its own: the surface gives way instead.
        if plain {
            row.onSlide = { [weak surface] offset in surface?.setPull(-offset) }
        } else {
            row.onSlide = nil
        }
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
        // 3.3 beta 4: a row taken mid-glide must not carry the glide to its next server.
        row.layer.removeAllAnimations()
        row.removeFromSuperview()
        row.close(animated: false)
        row.onSlide = nil
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
            let head = section.standalone ? CGRect(x: 0, y: 0, width: surface.bounds.width, height: Self.headerHeight) : headRect(section.id)
            if section.standalone, let node = section.nodes.first, let row = rows[Self.key(section.id, node)] {
                row.setHeld(true)
                onHold?(section.id, node, point, (view: surface as UIView, rect: head, lift: head)) { [weak row] in row?.setHeld(false) }
            } else if local.y < head.maxY {
                // 3.5.14 (the owner): as in 3.5 beta 1–4 — the rest of the sheet
                // dims and the subscription stays bright above it, the whole card,
                // open with its servers or closed (3.5–3.5.13 darkened the card itself).
                // Only the part on screen, below the sheet's bar, is lifted.
                let visible = convert(bounds.inset(by: UIEdgeInsets(top: max(0, contentInset.top - 6), left: 0, bottom: 0, right: 0)), to: surface)
                var lift = surface.bounds.intersection(visible)
                if lift.isNull || lift.height < 1 { lift = head }
                // 3.5.2 (the owner: a little higher): the menu hangs under the title
                // and the provider's line, over the filters.
                var place = head
                if isOpen(section.id), !section.tags.isEmpty, surface.filters.frame.height > 1 {
                    place.size.height = max(Self.headerHeight, surface.filters.frame.minY)
                }
                onHold?(section.id, nil, point, (view: surface as UIView, rect: place, lift: lift)) {}
            } else if let row = rows.values.first(where: { $0.superview === surface && $0.frame.contains(local) }) {
                row.setHeld(true)
                onHold?(section.id, row.key.node, point, (view: row.card as UIView, rect: row.card.bounds, lift: row.card.bounds)) { [weak row] in row?.setHeld(false) }
            }
            return
        }
    }
}
