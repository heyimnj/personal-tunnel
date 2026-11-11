import TunnelCore
import UIKit

/// Building blocks of the Classic look: thin frames, monospaced captions, dark slabs.
enum Classic {
    static func mono(_ text: String, _ size: CGFloat = 10, _ color: UIColor = .secondaryLabel, weight: UIFont.Weight = .medium) -> UILabel {
        let label = UILabel(text, font: Theme.mono(size, weight), color: color)
        label.attributedText = NSAttributedString(string: text, attributes: [.kern: 0.6])
        return label
    }

    static func text(_ text: String, _ size: CGFloat, _ weight: UIFont.Weight = .regular, _ color: UIColor = Theme.text, lines: Int = 1) -> UILabel {
        UILabel(text, font: Theme.font(size, weight), color: color, lines: lines)
    }

    /// Rectangular flag from the asset catalogue, or the dark «XX» tile.
    static func flag(_ code: String?, width: CGFloat = 34) -> UIView {
        let height = width * 0.66
        let view: UIView
        if let code, let image = UIImage(named: "flag-\(code.lowercased())") {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.borderWidth = 0.5
            imageView.layer.borderColor = UIColor.separator.cgColor
            view = imageView
        } else {
            let tile = UILabel("XX", font: Theme.mono(9, .semibold), color: Theme.accent)
            tile.textAlignment = .center
            tile.backgroundColor = Theme.panel
            view = tile
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: width), view.heightAnchor.constraint(equalToConstant: height)])
        return view
    }

    static func rule(_ color: UIColor = Theme.line) -> UIView {
        let line = UIView()
        line.backgroundColor = color
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    static func padded(_ view: UIView, _ insets: UIEdgeInsets) -> UIView {
        let box = UIView()
        box.addSubview(view)
        view.pin(to: box, insets: insets)
        return box
    }

    static func ping(_ entry: LatencyEntry?, testing: Bool, upper: Bool = true) -> String {
        if testing { return upper ? "··· MS" : "··· ms" }
        switch entry?.result {
        case let .delay(value)?: return upper ? "\(value) MS" : "\(value) ms"
        case let .failed(reason)?: return reason.title.uppercased()
        case nil: return upper ? "— MS" : "— ms"
        }
    }
}

/// A box with a thin border and an optional caption line on top.
final class ClassicFrame: UIView {
    let stack = UIStackView(.vertical, spacing: 0, alignment: .fill, [])

    init(caption: String? = nil, border: UIColor = UIColor.label.withAlphaComponent(0.7), width: CGFloat = 1) {
        super.init(frame: .zero)
        layer.borderWidth = width
        layer.borderColor = border.cgColor
        addSubview(stack)
        stack.pin(to: self)
        if let caption {
            stack.addArrangedSubview(Classic.padded(Classic.mono(caption, 10, Theme.text, weight: .bold), UIEdgeInsets(top: 18, left: 18, bottom: 14, right: 18)))
            stack.addArrangedSubview(Classic.padded(Classic.rule(), UIEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)))
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    func add(_ view: UIView, insets: UIEdgeInsets = UIEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)) {
        stack.addArrangedSubview(Classic.padded(view, insets))
    }
}

/// A row that calls back on tap, without the scale effect of the Minimal look.
final class ClassicRow: TapControl {
    init(_ content: UIView, insets: UIEdgeInsets = .zero, action: @escaping () -> Void) {
        super.init(frame: .zero)
        pressScale = 1
        content.isUserInteractionEnabled = false
        addSubview(content)
        content.pin(to: self, insets: insets)
        onTap = action
    }
}

/// Scrolling page with 20 pt margins used by every Classic tab.
class ClassicPage: UIViewController {
    let scroll = UIScrollView()
    let content = UIStackView(.vertical, spacing: 18, alignment: .fill, [])

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .onDrag
        view.addSubview(scroll)
        scroll.pin(to: view)
        scroll.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
        rebuild()
        Prefs.appearanceChanged.observe(self) { [weak self] in
            self?.view.backgroundColor = Theme.background
            self?.rebuild()
        }
    }

    /// Clears and builds the page again; pages are small, so this is cheap.
    func rebuild() {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        build()
    }

    func build() {}
}
