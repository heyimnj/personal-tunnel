import TunnelCore
import UIKit

/// A scroll view that hands a downward drag at its top edge to the pager outside it.
final class HandoffScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            if contentOffset.y <= -adjustedContentInset.top + 0.5, velocity.y > 0, abs(velocity.y) > abs(velocity.x) { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

/// The Home tab: the connection page and, one swipe up, analytics.
final class MinimalHomeViewController: UIViewController, UIScrollViewDelegate, UINavigationControllerDelegate {
    private let pager = UIScrollView()
    private let connection = MinimalConnectionView()
    private let analytics = MinimalAnalyticsViewController()
    private lazy var analyticsNavigation = UINavigationController(rootViewController: analytics)
    private let dots = [UIView(), UIView()]
    private var page = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        pager.isPagingEnabled = true
        pager.showsVerticalScrollIndicator = false
        pager.contentInsetAdjustmentBehavior = .never
        pager.delegate = self
        pager.bounces = false
        pager.delaysContentTouches = false
        view.addSubview(pager)
        pager.addSubview(connection)
        analyticsNavigation.delegate = self
        analyticsNavigation.setNavigationBarHidden(true, animated: false)
        addChild(analyticsNavigation)
        pager.addSubview(analyticsNavigation.view)
        analyticsNavigation.didMove(toParent: self)
        connection.onChooseServer = { [weak self] in
            self?.present(MinimalServersViewController.wrapped(), animated: true)
        }
        for (index, dot) in dots.enumerated() {
            dot.layer.cornerRadius = 3
            let control = TapControl()
            control.addSubview(dot)
            control.onTap = { [weak self] in self?.go(to: index, animated: true) }
            control.tag = index
            view.addSubview(control)
        }
        updateDots()
        Prefs.appearanceChanged.observe(self) { [weak self] in
            self?.view.backgroundColor = Theme.background
            self?.updateDots()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard pager.frame.size != size else { layoutDots(); return }
        pager.frame = view.bounds
        pager.contentSize = CGSize(width: size.width, height: size.height * 2)
        connection.frame = CGRect(origin: .zero, size: size)
        analyticsNavigation.view.frame = CGRect(x: 0, y: size.height, width: size.width, height: size.height)
        pager.contentOffset = CGPoint(x: 0, y: CGFloat(page) * size.height)
        layoutDots()
    }

    private func layoutDots() {
        let bottom = view.bounds.height - view.safeAreaInsets.bottom - 8
        for control in view.subviews.compactMap({ $0 as? TapControl }) where control.subviews.first.map({ dots.contains($0) }) == true {
            control.frame = CGRect(x: view.bounds.width - 42, y: bottom - CGFloat(2 - control.tag) * 26, width: 22, height: 22)
            control.subviews.first?.frame = CGRect(x: 8, y: 8, width: 6, height: 6)
        }
    }

    private func updateDots() {
        for (index, dot) in dots.enumerated() {
            dot.backgroundColor = index == page ? (Prefs.accentDots ? Theme.accent : .label) : UIColor.secondaryLabel.withAlphaComponent(0.5)
        }
    }

    private func go(to next: Int, animated: Bool) {
        guard pager.bounds.height > 0 else { return }
        if animated {
            UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.pager.contentOffset = CGPoint(x: 0, y: CGFloat(next) * self.pager.bounds.height)
            }
        } else {
            pager.contentOffset = CGPoint(x: 0, y: CGFloat(next) * pager.bounds.height)
        }
        setPage(next)
    }

    private func setPage(_ next: Int) {
        guard next != page else { return }
        page = next
        updateDots()
        analytics.setVisible(next == 1)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pager, pager.bounds.height > 0, pager.isDragging || pager.isDecelerating else { return }
        setPage(pager.contentOffset.y > pager.bounds.height / 2 ? 1 : 0)
    }

    /// Tapping Home again: close an open analytics child page, then scroll
    /// analytics to the top, then return to the connection page.
    func reselect() {
        if analyticsNavigation.viewControllers.count > 1 {
            analyticsNavigation.popToRootViewController(animated: true)
        } else if page == 1, !analytics.isAtTop {
            analytics.scrollToTop()
        } else if page == 1 {
            go(to: 0, animated: true)
        }
    }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        let isRoot = viewController === analytics
        pager.isScrollEnabled = isRoot
        navigationController.setNavigationBarHidden(isRoot, animated: animated)
        for control in view.subviews.compactMap({ $0 as? TapControl }) { control.isHidden = !isRoot }
    }
}

/// Big round power button, state line and the server capsule.
final class MinimalConnectionView: UIView {
    var onChooseServer: (() -> Void)?
    private let button = TapControl()
    private let buttonGlass = GlassView(opacityKey: Prefs.buttonOpacityKey)
    private let power = UIImageView(image: UIImage(systemName: "power", withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)))
    private let dot = UIView()
    private let status = UILabel(font: Theme.font(20, .semibold), color: .secondaryLabel)
    private let capsule = TapControl()
    private let capsuleGlass = GlassView(opacityKey: Prefs.serverOpacityKey)
    private let flag = UILabel(font: .systemFont(ofSize: 24))
    private let globe = UIImageView(image: UIImage(systemName: "globe"))
    private let name = UILabel(font: Theme.font(20))
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.pressScale = 0.96
        button.addSubview(buttonGlass)
        buttonGlass.isUserInteractionEnabled = false
        buttonGlass.pin(to: button)
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.06
        button.layer.shadowRadius = 14
        button.layer.shadowOffset = CGSize(width: 0, height: 6)
        power.tintColor = .label
        dot.layer.cornerRadius = 2.5
        for view in [power, dot] as [UIView] {
            view.isUserInteractionEnabled = false
            view.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(view)
        }
        button.accessibilityLabel = "Подключение"
        button.onTap = { App.shared.toggleConnection() }
        status.textAlignment = .center

        capsule.pressScale = 0.985
        capsule.addSubview(capsuleGlass)
        capsuleGlass.isUserInteractionEnabled = false
        capsuleGlass.pin(to: capsule)
        globe.tintColor = .label
        chevron.tintColor = .secondaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(.horizontal, spacing: 12, alignment: .center, [flag, globe, name, UIView(), chevron])
        row.isUserInteractionEnabled = false
        capsule.addSubview(row)
        row.pin(to: capsule, insets: UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20))
        capsule.onTap = { [weak self] in Haptics.tap(); self?.onChooseServer?() }

        for view in [button, status, capsule] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            NSLayoutConstraint(item: button, attribute: .centerY, relatedBy: .equal, toItem: self, attribute: .centerY, multiplier: 0.786, constant: 0),
            button.widthAnchor.constraint(equalToConstant: 142), button.heightAnchor.constraint(equalToConstant: 142),
            power.centerXAnchor.constraint(equalTo: button.centerXAnchor), power.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            dot.centerXAnchor.constraint(equalTo: button.centerXAnchor), dot.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: 45),
            dot.widthAnchor.constraint(equalToConstant: 5), dot.heightAnchor.constraint(equalToConstant: 5),
            status.centerXAnchor.constraint(equalTo: centerXAnchor), status.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 18),
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), capsule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            capsule.heightAnchor.constraint(equalToConstant: 56),
            NSLayoutConstraint(item: capsule, attribute: .centerY, relatedBy: .equal, toItem: self, attribute: .centerY, multiplier: 1.312, constant: 0),
        ])
        App.shared.tunnel.state.observe(self) { [weak self] in self?.show($0) }
        App.shared.store.library.observe(self) { [weak self] _ in self?.showServer() }
        Prefs.appearanceChanged.observe(self) { [weak self] in
            self?.status.font = Theme.font(20, .semibold)
            self?.name.font = Theme.font(20)
            self?.name.textColor = Theme.text
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        button.layer.shadowPath = UIBezierPath(ovalIn: button.bounds).cgPath
    }

    private func show(_ state: TunnelState) {
        switch state {
        case .connected: status.text = "Подключено"; dot.backgroundColor = Theme.connected
        case .connecting: status.text = "Подключение…"; dot.backgroundColor = .systemYellow
        case .disconnecting: status.text = "Отключение…"; dot.backgroundColor = .systemYellow
        case .reasserting: status.text = "Смена сервера…"; dot.backgroundColor = .systemYellow
        case .disconnected: status.text = "Не подключено"; dot.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.6)
        }
        button.accessibilityValue = status.text
    }

    private func showServer() {
        let library = App.shared.library
        guard let subscription = library.activeSubscription, let node = library.activeNode else {
            name.text = "Выбрать сервер"
            flag.isHidden = true
            globe.isHidden = false
            return
        }
        let label = App.shared.store.label(of: node, in: subscription)
        name.text = Prefs.autoSelect ? "Автовыбор" : label.text
        let emoji = Theme.flag(label.countryCode)
        flag.text = emoji
        flag.isHidden = emoji == nil
        globe.isHidden = emoji != nil
    }
}
