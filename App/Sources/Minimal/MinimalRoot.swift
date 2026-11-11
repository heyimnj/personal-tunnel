import UIKit

enum MinimalIcons {
    /// The Home tab glyph: the app icon's mark (two arches on feet and a centre bar).
    static let home: UIImage = {
        let size = CGSize(width: 30, height: 30)
        return UIGraphicsImageRenderer(size: size).image { context in
            let c = context.cgContext
            c.setStrokeColor(UIColor.black.cgColor)
            c.setFillColor(UIColor.black.cgColor)
            c.setLineWidth(2.3)
            c.addArc(center: CGPoint(x: 15, y: 15.5), radius: 11.2, startAngle: .pi, endAngle: 0, clockwise: false)
            c.strokePath()
            // Inner arch is taller than it is wide, as on the icon.
            let inner = UIBezierPath()
            inner.move(to: CGPoint(x: 9.2, y: 17.5))
            inner.addCurve(to: CGPoint(x: 15, y: 9.6), controlPoint1: CGPoint(x: 9.2, y: 12.6), controlPoint2: CGPoint(x: 12, y: 9.6))
            inner.addCurve(to: CGPoint(x: 20.8, y: 17.5), controlPoint1: CGPoint(x: 18, y: 9.6), controlPoint2: CGPoint(x: 20.8, y: 12.6))
            c.addPath(inner.cgPath)
            c.strokePath()
            for rect in [CGRect(x: 2.2, y: 15.5, width: 3.4, height: 7.5), CGRect(x: 24.4, y: 15.5, width: 3.4, height: 7.5),
                         CGRect(x: 7.5, y: 17.5, width: 3.4, height: 5.5), CGRect(x: 19.1, y: 17.5, width: 3.4, height: 5.5),
                         CGRect(x: 13.7, y: 18, width: 2.6, height: 6)]
            {
                c.fill(rect)
            }
        }.withRenderingMode(.alwaysTemplate)
    }()

    static let settings = UIImage(systemName: "rectangle.3.group.fill",
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .regular))!
}

/// The floating glass capsule with the two tabs.
final class MinimalTabBar: UIView {
    var onSelect: ((Int) -> Void)?
    private(set) var selected = 0
    private let glass = GlassView()
    private let pill = UIView()
    private var items: [TapControl] = []
    private var icons: [UIImageView] = []
    private var labels: [UILabel] = []
    private var heightConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(glass)
        glass.pin(to: self)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.08
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)
        pill.backgroundColor = UIColor.label.withAlphaComponent(0.07)
        pill.isUserInteractionEnabled = false
        glass.contentView.addSubview(pill)
        for (index, entry) in [("Главная", MinimalIcons.home), ("Настройки", MinimalIcons.settings)].enumerated() {
            let control = TapControl()
            let icon = UIImageView(image: entry.1)
            icon.contentMode = .scaleAspectFit
            let label = UILabel(entry.0, font: Theme.font(10, .medium))
            let stack = UIStackView(.vertical, spacing: 3, alignment: .center, [icon, label])
            stack.isUserInteractionEnabled = false
            control.addSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: control.centerXAnchor), stack.centerYAnchor.constraint(equalTo: control.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 26), icon.heightAnchor.constraint(equalToConstant: 26),
            ])
            control.accessibilityLabel = entry.0
            control.onTap = { [weak self] in self?.tap(index) }
            glass.contentView.addSubview(control)
            items.append(control)
            icons.append(icon)
            labels.append(label)
        }
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: 66)
        NSLayoutConstraint.activate([heightConstraint, widthAnchor.constraint(equalToConstant: 188)])
        restyle()
        Prefs.appearanceChanged.observe(self) { [weak self] in self?.restyle() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func tap(_ index: Int) {
        Haptics.selection()
        onSelect?(index)
    }

    func select(_ index: Int, animated: Bool) {
        selected = index
        let update = { self.layoutPill(); self.tint() }
        if animated {
            UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: update)
        } else {
            update()
        }
    }

    private func tint() {
        for index in items.indices {
            let color = index == selected ? Theme.accent : UIColor.label.withAlphaComponent(0.9)
            icons[index].tintColor = color
            labels[index].textColor = color
        }
    }

    private func restyle() {
        let hidden = Prefs.hideTabLabels
        for label in labels {
            label.isHidden = hidden
            label.font = Theme.font(10, .medium)
        }
        heightConstraint.constant = hidden ? 58 : 66
        tint()
        setNeedsLayout()
    }

    private func layoutPill() {
        let width = (bounds.width - 14) / 2
        pill.frame = CGRect(x: selected == 0 ? 5 : bounds.width - width - 5, y: 5, width: width, height: bounds.height - 10)
        pill.layer.cornerRadius = pill.bounds.height / 2
        pill.layer.cornerCurve = .continuous
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let half = bounds.width / 2
        for (index, item) in items.enumerated() {
            item.frame = CGRect(x: CGFloat(index) * half, y: 0, width: half, height: bounds.height)
        }
        layoutPill()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
    }
}

/// «Минималистичный»: Home (connection + analytics pager) and Settings behind a floating tab bar.
final class MinimalRootViewController: UIViewController, UINavigationControllerDelegate {
    private let home = MinimalHomeViewController()
    private lazy var settings: UINavigationController = {
        let controller = UINavigationController(rootViewController: MinimalSettingsViewController())
        controller.navigationBar.prefersLargeTitles = true
        return controller
    }()
    private let tabBar = MinimalTabBar()
    private var index = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        for controller in [home, settings] as [UIViewController] {
            addChild(controller)
            controller.view.frame = view.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(controller.view)
            controller.didMove(toParent: self)
            // Content scrolls under the floating bar.
            controller.additionalSafeAreaInsets.bottom = 64
        }
        settings.view.isHidden = true
        view.addSubview(tabBar)
        NSLayoutConstraint.activate([
            tabBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            tabBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: 14),
        ])
        tabBar.onSelect = { [weak self] in self?.select($0) }
        tabBar.select(0, animated: false)
        Prefs.appearanceChanged.observe(self) { [weak self] in self?.view.backgroundColor = Theme.background }
    }

    private func select(_ next: Int) {
        if next == index {
            if next == 0 { home.reselect() } else { settings.popToRootViewController(animated: true) }
            return
        }
        index = next
        tabBar.select(next, animated: true)
        home.view.isHidden = next != 0
        settings.view.isHidden = next != 1
        setNeedsStatusBarAppearanceUpdate()
    }

    /// Settings → «Подписки и серверы» opens the same panel as the Home capsule.
    func showServers() {
        present(MinimalServersViewController.wrapped(), animated: true)
    }
}
