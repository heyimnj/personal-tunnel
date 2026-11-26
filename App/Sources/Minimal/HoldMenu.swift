import UIKit

struct HoldMenuItem {
    var title: String
    var symbol: String
    var destructive = false
    var action: () -> Void
}

/// Sizes of the hold menu: a 268 pt card with 26 pt corners. It has no arrow:
/// like the system's context menus it stands a little apart from the lifted row,
/// under it (or over it when there is no room), and grows out of the point of
/// its edge nearest to the finger.
enum HoldMenuMetrics {
    static let width: CGFloat = 268
    static let radius: CGFloat = 26
    static let margin: CGFloat = 12
    static let rowHeight: CGFloat = 46
    static let padding: CGFloat = 6
    /// Space between the lifted row and the menu.
    static let gap: CGFloat = 8

    struct Placement {
        /// The card, in the host's coordinates.
        var frame: CGRect
        /// The menu hangs below the row (it grows downwards).
        var below: Bool
        /// Where it grows from, on its edge facing the row: x inside the card.
        var originX: CGFloat
    }

    /// A press in the left third gets a menu running right from the finger, the
    /// right third the mirror image, the middle a centred menu. Below the row,
    /// above it without room, always inside the safe area.
    /// `row`: the pressed row's frame (the finger's point when there is none).
    static func placement(content: CGSize, touch: CGPoint, row: CGRect, bounds: CGRect, safe: UIEdgeInsets) -> Placement {
        let size = content
        let minX = bounds.minX + max(margin, safe.left + 8)
        let maxX = bounds.maxX - max(margin, safe.right + 8) - size.width
        let minY = bounds.minY + safe.top + 8
        let maxY = bounds.maxY - safe.bottom - 8 - size.height
        let edge = radius + 10
        let third = bounds.width / 3
        let preferredX: CGFloat
        if touch.x < bounds.minX + third { preferredX = touch.x - edge }
        else if touch.x > bounds.maxX - third { preferredX = touch.x - size.width + edge }
        else { preferredX = touch.x - size.width / 2 }
        let x = min(max(minX, preferredX), max(minX, maxX))
        let below = row.maxY + gap, above = row.minY - gap - size.height
        let down: Bool, y: CGFloat
        if below <= maxY { down = true; y = below }
        else if above >= minY { down = false; y = above }
        else { down = true; y = min(max(minY, below), max(minY, maxY)) }
        let originX = min(max(radius, touch.x - x), size.width - radius)
        return Placement(frame: CGRect(x: x, y: y, width: size.width, height: size.height), below: down, originX: originX)
    }
}

/// One action: icon in a fixed column, the title, a rounded press shade that comes
/// in quickly and leaves slowly.
private final class HoldMenuRow: UIControl {
    private let shade = UIView()

    init(_ item: HoldMenuItem) {
        super.init(frame: .zero)
        let color: UIColor = item.destructive ? .systemRed : .label
        shade.backgroundColor = UIColor.label.withAlphaComponent(0.08)
        shade.alpha = 0
        shade.layer.cornerRadius = 16
        shade.layer.cornerCurve = .continuous
        shade.isUserInteractionEnabled = false
        addSubview(shade)
        shade.pin(to: self)
        let icon = UIImageView(image: UIImage(systemName: item.symbol, withConfiguration: UIImage.SymbolConfiguration(textStyle: .body)))
        icon.tintColor = color
        icon.contentMode = .center
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let title = UILabel(item.title, font: Theme.font(.body), color: color)
        title.lineBreakMode = .byTruncatingTail
        let row = UIStackView(.horizontal, spacing: 12, alignment: .center, [icon, title, UIView()])
        row.isUserInteractionEnabled = false
        addSubview(row)
        row.pin(to: self, insets: UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14))
        heightAnchor.constraint(equalToConstant: HoldMenuMetrics.rowHeight).isActive = true
        accessibilityLabel = item.title
        accessibilityTraits = .button
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            UIView.animate(withDuration: isHighlighted ? 0.08 : 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
                self.shade.alpha = self.isHighlighted ? 1 : 0
            }
        }
    }
}

/// The menu a long press opens, as in 1.5.0: a card that pours out of the pressed
/// row (down first, then sideways, the items settling a beat later) and drains
/// back into it. A touch outside closes it.
///
/// 3.6.15 (the owner: a torn shift as it opens, most of all on the right): the pour
/// was a scale with a springy overshoot — the items were squeezed sideways and the
/// right edge ran past its place and back. Now the card's outline grows (the
/// surface, its shadow and a mask over the items), the items keep their size, and
/// the spring stops without overshoot.
///
/// The card is one even surface in the cards' own tone (glass took its colour from
/// whatever lay under each part of it, so the menu looked patchy and sat on a layer
/// of its own). The rest of the sheet dims, and the pressed row is lifted above the
/// dim together with the menu: the two read as one piece.
final class HoldMenuView: UIView {
    /// Horizontal half of the pour (scale X), anchored at the point it grows from.
    private let card = UIView()
    /// Vertical half of the pour (scale Y); carries the shadow and the surface.
    private let stretch = UIView()
    private let items = UIStackView(.vertical, spacing: 0, alignment: .fill, [])
    private let surface = CAShapeLayer()
    private let backdrop = UIControl()
    /// A picture of the pressed row, above the dim.
    private var lifted: UIView?
    private var animators: [UIViewPropertyAnimator] = []
    private var direction: CGFloat = 1
    private var leaving = false
    private var onDismiss: (() -> Void)?
    /// The sheet dims under the menu.
    private var dims = true
    /// Clips the items to the outline while it grows.
    private let clip = CAShapeLayer()
    /// The card's whole outline, and the small one it pours out of.
    private var fullOutline: CGPath?
    private var seedOutline: CGPath?
    /// Pictures of views that stay bright above the dim (the servers sheet's bottom
    /// bar, 3.6.15), with the lifted row.
    private var kept: [UIView] = []

    /// The menu's surface: the cards' colour, a step lighter in dark mode so it
    /// stands off the cards it covers.
    static let fill = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.173, green: 0.173, blue: 0.180, alpha: 1) : .white
    }

    /// `source`: the pressed row, the part the menu is placed by, and the part
    /// lifted above the dim (`.null`: nothing dims).
    /// `keep`: views shown bright above the dim as they are (3.6.15, the owner: the
    /// servers sheet's bottom bar stayed under a held server but vanished under a
    /// held subscription, whose lifted picture covered it — now it stays in both).
    static func show(in host: UIView, at point: CGPoint, title: String, items: [HoldMenuItem], source: (view: UIView, rect: CGRect, lift: CGRect)? = nil,
                     keep: [UIView] = [], onDismiss: (() -> Void)? = nil) {
        let menu = HoldMenuView(frame: host.bounds)
        menu.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        menu.onDismiss = onDismiss
        menu.accessibilityLabel = title
        // 3.5: in the host first, so the menu takes the app's theme: built outside
        // the window it resolved its colours with the system's (a dark menu over
        // the light theme on a phone set to dark).
        host.addSubview(menu)
        menu.overrideUserInterfaceStyle = host.traitCollection.userInterfaceStyle
        // Nothing to lift (.null): nothing dims either.
        menu.dims = !(source?.lift.isNull ?? false)
        menu.build(items)
        var row = CGRect(origin: point, size: .zero)
        if let source {
            if !source.lift.isNull { menu.lift(source.view, source.lift) }
            row = source.view.convert(source.rect, to: menu)
        }
        if menu.dims { menu.keep(keep) }
        menu.place(at: point, row: row)
        menu.animateIn()
    }

    private func build(_ list: [HoldMenuItem]) {
        backdrop.addTarget(self, action: #selector(backdropTouched), for: .touchDown)
        // Clear when it does not dim: it still takes the touch that closes the menu.
        backdrop.backgroundColor = dims ? UIColor.black.withAlphaComponent(traitCollection.userInterfaceStyle == .dark ? 0.55 : 0.16) : UIColor.black.withAlphaComponent(0.001)
        backdrop.alpha = 0
        addSubview(backdrop)
        backdrop.pin(to: self)

        let dark = traitCollection.userInterfaceStyle == .dark
        surface.fillColor = Self.fill.resolvedColor(with: traitCollection).cgColor
        surface.strokeColor = UIColor.label.withAlphaComponent(dark ? 0.08 : 0.04).resolvedColor(with: traitCollection).cgColor
        surface.lineWidth = 0.5
        stretch.layer.addSublayer(surface)
        stretch.layer.shadowColor = UIColor.black.cgColor
        stretch.layer.shadowOffset = CGSize(width: 0, height: 8)
        stretch.layer.shadowRadius = 24
        stretch.layer.shadowOpacity = dark ? 0.4 : 0.12
        card.addSubview(stretch)
        card.accessibilityViewIsModal = true
        addSubview(card)

        for item in list {
            if item.destructive { items.addArrangedSubview(rule()) }
            let row = HoldMenuRow(item)
            row.addAction(UIAction { [weak self] _ in self?.close(then: item.action) }, for: .touchUpInside)
            items.addArrangedSubview(row)
        }
        items.isLayoutMarginsRelativeArrangement = true
        items.directionalLayoutMargins = NSDirectionalEdgeInsets(top: HoldMenuMetrics.padding, leading: HoldMenuMetrics.padding,
                                                                 bottom: HoldMenuMetrics.padding, trailing: HoldMenuMetrics.padding)
        stretch.addSubview(items)
    }

    /// The pressed row stays bright above the dim, where it is.
    private func lift(_ view: UIView, _ rect: CGRect) {
        guard rect.width > 1, rect.height > 1,
              let picture = view.resizableSnapshotView(from: rect, afterScreenUpdates: false, withCapInsets: .zero) else { return }
        picture.frame = view.convert(rect, to: self)
        picture.isUserInteractionEnabled = false
        // 3.5.27 (the owner): a held subscription (a part of the sheet, not a card of
        // its own) was hard to tell from the dimmed sheet around it. 3.5.29 (the
        // owner): no edge — the rest dims and what is held is lightened, its
        // background with it (in the light theme it is light already).
        if traitCollection.userInterfaceStyle == .dark {
            picture.layer.cornerRadius = view.layer.cornerRadius > 0 ? view.layer.cornerRadius : 18
            picture.layer.cornerCurve = .continuous
            picture.clipsToBounds = true
            let glow = UIView(frame: picture.bounds)
            glow.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            glow.backgroundColor = UIColor.white.withAlphaComponent(0.04)  // 3.6.1 (the owner): 0.08 was too bright
            glow.isUserInteractionEnabled = false
            picture.addSubview(glow)
        }
        insertSubview(picture, aboveSubview: backdrop)
        lifted = picture
    }

    private func keep(_ views: [UIView]) {
        for view in views where view.window != nil && !view.isHidden && view.alpha > 0.01 {
            guard let picture = view.snapshotView(afterScreenUpdates: false) else { continue }
            picture.frame = view.convert(view.bounds, to: self)
            picture.isUserInteractionEnabled = false
            insertSubview(picture, belowSubview: card)
            kept.append(picture)
        }
    }

    /// A thin inset rule before the destructive action, as in system menus.
    private func rule() -> UIView {
        let box = UIView()
        let line = UIView()
        line.backgroundColor = UIColor.label.withAlphaComponent(0.1)
        box.addSubview(line)
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.heightAnchor.constraint(equalToConstant: 0.5), line.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14), line.topAnchor.constraint(equalTo: box.topAnchor, constant: 5),
            line.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -5),
        ])
        return box
    }

    private func place(at touch: CGPoint, row: CGRect) {
        let fitted = items.systemLayoutSizeFitting(CGSize(width: HoldMenuMetrics.width, height: UIView.layoutFittingCompressedSize.height),
                                                   withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let content = CGSize(width: HoldMenuMetrics.width, height: ceil(max(44, fitted.height)))
        let place = HoldMenuMetrics.placement(content: content, touch: touch, row: row, bounds: bounds, safe: safeAreaInsets)
        let frame = place.frame
        card.frame = frame
        stretch.frame = card.bounds
        let whole = CGRect(origin: .zero, size: frame.size)
        let radius = HoldMenuMetrics.radius
        let outline = UIBezierPath(roundedRect: whole, cornerRadius: radius).cgPath
        // The pour starts as a small card at the edge facing the row, under the
        // finger: a fifth of the width, its corners already whole (so the outlines
        // have the same points and blend).
        let seedWidth = max(radius * 2 + 2, frame.width * 0.22)
        let seedHeight = radius * 2 + 2
        let seedX = min(max(place.originX - seedWidth / 2, 0), frame.width - seedWidth)
        let seed = CGRect(x: seedX, y: place.below ? 0 : frame.height - seedHeight, width: seedWidth, height: seedHeight)
        seedOutline = UIBezierPath(roundedRect: seed, cornerRadius: radius).cgPath
        fullOutline = outline
        stretch.layer.shadowPath = outline
        surface.frame = stretch.bounds
        surface.path = outline
        clip.frame = stretch.bounds
        clip.path = outline
        items.frame = whole
        items.layer.mask = clip
        direction = place.below ? 1 : -1
    }

    /// Moves the outline (surface, shadow, mask) from where it is now to `target`.
    private func morph(to target: CGPath, spring: Bool, duration: CFTimeInterval) {
        let parts: [(CALayer, String)] = [(surface, "path"), (clip, "path"), (stretch.layer, "shadowPath")]
        for (layer, key) in parts {
            let now: CGPath?
            if key == "path" { now = (layer.presentation() as? CAShapeLayer)?.path ?? (layer as? CAShapeLayer)?.path } else { now = layer.presentation()?.shadowPath ?? layer.shadowPath }
            let animation: CABasicAnimation
            if spring {
                let bounce = CASpringAnimation(keyPath: key)
                bounce.mass = 1
                bounce.stiffness = 260
                bounce.damping = 2 * sqrt(260)  // critical: no overshoot
                bounce.duration = bounce.settlingDuration
                animation = bounce
            } else {
                animation = CABasicAnimation(keyPath: key)
                animation.duration = duration
                animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            }
            animation.fromValue = now
            animation.toValue = target
            if key == "path" { (layer as? CAShapeLayer)?.path = target } else { layer.shadowPath = target }
            layer.add(animation, forKey: "outline")
        }
    }

    private func run(_ animator: UIViewPropertyAnimator, delay: TimeInterval = 0) {
        animator.isUserInteractionEnabled = true
        animators.append(animator)
        animator.startAnimation(afterDelay: delay)
    }

    private func animateIn() {
        card.alpha = 0
        run(UIViewPropertyAnimator(duration: 0.22, curve: .easeOut) { self.backdrop.alpha = 1 })
        guard !UIAccessibility.isReduceMotionEnabled else {
            run(UIViewPropertyAnimator(duration: 0.18, curve: .easeOut) { self.card.alpha = 1 })
            return
        }
        items.alpha = 0
        items.transform = CGAffineTransform(translationX: 0, y: -6 * direction)
        if let seedOutline, let fullOutline {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.path = seedOutline
            clip.path = seedOutline
            stretch.layer.shadowPath = seedOutline
            CATransaction.commit()
            morph(to: fullOutline, spring: true, duration: 0)
        }
        let appear = UIViewPropertyAnimator(duration: 0.12, curve: .easeOut) { self.card.alpha = 1 }
        let settle = UIViewPropertyAnimator(duration: 0.3, timingParameters: UISpringTimingParameters(dampingRatio: 1, initialVelocity: .zero))
        settle.addAnimations { self.items.alpha = 1; self.items.transform = .identity }
        run(appear); run(settle, delay: 0.06)
    }

    @objc private func backdropTouched() { close(then: nil) }

    override func accessibilityPerformEscape() -> Bool { close(then: nil); return true }

    /// Drains back into the row and fades; the chosen action runs once the menu is gone.
    private func close(then action: (() -> Void)?) {
        guard !leaving else { return }
        leaving = true
        isUserInteractionEnabled = false
        onDismiss?()
        for running in animators where running.state == .active { running.stopAnimation(true) }
        animators.removeAll()
        let reduce = UIAccessibility.isReduceMotionEnabled
        let shrink = UIViewPropertyAnimator(duration: 0.24, controlPoint1: CGPoint(x: 0.4, y: 0), controlPoint2: CGPoint(x: 0.2, y: 1)) {
            self.card.alpha = 0
            self.backdrop.alpha = 0
            self.lifted?.alpha = 0
            guard !reduce else { return }
            self.items.alpha = 0
        }
        if !reduce, let seedOutline { morph(to: seedOutline, spring: false, duration: 0.24) }
        shrink.addCompletion { [weak self] _ in
            self?.removeFromSuperview()
            if let action { DispatchQueue.main.async(execute: action) }
        }
        animators = [shrink]
        shrink.startAnimation()
    }
}
