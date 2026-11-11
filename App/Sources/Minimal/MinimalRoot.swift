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
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .regular))!
}

/// «Минималистичный»: Home (connection + analytics pager) and Settings in the
/// system tab bar, as 1.5.0 had it (`ModernTabContainer`): on iOS 26 and later it
/// is the system's Liquid Glass bar, before that the standard translucent one.
final class MinimalRootViewController: UITabBarController, UITabBarControllerDelegate {
    private let home = MinimalHomeViewController()
    private let settings: UINavigationController = {
        let controller = UINavigationController(rootViewController: MinimalSettingsViewController())
        controller.navigationBar.prefersLargeTitles = true
        return controller
    }()
    private var previous = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        setViewControllers([home, settings], animated: false)
        delegate = self
        updateItems()
        Prefs.appearanceChanged.observe(self) { [weak self] in
            self?.view.backgroundColor = Theme.background
            self?.updateItems()
        }
    }

    /// Icons, captions («Только иконки вкладок» removes them), accent tint and the imported font.
    private func updateItems() {
        let labels = !Prefs.hideTabLabels
        home.tabBarItem.image = MinimalIcons.home
        home.tabBarItem.title = labels ? "Главная" : nil
        home.tabBarItem.accessibilityLabel = "Главная"
        settings.tabBarItem.image = MinimalIcons.settings.withRenderingMode(.alwaysTemplate)
        settings.tabBarItem.title = labels ? "Настройки" : nil
        settings.tabBarItem.accessibilityLabel = "Настройки"
        tabBar.tintColor = Theme.accent
        let custom = !(Prefs.fontFile ?? "").isEmpty
        let attributes: [NSAttributedString.Key: Any]? = custom ? [.font: Theme.fixed(10, .medium)] : nil
        for item in [home.tabBarItem, settings.tabBarItem].compactMap({ $0 }) {
            item.setTitleTextAttributes(attributes, for: .normal)
            item.setTitleTextAttributes(attributes, for: .selected)
        }
    }

    func tabBarController(_: UITabBarController, didSelect _: UIViewController) {
        let next = selectedIndex
        // Tapping Home again steps back through analytics (Settings pops to its root by itself).
        if next == previous, next == 0 { home.reselect() }
        previous = next
        setNeedsStatusBarAppearanceUpdate()
    }

    /// Settings → «Подписки и серверы» opens the same panel as the Home capsule.
    func showServers() {
        present(MinimalServersViewController.wrapped(), animated: true)
    }
}
