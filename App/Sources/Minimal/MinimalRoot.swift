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

    /// 3.6.6 (the owner: the connection button now draws the logo's arch, and two
    /// app marks on one screen will not do): the Home tab is a signal — a dot with
    /// two waves either side.
    static let homeTab: UIImage = {
        let size = CGSize(width: 30, height: 30)
        return UIGraphicsImageRenderer(size: size).image { context in
            let c = context.cgContext
            c.setStrokeColor(UIColor.black.cgColor)
            c.setFillColor(UIColor.black.cgColor)
            c.setLineWidth(2.3)
            c.setLineCap(.round)
            let centre = CGPoint(x: 15, y: 15)
            c.fillEllipse(in: CGRect(x: 15 - 2.9, y: 15 - 2.9, width: 5.8, height: 5.8))
            for radius in [7.6, 12.7] as [CGFloat] {
                for side in [CGFloat.pi, 0] {
                    c.addArc(center: centre, radius: radius, startAngle: side - .pi / 4, endAngle: side + .pi / 4, clockwise: false)
                    c.strokePath()
                }
            }
        }.withRenderingMode(.alwaysTemplate)
    }()

    /// The Settings tab glyph (3.5, drawn for the owner): a gear over two
    /// crossed wrenches, as the bones lie under the skull of a pirate flag —
    /// the open ends at the top, the ring ends at the bottom. A clear ring round
    /// the gear keeps the shapes apart.
    static let settings: UIImage = {
        let size = CGSize(width: 30, height: 30)
        return UIGraphicsImageRenderer(size: size).image { context in
            let c = context.cgContext
            c.setFillColor(UIColor.black.cgColor)
            let center = CGPoint(x: 15, y: 15)
            let diagonal = 1 / CGFloat(2).squareRoot()
            // Ends of the wrenches: (direction from the centre, distance, radius, open).
            let ends: [(CGFloat, CGFloat, CGFloat, CGFloat, Bool)] = [
                (-1, -1, 11.3, 3.4, true), (1, -1, 11.3, 3.4, true),
                (-1, 1, 11.45, 3.25, false), (1, 1, 11.45, 3.25, false),
            ]
            for (dx, dy, distance, radius, _) in ends {
                let point = CGPoint(x: center.x + dx * diagonal * distance, y: center.y + dy * diagonal * distance)
                c.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            }
            // Cut out: the open ends' jaws, the rings' holes, the ring round the gear.
            c.setBlendMode(.clear)
            for (dx, dy, distance, radius, open) in ends {
                let point = CGPoint(x: center.x + dx * diagonal * distance, y: center.y + dy * diagonal * distance)
                if open {
                    c.saveGState()
                    c.translateBy(x: point.x, y: point.y)
                    c.rotate(by: atan2(dy, dx))
                    c.fill(CGRect(x: radius - 2.9, y: -1.0, width: 4.9, height: 2.0))
                    c.restoreGState()
                } else {
                    c.fillEllipse(in: CGRect(x: point.x - 1.35, y: point.y - 1.35, width: 2.7, height: 2.7))
                }
            }
            c.fillEllipse(in: CGRect(x: center.x - 8.2, y: center.y - 8.2, width: 16.4, height: 16.4))
            c.setBlendMode(.normal)
            // The gear: ten teeth, a hole in the middle.
            let teeth = 10, inner: CGFloat = 5.6, outer: CGFloat = 7.3
            let pitch = 2 * CGFloat.pi / CGFloat(teeth)
            let gear = UIBezierPath()
            for index in 0 ..< teeth {
                let angle = CGFloat(index) * pitch - .pi / 2
                for (fraction, radius) in [(-0.31, inner), (-0.21, outer), (0.21, outer), (0.31, inner)] as [(CGFloat, CGFloat)] {
                    let point = CGPoint(x: center.x + radius * cos(angle + fraction * pitch), y: center.y + radius * sin(angle + fraction * pitch))
                    if gear.isEmpty { gear.move(to: point) } else { gear.addLine(to: point) }
                }
            }
            gear.close()
            gear.append(UIBezierPath(arcCenter: center, radius: 2.2, startAngle: 0, endAngle: 2 * .pi, clockwise: false))
            gear.usesEvenOddFillRule = true
            gear.lineWidth = 0.6
            gear.lineJoinStyle = .round
            UIColor.black.setFill()
            UIColor.black.setStroke()
            gear.fill()
            // A thin outline rounds the teeth's corners.
            gear.stroke()
        }.withRenderingMode(.alwaysTemplate)
    }()
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
        home.tabBarItem.image = MinimalIcons.homeTab
        home.tabBarItem.title = labels ? L("Главная") : nil
        home.tabBarItem.accessibilityLabel = L("Главная")
        settings.tabBarItem.image = MinimalIcons.settings.withRenderingMode(.alwaysTemplate)
        settings.tabBarItem.title = labels ? L("Настройки") : nil
        settings.tabBarItem.accessibilityLabel = L("Настройки")
        tabBar.tintColor = Theme.accent
        let custom = !(Prefs.fontFile ?? "").isEmpty
        let attributes: [NSAttributedString.Key: Any]? = custom ? [.font: Theme.fixed(10, .medium)] : nil
        for item in [home.tabBarItem, settings.tabBarItem].compactMap({ $0 }) {
            item.setTitleTextAttributes(attributes, for: .normal)
            item.setTitleTextAttributes(attributes, for: .selected)
        }
    }

    /// Settings tapped again (3.1.4): a page that is not at its top goes back to
    /// it first; one already at its top goes back one page, not to the root.
    /// 3.5.7: the way up on a quick spring; a tap while it runs counts as at the top.
    func tabBarController(_: UITabBarController, shouldSelect controller: UIViewController) -> Bool {
        // 3.5.14 (the owner): every tap on the bar, as a server or a subscription answers.
        Haptics.item()
        // Home tapped again: ours alone (3.5.8). Let through, UIKit ran its own
        // reselect on the tab (its way to the top of the first scroll view it
        // finds) against the page's spring: a frozen frame, then a jump.
        if controller === home, selectedViewController === home {
            home.reselect()
            return false
        }
        guard controller === settings, selectedViewController === settings, let page = settings.topViewController else { return true }
        if let scroll = Self.scrollView(in: page) {
            let top = -scroll.adjustedContentInset.top
            if scroll.contentOffset.y > top + 1, !scroll.isSpringingToTop {
                scroll.springToTop()
                return false
            }
        }
        if settings.viewControllers.count > 1 { settings.popViewController(animated: true) }
        return false
    }

    /// The page's own scrolling view: the view itself, or the first one in it.
    private static func scrollView(in page: UIViewController) -> UIScrollView? {
        if let scroll = page.view as? UIScrollView { return scroll }
        var queue: [UIView] = [page.view]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scroll = view as? UIScrollView, !(view is UITextView), scroll.isScrollEnabled { return scroll }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    func tabBarController(_: UITabBarController, didSelect _: UIViewController) {
        setNeedsStatusBarAppearanceUpdate()
    }

    /// Settings → «Подписки и серверы» opens the same panel as the Home capsule.
    func showServers() {
        present(MinimalServersViewController.wrapped(), animated: true)
    }
}
