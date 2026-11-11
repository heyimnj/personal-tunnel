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
    static var card: UIColor {
        UIAccessibility.isReduceTransparencyEnabled ? .secondarySystemBackground : UIColor.secondarySystemBackground.withAlphaComponent(0.23)
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

    static func mono(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        .monospacedSystemFont(ofSize: scaled(size), weight: weight)
    }

    static func fixed(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        if let descriptor = custom() { return UIFont(descriptor: descriptor, size: size) }
        return .systemFont(ofSize: size, weight: weight)
    }

    static func fixedMono(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
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
/// and a soft shade appears under the finger and spreads to the edges, fading.
class TapControl: UIControl {
    var onTap: (() -> Void)?
    var pressScale: CGFloat = 0.97
    var ripple = false {
        didSet { if ripple { pressScale = 1.012 } }
    }
    /// Corner radius the shade is clipped to; `nil` makes a capsule or circle.
    var rippleCornerRadius: CGFloat?
    private var rippleClip: UIView?

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
                UIView.animate(withDuration: reduce ? 0 : (pressed ? 0.10 : 0.18), delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
                    self.transform = pressed && !reduce ? CGAffineTransform(scaleX: self.pressScale, y: self.pressScale) : .identity
                }
                return
            }
            UIView.animate(withDuration: pressed ? 0.08 : 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.transform = pressed ? CGAffineTransform(scaleX: self.pressScale, y: self.pressScale) : .identity
                self.alpha = pressed ? 0.85 : 1
            }
        }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        if ripple, !UIAccessibility.isReduceMotionEnabled { spread(from: touch.location(in: self)) }
        return super.beginTracking(touch, with: event)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let rippleClip else { return }
        rippleClip.frame = bounds
        rippleClip.layer.cornerRadius = rippleCornerRadius ?? min(bounds.width, bounds.height) / 2
        bringSubviewToFront(rippleClip)
    }

    /// The shade: a radial gradient twice the diagonal, from 1.5 % to full size in 0.38 s.
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
        let reach = hypot(bounds.width, bounds.height) * 2
        let shade = CAGradientLayer()
        shade.type = .radial
        shade.colors = [UIColor.label.resolvedColor(with: traitCollection).withAlphaComponent(0.10).cgColor, UIColor.clear.cgColor]
        shade.startPoint = CGPoint(x: 0.5, y: 0.5)
        shade.endPoint = CGPoint(x: 1, y: 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.bounds = CGRect(x: 0, y: 0, width: reach, height: reach)
        shade.position = point
        shade.transform = CATransform3DIdentity
        shade.opacity = 0
        clip.layer.addSublayer(shade)
        CATransaction.commit()
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.015
        grow.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.38
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { shade.removeFromSuperlayer() }
        shade.add(group, forKey: "spread")
        CATransaction.commit()
    }
}
