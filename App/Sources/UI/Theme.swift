import CoreText
import TunnelCore
import UIKit

extension UIColor {
    convenience init?(hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(round(max(0, min(1, r)) * 255)), Int(round(max(0, min(1, g)) * 255)), Int(round(max(0, min(1, b)) * 255)))
    }
}

/// Colours and fonts of the current style. Values come from `Prefs`; screens
/// restyle when `Prefs.appearanceChanged` fires.
enum Theme {
    static var accent: UIColor { UIColor(hex: Prefs.accentHex()) ?? .systemBlue }

    static var userInterfaceStyle: UIUserInterfaceStyle {
        switch Prefs.theme {
        case "light": return .light
        case "dark": return .dark
        default: return .unspecified
        }
    }

    /// Screen background: white / black in Minimal, grouped grey in Classic.
    static var background: UIColor {
        let minimal = Prefs.style == .minimal
        let amoled = Prefs.amoled
        return UIColor { traits in
            if traits.userInterfaceStyle == .dark { return amoled ? .black : UIColor(white: 0.13, alpha: 1) }
            return minimal ? .white : UIColor.systemGroupedBackground.resolvedColor(with: traits)
        }
    }

    static var text: UIColor { UIColor(hex: Prefs.textHex) ?? .label }
    static let secondaryText = UIColor.secondaryLabel
    /// Dark slabs of the Classic interface.
    static var panel: UIColor { UIColor(hex: Prefs.panelHex) ?? UIColor(red: 0.15, green: 0.17, blue: 0.21, alpha: 1) }
    static let line = UIColor.separator
    static let danger = UIColor(red: 0.82, green: 0.24, blue: 0.20, alpha: 1)
    static let connected = UIColor.systemGreen

    /// Analytics cards of the Minimal interface, as 1.5.0 drew them (`ModernGlass`
    /// "analytics"): a faint grouped surface, solid when transparency is reduced.
    /// 3.5 beta 2: its colour and how solid it is are the owner's to choose
    /// («Стекло и прозрачность» → «Фон карточек»).
    static var card: UIColor {
        let base = UIColor(hex: Prefs.cardHex) ?? .secondarySystemBackground
        return UIAccessibility.isReduceTransparencyEnabled ? base : base.withAlphaComponent(CGFloat(Prefs.cardFill))
    }

    // MARK: Fonts

    private static var customDescriptor: (file: String, descriptor: UIFontDescriptor)?

    static var fontsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Fonts", isDirectory: true)
    }

    /// The imported font, read straight from its file (never looked up by name).
    private static func custom() -> UIFontDescriptor? {
        guard let file = Prefs.fontFile, !file.isEmpty else { return nil }
        if let cached = customDescriptor, cached.file == file { return cached.descriptor }
        let url = fontsDirectory.appendingPathComponent(file)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let first = descriptors.first else { return nil }
        let descriptor = first as UIFontDescriptor
        customDescriptor = (file, descriptor)
        return descriptor
    }

    /// Sizes are given for the default text size. `font` and `mono` follow the
    /// user's text size the way 1.5.0's text styles did (Minimal, shared pages);
    /// `fixed` and `fixedMono` keep the size, as 1.5.0's Classic screens did.
    static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        fixed(scaled(size), weight)
    }

    static func font(_ style: UIFont.TextStyle, _ weight: UIFont.Weight = .regular) -> UIFont {
        fixed(UIFont.preferredFont(forTextStyle: style).pointSize, weight)
    }

    /// 3.5.18: with an imported font, the log, the Classic labels and every figure
    /// take it too (the owner found analytics and the log in the system font);
    /// its digits made even-width where the font can.
    static func mono(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        fixedMono(scaled(size), weight)
    }

    /// Figures that change in place (speeds, totals, delays): even-width digits.
    static func digits(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        if let descriptor = customDigits() { return UIFont(descriptor: descriptor, size: size) }
        return .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    private static func customDigits() -> UIFontDescriptor? {
        guard let descriptor = custom() else { return nil }
        let feature: [UIFontDescriptor.FeatureKey: Int] = [.type: kNumberSpacingType, .selector: kMonospacedNumbersSelector]
        return descriptor.addingAttributes([.featureSettings: [feature]])
    }

    static func fixed(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        if let descriptor = custom() { return UIFont(descriptor: descriptor, size: size) }
        return .systemFont(ofSize: size, weight: weight)
    }

    static func fixedMono(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        if let descriptor = customDigits() { return UIFont(descriptor: descriptor, size: size) }
        return .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// A size scaled like the text style it is closest to.
    static func scaled(_ size: CGFloat) -> CGFloat {
        UIFontMetrics(forTextStyle: textStyle(near: size)).scaledValue(for: size)
    }

    private static func textStyle(near size: CGFloat) -> UIFont.TextStyle {
        switch size {
        case ..<11.5: return .caption2 // 11
        case ..<12.5: return .caption1 // 12
        case ..<14: return .footnote // 13
        case ..<15.5: return .subheadline // 15
        case ..<16.5: return .callout // 16
        case ..<18.5: return .body // 17
        case ..<21: return .title3 // 20
        case ..<25: return .title2 // 22
        case ..<31: return .title1 // 28
        default: return .largeTitle // 34
        }
    }

    static func flag(_ code: String?) -> String? { Countries.flagEmoji(code: code) }
}

/// A translucent surface, as 1.5.0's `ModernGlass`: Liquid Glass on iOS 26 and
/// later, the ultra-thin system material before; no backing colour and no border.
/// The opacity sliders fade the glass only, never what lies on it.
final class GlassView: UIView {
    /// Put content here: it stays opaque whatever the glass opacity.
    let contentView = UIView()
    private let effectView = UIVisualEffectView(effect: nil)
    private let radius: CGFloat?
    private let opacityKey: String?

    /// `radius == nil` makes a capsule.
    init(radius: CGFloat? = nil, opacityKey: String? = nil) {
        self.radius = radius
        self.opacityKey = opacityKey
        super.init(frame: .zero)
        effectView.clipsToBounds = true
        effectView.layer.cornerCurve = .continuous
        effectView.isUserInteractionEnabled = false
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        for view in [effectView, contentView] {
            addSubview(view)
            view.pin(to: self)
        }
        restyle()
        Prefs.appearanceChanged.observe(self) { [weak self] in self?.restyle() }
        NotificationCenter.default.addObserver(self, selector: #selector(restyle), name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    @objc func restyle() {
        if UIAccessibility.isReduceTransparencyEnabled {
            effectView.effect = nil
            effectView.alpha = 1
            effectView.backgroundColor = .secondarySystemBackground
            return
        }
        effectView.backgroundColor = .clear
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: Prefs.glassStyle == "clear" ? .clear : .regular)
            glass.isInteractive = false
            if Prefs.glassStyle == "tinted" { glass.tintColor = UIColor.label.withAlphaComponent(0.06) }
            effectView.effect = glass
        } else {
            effectView.effect = UIBlurEffect(style: .systemUltraThinMaterial)
        }
        effectView.alpha = CGFloat(Prefs.opacity(Prefs.glassOpacityKey) * (opacityKey.map(Prefs.opacity) ?? 1))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let corner = radius ?? bounds.height / 2
        effectView.layer.cornerRadius = corner
        contentView.layer.cornerRadius = corner
    }
}

/// The surface of the power button and the server capsule, as 1.5.0's
/// `AnywhereControlGlass`: native glass (iOS 27: regular, iOS 26: clear) with a
/// thin, broken specular rim; the ultra-thin material before iOS 26.
final class ControlGlassView: UIView {
    private let effectView = UIVisualEffectView(effect: nil)
    private let rim = CAGradientLayer()
    private let rimShape = CAShapeLayer()
    private let circle: Bool
    private let opacityKey: String

    init(circle: Bool, opacityKey: String) {
        self.circle = circle
        self.opacityKey = opacityKey
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        effectView.clipsToBounds = true
        effectView.layer.cornerCurve = .continuous
        addSubview(effectView)
        effectView.pin(to: self)
        rim.startPoint = CGPoint(x: 0, y: 0)
        rim.endPoint = CGPoint(x: 1, y: 1)
        rim.locations = [0, 0.22, 0.48, 0.72, 1]
        rimShape.fillColor = UIColor.clear.cgColor
        rimShape.strokeColor = UIColor.black.cgColor
        rimShape.lineWidth = 0.65
        rim.mask = rimShape
        layer.addSublayer(rim)
        restyle()
        Prefs.appearanceChanged.observe(self) { [weak self] in self?.restyle() }
        NotificationCenter.default.addObserver(self, selector: #selector(restyle), name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    @objc func restyle() {
        let solid = UIAccessibility.isReduceTransparencyEnabled
        rim.isHidden = solid
        if solid {
            effectView.effect = nil
            effectView.alpha = 1
            effectView.backgroundColor = .secondarySystemGroupedBackground
            return
        }
        effectView.backgroundColor = .clear
        if #available(iOS 26.0, *) {
            let glass: UIGlassEffect
            switch Prefs.glassStyle {
            case "clear": glass = UIGlassEffect(style: .clear)
            case "tinted":
                glass = UIGlassEffect(style: .regular)
                glass.tintColor = Theme.accent.withAlphaComponent(0.08)
            default:
                if #available(iOS 27.0, *) { glass = UIGlassEffect(style: .regular) } else { glass = UIGlassEffect(style: .clear) }
            }
            glass.isInteractive = circle
            effectView.effect = glass
        } else {
            effectView.effect = UIBlurEffect(style: .systemUltraThinMaterial)
        }
        effectView.alpha = CGFloat(Prefs.opacity(Prefs.glassOpacityKey) * Prefs.opacity(opacityKey))
        updateRimColors()
    }

    private func updateRimColors() {
        let dark = traitCollection.userInterfaceStyle == .dark
        rim.colors = [
            UIColor.white.withAlphaComponent(dark ? 0.24 : 0.85), UIColor.white.withAlphaComponent(0.02), UIColor.clear,
            UIColor.label.resolvedColor(with: traitCollection).withAlphaComponent(0.06), UIColor.white.withAlphaComponent(dark ? 0.16 : 0.65),
        ].map(\.cgColor)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle { updateRimColors() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let corner = bounds.height / 2
        effectView.layer.cornerRadius = corner
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.frame = bounds
        // The stroke sits inside the edge, like SwiftUI's strokeBorder.
        let inset = rimShape.lineWidth / 2
        rimShape.path = UIBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), cornerRadius: corner - inset).cgPath
        CATransaction.commit()
    }
}

extension UIView {
    func pin(to other: UIView, insets: UIEdgeInsets = .zero) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
        ])
    }

    static func spacer(_ height: CGFloat) -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }
}

extension UILabel {
    convenience init(_ text: String = "", font: UIFont, color: UIColor = Theme.text, lines: Int = 1) {
        self.init()
        self.text = text
        self.font = font
        textColor = color
        numberOfLines = lines
        adjustsFontForContentSizeCategory = false
    }
}

extension UIStackView {
    convenience init(_ axis: NSLayoutConstraint.Axis, spacing: CGFloat = 0, alignment: UIStackView.Alignment = .fill, _ views: [UIView]) {
        self.init(arrangedSubviews: views)
        self.axis = axis
        self.spacing = spacing
        self.alignment = alignment
    }
}

/// A plain control that dims while pressed and calls a closure. With `ripple`
/// it gives 1.5.0's `ModernTouchFeedback` instead: the control grows by 1.2 %
/// and a faint wave runs from under the finger out to the edges; a barely
/// visible tint stays while the finger holds it and fades once it lets go. Only
/// the server capsule and the connect button of Home use it.
class TapControl: UIControl {
    var onTap: (() -> Void)?
    var pressScale: CGFloat = 0.97
    var ripple = false {
        didSet { if ripple { pressScale = 0.985 } }
    }
    /// Corner radius the shade is clipped to; `nil` makes a capsule or circle.
    var rippleCornerRadius: CGFloat?
    private var rippleClip: UIView?
    /// The shade of the current press, faded when the press ends.
    private var shade: CAGradientLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(fire), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    @objc private func fire() { onTap?() }

    override var isHighlighted: Bool {
        didSet {
            guard oldValue != isHighlighted else { return }
            let pressed = isHighlighted
            let reduce = UIAccessibility.isReduceMotionEnabled
            if ripple {
                // 3.5.26 (the owner: like a heavy stone into calm water, slower but not
                // slow): the surface sinks under the finger, and on release rises back
                // with a couple of settling swings.
                // 3.6.2: the spot is let go by endTracking / cancelTracking (spread or faded).
                if reduce {
                    transform = .identity
                } else if pressed {
                    UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
                        self.transform = CGAffineTransform(scaleX: self.pressScale, y: self.pressScale)
                    }
                } else {
                    UIView.animate(withDuration: 0.9, delay: 0, usingSpringWithDamping: 0.42, initialSpringVelocity: 0.6,
                                   options: [.beginFromCurrentState, .allowUserInteraction]) {
                        self.transform = .identity
                    }
                }
                return
            }
            // 3.1.4: a control that does not scale leaves its transform alone. A
            // swiped card is moved by its transform every frame; the release
            // animated it back towards identity on top of the swipe (UIKit adds
            // such animations), and the card fell behind its plate, then jumped.
            let scales = pressScale != 1
            UIView.animate(withDuration: pressed ? 0.08 : 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                if scales { self.transform = pressed ? CGAffineTransform(scaleX: self.pressScale, y: self.pressScale) : .identity }
                self.alpha = pressed ? 0.85 : 1
            }
        }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        drift = .zero
        if ripple, !UIAccessibility.isReduceMotionEnabled { spread(from: touch.location(in: self)) }
        return super.beginTracking(touch, with: event)
    }

    /// 3.6.5 (the owner): the spot follows the finger. Towards the edge the plate's
    /// border cuts it off, and past it the spot pales with the distance — as if
    /// it ran off over the edge, unseen, and was gone.
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let going = super.continueTracking(touch, with: event)
        if ripple, let shade, !UIAccessibility.isReduceMotionEnabled {
            let point = touch.location(in: self)
            let previous = touch.previousLocation(in: self)
            // The way the finger goes, kept smooth, for the run-off on release.
            drift = CGPoint(x: drift.x * 0.6 + (point.x - previous.x) * 0.4, y: drift.y * 0.6 + (point.y - previous.y) * 0.4)
            let outX = max(0, -point.x, point.x - bounds.width)
            let outY = max(0, -point.y, point.y - bounds.height)
            let out = hypot(outX, outY)
            let fadeOver = max(shade.bounds.width / 2 * 0.9, 30)
            leaveGhost(of: shade, towards: point)
            CATransaction.begin()
            // A touch of lag, so it moves like something liquid, not glued on
            // (3.6.6: 0.16 s, was 0.09).
            CATransaction.setAnimationDuration(0.16)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            shade.position = point
            shade.opacity = Float(max(0, 1 - out / fadeOver))
            CATransaction.commit()
        }
        return going
    }

    /// The finger's recent way, points per touch event (see `continueTracking`).
    private var drift = CGPoint.zero

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        let inside = isTouchInside
        super.endTracking(touch, with: event)
        fadeShade(inside ? .spread : .runOff)
    }

    override func cancelTracking(with event: UIEvent?) {
        super.cancelTracking(with: event)
        fadeShade(.retract)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let rippleClip else { return }
        rippleClip.frame = bounds
        rippleClip.layer.cornerRadius = rippleCornerRadius ?? min(bounds.width, bounds.height) / 2
        bringSubviewToFront(rippleClip)
    }

    /// 3.5.26 (the owner): a stone into water. Under the finger a soft dimple grows
    /// and stays while it holds. 3.6.2: no ring; on release the spot spreads.
    private func spread(from point: CGPoint) {
        let clip: UIView
        if let rippleClip { clip = rippleClip } else {
            clip = UIView(frame: bounds)
            clip.isUserInteractionEnabled = false
            clip.clipsToBounds = true
            clip.layer.cornerCurve = .continuous
            clip.layer.cornerRadius = rippleCornerRadius ?? min(bounds.width, bounds.height) / 2
            addSubview(clip)
            rippleClip = clip
        }
        bringSubviewToFront(clip)
        fadeShade()
        let corners = [CGPoint.zero, CGPoint(x: bounds.width, y: 0), CGPoint(x: 0, y: bounds.height), CGPoint(x: bounds.width, y: bounds.height)]
        let farthest = corners.map { hypot($0.x - point.x, $0.y - point.y) }.max() ?? 1
        let ink = UIColor.label.resolvedColor(with: traitCollection)

        // The dimple: a soft darker centre.
        let dimpleRadius = min(farthest, max(bounds.height, 44)) * 0.9
        let shade = CAGradientLayer()
        shade.type = .radial
        // 3.6.6 (the owner, «Волна» in PTLab): a little deeper than 0.07, so the press is seen.
        shade.colors = [ink.withAlphaComponent(0.09).cgColor, ink.withAlphaComponent(0.045).cgColor, ink.withAlphaComponent(0).cgColor]
        shade.locations = [0, 0.55, 1]
        shade.startPoint = CGPoint(x: 0.5, y: 0.5)
        shade.endPoint = CGPoint(x: 1, y: 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.bounds = CGRect(x: 0, y: 0, width: dimpleRadius * 2, height: dimpleRadius * 2)
        shade.position = point
        clip.layer.addSublayer(shade)
        CATransaction.commit()
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.2
        grow.toValue = 1
        grow.duration = 0.5
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
        shade.add(grow, forKey: "spread")
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = 0.12
        shade.add(appear, forKey: "appear")
        self.shade = shade

        // 3.6.2 (the owner): no thin ring — the spot alone carries the touch, and
        // on release it spreads over the whole plate (fadeShade).
        shadeReach = farthest * 1.08 / dimpleRadius
        lastGhost = 0
        lastGhostPoint = point
    }

    private var lastGhost: CFTimeInterval = 0
    private var lastGhostPoint = CGPoint.zero

    /// 3.6.6 (the owner: the trail a little longer): where the spot was a moment
    /// ago a fainter copy stays and melts away, so the moving finger leaves a wake.
    private func leaveGhost(of shade: CAGradientLayer, towards point: CGPoint) {
        let now = CACurrentMediaTime()
        guard now - lastGhost > 0.035, hypot(point.x - lastGhostPoint.x, point.y - lastGhostPoint.y) > 3, let host = rippleClip else { return }
        lastGhost = now
        lastGhostPoint = point
        let ghost = CAGradientLayer()
        ghost.type = .radial
        ghost.colors = shade.colors
        ghost.locations = shade.locations
        ghost.startPoint = shade.startPoint
        ghost.endPoint = shade.endPoint
        let from = shade.presentation()?.position ?? shade.position
        let opacity = (shade.presentation()?.opacity ?? shade.opacity) * 0.45
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.bounds = shade.bounds
        ghost.position = from
        ghost.opacity = 0
        host.layer.insertSublayer(ghost, below: shade)
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity
        fade.toValue = 0
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 0.95
        shrink.toValue = 0.7
        let group = CAAnimationGroup()
        group.animations = [fade, shrink]
        group.duration = 0.42
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ghost.add(group, forKey: "ghost")
        CATransaction.commit()
    }

    /// The scale at which the spot covers the whole plate (set by `spread`).
    private var shadeReach: CGFloat = 1

    /// How a press lets its spot go.
    private enum ShadeEnd {
        /// Let go on the plate: the spot runs out over all of it.
        case spread
        /// 3.6.4 (the owner): the press was called off by a scroll that took it.
        /// The spot draws back into itself, not just fades.
        case retract
        /// 3.6.5 (the owner): let go off the plate — the spot, which followed the
        /// finger, runs on the way it went, over the edge, and is gone.
        case runOff
        /// A new press began on top of the old spot.
        case fade
    }

    /// The press ended. 3.6.2 (the owner: the accent is on the spot now): let go
    /// on the plate, the spot runs out over all of it — the same soft round shape —
    /// a touch deeper as it goes, then fades.
    private func fadeShade(_ end: ShadeEnd = .fade) {
        guard let shade else { return }
        self.shade = nil
        let current = shade.presentation()?.opacity ?? shade.opacity
        let scale = (shade.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
        CATransaction.begin()
        CATransaction.setCompletionBlock { shade.removeFromSuperlayer() }
        if end == .runOff, !UIAccessibility.isReduceMotionEnabled {
            let duration = 0.42
            let from = shade.presentation()?.position ?? shade.position
            let length = max(hypot(drift.x, drift.y), 0.001)
            // On the way the finger went, a spot's width or so further (3.6.6: further).
            let run = min(shade.bounds.width * 0.8, max(40, length * 8))
            let to = CGPoint(x: from.x + drift.x / length * run, y: from.y + drift.y / length * run)
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(cgPoint: from)
            move.toValue = NSValue(cgPoint: to)
            move.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.6, 0.4, 1)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = current
            fade.toValue = 0
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = duration
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            shade.position = to
            shade.opacity = 0
            shade.add(group, forKey: "runOff")
            drift = .zero
            CATransaction.commit()
            return
        }
        if end == .retract, !UIAccessibility.isReduceMotionEnabled {
            // 3.6.4: called off — the spot gathers back towards the point it came
            // from (the reverse of its growth, quicker) and is gone, a little paler
            // at once so it reads as «not this time».
            let duration = 0.3
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = scale
            shrink.toValue = scale * 0.25
            shrink.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.75, 0.4)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [current, current * 0.7, 0]
            fade.keyTimes = [0, 0.3, 1]
            let group = CAAnimationGroup()
            group.animations = [shrink, fade]
            group.duration = duration
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            shade.removeAnimation(forKey: "spread")
            shade.add(group, forKey: "retract")
            CATransaction.commit()
            return
        }
        guard end == .spread, !UIAccessibility.isReduceMotionEnabled else {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = current
            fade.toValue = 0
            fade.duration = 0.5
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shade.opacity = 0
            shade.add(fade, forKey: "fade")
            CATransaction.commit()
            return
        }
        // 3.6.3 (the owner): 0.85 s was not seen — the next sheet opened over it.
        // 3.6.4: 0.18 s — but it read as a flat dark fill, like a settings row.
        // 3.6.6 (the owner, «Волна» in PTLab): a wave, not a flood — the spot
        // runs out to the edges while its middle empties, so the darker front is
        // what moves (0.42 s); then it is gone.
        let duration = 0.42
        let ink = UIColor.label.resolvedColor(with: traitCollection)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = scale
        grow.toValue = max(scale, shadeReach * 1.05)
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.15, 0.55, 0.3, 1)
        let deepen = CAKeyframeAnimation(keyPath: "colors")
        let first: [Any] = shade.colors ?? []
        let middle: [Any] = [ink.withAlphaComponent(0.055).cgColor, ink.withAlphaComponent(0.105).cgColor, ink.withAlphaComponent(0).cgColor]
        let last: [Any] = [ink.withAlphaComponent(0).cgColor, ink.withAlphaComponent(0.095).cgColor, ink.withAlphaComponent(0).cgColor]
        deepen.values = [first, middle, last]
        deepen.keyTimes = [0, 0.3, 1]
        let front = CABasicAnimation(keyPath: "locations")
        front.fromValue = [0, 0.55, 1]
        front.toValue = [0, 0.82, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [current, 1, 1, 0]
        fade.keyTimes = [0, 0.1, 0.6, 1]
        let group = CAAnimationGroup()
        group.animations = [grow, deepen, front, fade]
        group.duration = duration
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        shade.removeAnimation(forKey: "spread")
        shade.add(group, forKey: "release")
        CATransaction.commit()
    }
}

/// 3.5: the owner's own background for the Minimal Home and analytics, up to
/// four colours blended across the screen, as 1.x had it. One colour fills the
/// screen; two run top to bottom; three: two along the top, one along the bottom;
/// four: top left, top right, bottom left, bottom right. Drawn once, small, and
/// stretched smoothly by the image view: nothing is redrawn per frame.
enum Wallpaper {
    /// Shown instead of the plain background.
    static var active: Bool { Prefs.style == .minimal && Prefs.customBackground }

    private static let cache = NSCache<NSString, UIImage>()

    static func image(_ hexes: [String]) -> UIImage {
        let key = hexes.joined(separator: "|") as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let colors = hexes.compactMap { UIColor(hex: $0) }.map { color -> [CGFloat] in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b]
        }
        let corners: [[CGFloat]]
        switch colors.count {
        case 0: corners = Array(repeating: [0.13, 0.13, 0.13], count: 4)
        case 1: corners = Array(repeating: colors[0], count: 4)
        case 2: corners = [colors[0], colors[0], colors[1], colors[1]]
        case 3: corners = [colors[0], colors[1], colors[2], colors[2]]
        default: corners = Array(colors.prefix(4))
        }
        let side = 64
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0 ..< side {
            let v = CGFloat(y) / CGFloat(side - 1)
            for x in 0 ..< side {
                let u = CGFloat(x) / CGFloat(side - 1)
                for channel in 0 ..< 3 {
                    let top = corners[0][channel] * (1 - u) + corners[1][channel] * u
                    let bottom = corners[2][channel] * (1 - u) + corners[3][channel] * u
                    bytes[(y * side + x) * 4 + channel] = UInt8((max(0, min(1, top * (1 - v) + bottom * v)) * 255).rounded())
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let picture = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return UIImage() }
        let image = UIImage(cgImage: picture)
        cache.setObject(image, forKey: key)
        return image
    }

    /// Puts the background into `view` (under everything) or takes it away.
    static func apply(to view: UIView, holder: inout UIImageView?) {
        guard active else {
            holder?.removeFromSuperview()
            holder = nil
            view.backgroundColor = Theme.background
            return
        }
        let imageView = holder ?? UIImageView()
        imageView.image = image(Prefs.backgroundColors)
        imageView.contentMode = .scaleToFill
        imageView.layer.minificationFilter = .linear
        imageView.layer.magnificationFilter = .linear
        imageView.isUserInteractionEnabled = false
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if imageView.superview !== view { view.insertSubview(imageView, at: 0) } else { view.sendSubviewToBack(imageView) }
        holder = imageView
        view.backgroundColor = Theme.background
    }
}
