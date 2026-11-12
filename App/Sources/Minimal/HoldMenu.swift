import SwiftUI
import UIKit

struct HoldMenuItem {
    var title: String
    var symbol: String
    var destructive = false
    var action: () -> Void
}

/// Sizes of the hold menu, as in 1.5.0: a 268 pt card with 26 pt corners and a
/// soft arrow whose tip sits on the finger.
enum HoldMenuMetrics {
    static let width: CGFloat = 268
    static let radius: CGFloat = 26
    static let arrowWidth: CGFloat = 34
    static let arrowHeight: CGFloat = 12
    static let margin: CGFloat = 12
    static let rowHeight: CGFloat = 46
    static let padding: CGFloat = 6

    struct Placement {
        /// The card with its arrow strip, in the host's coordinates.
        var frame: CGRect
        /// The arrow is on the top edge: the menu hangs below the finger.
        var arrowUp: Bool
        /// The arrow tip's x inside the card.
        var arrowX: CGFloat
    }

    /// A press in the left third gets a left arrow and a menu running right, the
    /// right third the mirror image, the middle a centred arrow. Below the finger,
    /// above it without room, always inside the safe area.
    static func placement(content: CGSize, touch: CGPoint, bounds: CGRect, safe: UIEdgeInsets) -> Placement {
        let size = CGSize(width: content.width, height: content.height + arrowHeight)
        let minX = bounds.minX + max(margin, safe.left + 8)
        let maxX = bounds.maxX - max(margin, safe.right + 8) - size.width
        let minY = bounds.minY + safe.top + 8
        let maxY = bounds.maxY - safe.bottom - 8 - size.height
        let edgeArrow = radius + arrowWidth / 2 + 10
        let third = bounds.width / 3
        let preferredX: CGFloat
        if touch.x < bounds.minX + third { preferredX = touch.x - edgeArrow }
        else if touch.x > bounds.maxX - third { preferredX = touch.x - size.width + edgeArrow }
        else { preferredX = touch.x - size.width / 2 }
        let x = min(max(minX, preferredX), max(minX, maxX))
        let below = touch.y, above = touch.y - size.height
        let arrowUp: Bool, y: CGFloat
        if below <= maxY { arrowUp = true; y = below }
        else if above >= minY { arrowUp = false; y = above }
        else { arrowUp = true; y = min(max(minY, below), max(minY, maxY)) }
        let inset = radius + arrowWidth / 2
        let arrowX = min(max(inset, touch.x - x), size.width - inset)
        return Placement(frame: CGRect(x: x, y: y, width: size.width, height: size.height), arrowUp: arrowUp, arrowX: arrowX)
    }

    /// Body and arrow as one contour, so the glass, the blur mask and the shadow
    /// share it without a seam.
    static func outline(size: CGSize, arrowUp: Bool, arrowX: CGFloat) -> UIBezierPath {
        let h = arrowHeight, half = arrowWidth / 2
        let top: CGFloat = arrowUp ? h : 0
        let bottom: CGFloat = arrowUp ? size.height : size.height - h
        let r = max(0, min(radius, (bottom - top) / 2, size.width / 2))
        let w = size.width, H = size.height
        let ax = min(max(r + half, arrowX), w - r - half)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: r, y: top))
        if arrowUp {
            path.addLine(to: CGPoint(x: ax - half, y: top))
            path.addCurve(to: CGPoint(x: ax - 2.2, y: 1), controlPoint1: CGPoint(x: ax - half * 0.55, y: top), controlPoint2: CGPoint(x: ax - 4.2, y: 2.6))
            path.addQuadCurve(to: CGPoint(x: ax + 2.2, y: 1), controlPoint: CGPoint(x: ax, y: -0.4))
            path.addCurve(to: CGPoint(x: ax + half, y: top), controlPoint1: CGPoint(x: ax + 4.2, y: 2.6), controlPoint2: CGPoint(x: ax + half * 0.55, y: top))
        }
        path.addLine(to: CGPoint(x: w - r, y: top))
        path.addArc(withCenter: CGPoint(x: w - r, y: top + r), radius: r, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: w, y: bottom - r))
        path.addArc(withCenter: CGPoint(x: w - r, y: bottom - r), radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        if !arrowUp {
            path.addLine(to: CGPoint(x: ax + half, y: bottom))
            path.addCurve(to: CGPoint(x: ax + 2.2, y: H - 1), controlPoint1: CGPoint(x: ax + half * 0.55, y: bottom), controlPoint2: CGPoint(x: ax + 4.2, y: H - 2.6))
            path.addQuadCurve(to: CGPoint(x: ax - 2.2, y: H - 1), controlPoint: CGPoint(x: ax, y: H + 0.4))
            path.addCurve(to: CGPoint(x: ax - half, y: bottom), controlPoint1: CGPoint(x: ax - 4.2, y: H - 2.6), controlPoint2: CGPoint(x: ax - half * 0.55, y: bottom))
        }
        path.addLine(to: CGPoint(x: r, y: bottom))
        path.addArc(withCenter: CGPoint(x: r, y: bottom - r), radius: r, startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: 0, y: top + r))
        path.addArc(withCenter: CGPoint(x: r, y: top + r), radius: r, startAngle: .pi, endAngle: .pi * 1.5, clockwise: true)
        path.close()
        return path
    }
}

/// The menu outline for SwiftUI's glass, which takes any shape.
private struct HoldMenuOutline: Shape {
    var arrowUp: Bool
    var arrowX: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(HoldMenuMetrics.outline(size: rect.size, arrowUp: arrowUp, arrowX: arrowX).cgPath)
    }
}

@available(iOS 26.0, *)
private struct HoldMenuGlass: View {
    let outline: HoldMenuOutline
    var body: some View { Color.clear.glassEffect(Glass.regular, in: outline) }
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

/// The menu a long press opens, as in 1.5.0: a glass card with an arrow at the
/// finger that pours out of the pressed row (down first, then sideways, the items
/// settling a beat later) and drains back into it. A touch outside closes it.
final class HoldMenuView: UIView {
    /// Horizontal half of the pour (scale X), anchored at the arrow tip.
    private let card = UIView()
    /// Vertical half of the pour (scale Y); carries the shadow and the surface.
    private let stretch = UIView()
    private let items = UIStackView(.vertical, spacing: 0, alignment: .fill, [])
    private lazy var blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let silhouette = CAShapeLayer()
    private var glass: UIView?
    private var glassHost: UIHostingController<AnyView>?
    private var animators: [UIViewPropertyAnimator] = []
    private var direction: CGFloat = 1
    private var leaving = false
    private var onDismiss: (() -> Void)?

    static func show(in host: UIView, at point: CGPoint, title: String, items: [HoldMenuItem], onDismiss: (() -> Void)? = nil) {
        let menu = HoldMenuView(frame: host.bounds)
        menu.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        menu.onDismiss = onDismiss
        menu.accessibilityLabel = title
        menu.build(items)
        host.addSubview(menu)
        menu.place(at: point)
        menu.animateIn()
        Haptics.soft()
    }

    private func build(_ list: [HoldMenuItem]) {
        let backdrop = UIControl()
        backdrop.addTarget(self, action: #selector(backdropTouched), for: .touchDown)
        addSubview(backdrop)
        backdrop.pin(to: self)

        stretch.layer.shadowColor = UIColor.black.cgColor
        stretch.layer.shadowOffset = CGSize(width: 0, height: 8)
        stretch.layer.shadowRadius = 24
        let dark = traitCollection.userInterfaceStyle == .dark
        if #available(iOS 26.0, *) {
            let host = UIHostingController(rootView: AnyView(EmptyView()))
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
            stretch.addSubview(host.view)
            glass = host.view
            glassHost = host
            // Glass draws its own depth: only a faint lift under it.
            stretch.layer.shadowOpacity = dark ? 0.22 : 0.08
        } else {
            silhouette.fillColor = UIColor.black.cgColor
            blur.layer.mask = silhouette
            stretch.addSubview(blur)
            stretch.layer.shadowOpacity = dark ? 0.35 : 0.12
        }
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

    private func place(at touch: CGPoint) {
        let fitted = items.systemLayoutSizeFitting(CGSize(width: HoldMenuMetrics.width, height: UIView.layoutFittingCompressedSize.height),
                                                   withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let content = CGSize(width: HoldMenuMetrics.width, height: ceil(max(44, fitted.height)))
        let place = HoldMenuMetrics.placement(content: content, touch: touch, bounds: bounds, safe: safeAreaInsets)
        let frame = place.frame
        // Both halves of the pour grow out of the arrow tip.
        let tip = CGPoint(x: place.arrowX, y: place.arrowUp ? 0 : frame.height)
        let anchor = CGPoint(x: tip.x / frame.width, y: tip.y / frame.height)
        card.layer.anchorPoint = anchor
        card.bounds = CGRect(origin: .zero, size: frame.size)
        card.layer.position = CGPoint(x: frame.minX + tip.x, y: frame.minY + tip.y)
        stretch.layer.anchorPoint = anchor
        stretch.bounds = card.bounds
        stretch.layer.position = tip
        let outline = HoldMenuMetrics.outline(size: frame.size, arrowUp: place.arrowUp, arrowX: place.arrowX)
        stretch.layer.shadowPath = outline.cgPath
        if let glass, #available(iOS 26.0, *) {
            glassHost?.rootView = AnyView(HoldMenuGlass(outline: HoldMenuOutline(arrowUp: place.arrowUp, arrowX: place.arrowX)))
            glass.frame = stretch.bounds
        } else {
            blur.frame = stretch.bounds
            silhouette.frame = blur.bounds
            silhouette.path = outline.cgPath
        }
        items.frame = CGRect(x: 0, y: place.arrowUp ? HoldMenuMetrics.arrowHeight : 0, width: frame.width, height: content.height)
        direction = place.arrowUp ? 1 : -1
    }

    private func run(_ animator: UIViewPropertyAnimator, delay: TimeInterval = 0) {
        animator.isUserInteractionEnabled = true
        animators.append(animator)
        animator.startAnimation(afterDelay: delay)
    }

    private func animateIn() {
        card.alpha = 0
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
