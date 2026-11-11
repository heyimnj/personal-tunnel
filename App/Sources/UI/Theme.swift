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

    /// Cards of the Minimal interface: grouped surface at the chosen opacity.
    static var card: UIColor {
        let alpha = CGFloat(Prefs.opacity(Prefs.cardOpacityKey) * Prefs.opacity(Prefs.glassOpacityKey))
        return UIColor { traits in
            (traits.userInterfaceStyle == .dark ? UIColor(white: 0.11, alpha: 1) : UIColor(white: 0.965, alpha: 1)).withAlphaComponent(0.25 + 0.75 * alpha)
        }
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

    static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        if let descriptor = custom() { return UIFont(descriptor: descriptor, size: size) }
        return .systemFont(ofSize: size, weight: weight)
    }

    static func font(_ style: UIFont.TextStyle, _ weight: UIFont.Weight = .regular) -> UIFont {
        let size = UIFont.preferredFont(forTextStyle: style).pointSize
        return font(size, weight)
    }

    static func mono(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func flag(_ code: String?) -> String? { Countries.flagEmoji(code: code) }
}

/// A translucent surface: Liquid Glass on iOS 26 and later, system blur before.
final class GlassView: UIVisualEffectView {
    private let radius: CGFloat?
    private let opacityKey: String?

    /// `radius == nil` makes a capsule.
    init(radius: CGFloat? = nil, opacityKey: String? = nil) {
        self.radius = radius
        self.opacityKey = opacityKey
        super.init(effect: nil)
        clipsToBounds = true
        layer.cornerCurve = .continuous
        restyle()
        Prefs.appearanceChanged.observe(self) { [weak self] in self?.restyle() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func restyle() {
        let strength = CGFloat(Prefs.opacity(Prefs.glassOpacityKey) * (opacityKey.map(Prefs.opacity) ?? 1))
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.isInteractive = false
            if Prefs.glassStyle == "tinted" { glass.tintColor = Theme.accent.withAlphaComponent(0.18) }
            effect = glass
            contentView.backgroundColor = Prefs.glassStyle == "clear" ? .clear : UIColor.systemBackground.withAlphaComponent(0.35 * strength)
        } else {
            effect = UIBlurEffect(style: Prefs.glassStyle == "clear" ? .systemUltraThinMaterial : .systemThinMaterial)
            contentView.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.25 * strength)
            layer.borderWidth = 1 / UIScreen.main.scale
            layer.borderColor = UIColor.separator.withAlphaComponent(0.5).cgColor
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = radius ?? bounds.height / 2
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

/// A plain control that dims while pressed and calls a closure.
class TapControl: UIControl {
    var onTap: (() -> Void)?
    var pressScale: CGFloat = 0.97

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
            UIView.animate(withDuration: pressed ? 0.08 : 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.transform = pressed ? CGAffineTransform(scaleX: self.pressScale, y: self.pressScale) : .identity
                self.alpha = pressed ? 0.85 : 1
            }
        }
    }
}
