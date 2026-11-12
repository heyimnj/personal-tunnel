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

    /// The menu's surface: the cards' colour, a step lighter in dark mode so it
    /// stands off the cards it covers.
    static let fill = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.173, green: 0.173, blue: 0.180, alpha: 1) : .white
    }

    /// `source`: the pressed row and the part of it to lift above the dim.
    static func show(in host: UIView, at point: CGPoint, title: String, items: [HoldMenuItem], source: (view: UIView, rect: CGRect)? = nil, onDismiss: (() -> Void)? = nil) {
        let menu = HoldMenuView(frame: host.bounds)
        menu.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        menu.onDismiss = onDismiss
        menu.accessibilityLabel = title
        menu.build(items)
        host.addSubview(menu)
        var row = CGRect(origin: point, size: .zero)
        if let source {
            menu.lift(source.view, source.rect)
            row = source.view.convert(source.rect, to: menu)
        }
        menu.place(at: point, row: row)
        menu.animateIn()
        Haptics.soft()
    }

    private func build(_ list: [HoldMenuItem]) {
        backdrop.addTarget(self, action: #selector(backdropTouched), for: .touchDown)
        backdrop.backgroundColor = UIColor.black.withAlphaComponent(traitCollection.userInterfaceStyle == .dark ? 0.4 : 0.16)
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
        insertSubview(picture, aboveSubview: backdrop)
        lifted = picture
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
        // Both halves of the pour grow out of the edge facing the row, under the finger.
        let origin = CGPoint(x: place.originX, y: place.below ? 0 : frame.height)
        let anchor = CGPoint(x: origin.x / frame.width, y: origin.y / frame.height)
        card.layer.anchorPoint = anchor
        card.bounds = CGRect(origin: .zero, size: frame.size)
        card.layer.position = CGPoint(x: frame.minX + origin.x, y: frame.minY + origin.y)
        stretch.layer.anchorPoint = anchor
        stretch.bounds = card.bounds
        stretch.layer.position = origin
        let outline = UIBezierPath(roundedRect: CGRect(origin: .zero, size: frame.size), cornerRadius: HoldMenuMetrics.radius)
        stretch.layer.shadowPath = outline.cgPath
        surface.frame = stretch.bounds
        surface.path = outline.cgPath
        items.frame = CGRect(origin: .zero, size: frame.size)
        direction = place.below ? 1 : -1
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
        card.transform = CGAffineTransform(scaleX: 0.22, y: 1)
        stretch.transform = CGAffineTransform(scaleX: 1, y: 0.06)
        items.alpha = 0
        items.transform = CGAffineTransform(translationX: 0, y: -10 * direction)
        let pour = UIViewPropertyAnimator(duration: 0.46, timingParameters: UISpringTimingParameters(dampingRatio: 0.74, initialVelocity: CGVector(dx: 0, dy: 1.2)))
        pour.addAnimations { self.stretch.transform = .identity }
        let spread = UIViewPropertyAnimator(duration: 0.56, timingParameters: UISpringTimingParameters(dampingRatio: 0.8, initialVelocity: .zero))
        spread.addAnimations { self.card.transform = .identity }
        let appear = UIViewPropertyAnimator(duration: 0.12, curve: .easeOut) { self.card.alpha = 1 }
        let settle = UIViewPropertyAnimator(duration: 0.3, timingParameters: UISpringTimingParameters(dampingRatio: 0.9, initialVelocity: .zero))
        settle.addAnimations { self.items.alpha = 1; self.items.transform = .identity }
        run(appear); run(pour); run(spread, delay: 0.03); run(settle, delay: 0.09)
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
            self.card.transform = CGAffineTransform(scaleX: 0.4, y: 1)
            self.stretch.transform = CGAffineTransform(scaleX: 1, y: 0.12)
        }
        shrink.addCompletion { [weak self] _ in
            self?.removeFromSuperview()
            if let action { DispatchQueue.main.async(execute: action) }
        }
        animators = [shrink]
        shrink.startAnimation()
    }
}
