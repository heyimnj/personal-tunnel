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
    private var dotControls: [TapControl] = []
    private var page = 0
    /// A programmatic page change is running its spring.
    private var animatingPage = false
    private var hideDots: DispatchWorkItem?

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
            dot.isUserInteractionEnabled = false
            let control = TapControl()
            control.addSubview(dot)
            control.onTap = { [weak self] in self?.go(to: index, animated: true) }
            control.accessibilityLabel = index == 0 ? "Подключение" : "Аналитика"
            // As in 1.5.0 the dots show only while the page moves.
            control.alpha = 0
            control.isUserInteractionEnabled = false
            view.addSubview(control)
            dotControls.append(control)
        }
        updateDots()
        Prefs.appearanceChanged.observe(self) { [weak self] in
            self?.view.backgroundColor = Theme.background
            self?.updateDots()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        connection.safeInsets = view.safeAreaInsets
        let size = view.bounds.size
        if pager.frame.size != size {
            pager.frame = view.bounds
            pager.contentSize = CGSize(width: size.width, height: size.height * 2)
            connection.frame = CGRect(origin: .zero, size: size)
            analyticsNavigation.view.frame = CGRect(x: 0, y: size.height, width: size.width, height: size.height)
            pager.contentOffset = CGPoint(x: 0, y: CGFloat(page) * size.height)
        }
        layoutDots()
        applyAnalyticsInsets()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        applyAnalyticsInsets()
    }

    private var pageMoving: Bool { animatingPage || pager.isDragging || pager.isDecelerating }

    /// The analytics page lives inside the pager, below the screen, so UIKit does
    /// not give it the status bar and tab bar insets of the screen. They are made
    /// up explicitly (as 1.5.0 did): only the part UIKit did not provide, and
    /// never while the page moves, so nothing shifts during the transition.
    private func applyAnalyticsInsets() {
        guard !pageMoving, view.window != nil else { return }
        let desired = view.safeAreaInsets
        let applied = analyticsNavigation.additionalSafeAreaInsets
        let actual = analyticsNavigation.view.safeAreaInsets
        let next = UIEdgeInsets(top: max(0, desired.top - (actual.top - applied.top)), left: 0,
                                bottom: max(0, desired.bottom - (actual.bottom - applied.bottom)), right: 0)
        guard abs(next.top - applied.top) > 0.5 || abs(next.bottom - applied.bottom) > 0.5 else { return }
        analyticsNavigation.additionalSafeAreaInsets = next
    }

    /// 1.5.0 `ModernPagerDots`: two 6 pt dots in 22 pt targets, 4 pt apart,
    /// 20 pt from the trailing edge and from the bottom of the safe area.
    private func layoutDots() {
        let last = view.bounds.height - view.safeAreaInsets.bottom - 20
        for (index, control) in dotControls.enumerated() {
            let y = last - 22 - CGFloat(1 - index) * 26
            control.frame = CGRect(x: view.bounds.width - 20 - 22, y: y, width: 22, height: 22)
            control.subviews.first?.frame = CGRect(x: 8, y: 8, width: 6, height: 6)
        }
    }

    /// Shows the dots at once when a page change starts.
    private func showDots() {
        hideDots?.cancel()
        hideDots = nil
        guard dotControls.first?.alpha != 1 else { return }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.14, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            for control in self.dotControls { control.alpha = 1 }
        }
        for control in dotControls { control.isUserInteractionEnabled = true }
    }

    /// Fades them out a second after the page has settled.
    private func scheduleHideDots() {
        hideDots?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pageMoving else { return }
            for control in self.dotControls { control.isUserInteractionEnabled = false }
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.14, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                for control in self.dotControls { control.alpha = 0 }
            }
        }
        hideDots = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func settled() {
        applyAnalyticsInsets()
        applyVisibility()
        scheduleHideDots()
    }

    private func updateDots() {
        for (index, dot) in dots.enumerated() {
            dot.backgroundColor = index == page ? (Prefs.accentDots ? Theme.accent : .label) : UIColor.secondaryLabel.withAlphaComponent(0.5)
        }
    }

    private func go(to next: Int, animated: Bool) {
        guard pager.bounds.height > 0 else { return }
        if animated {
            animatingPage = true
            showDots()
            UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.pager.contentOffset = CGPoint(x: 0, y: CGFloat(next) * self.pager.bounds.height)
            } completion: { _ in
                self.animatingPage = false
                self.settled()
            }
        } else {
            pager.contentOffset = CGPoint(x: 0, y: CGFloat(next) * pager.bounds.height)
        }
        setPage(next)
    }

    /// During a page change only the dots follow; the analytics streams and timer
    /// switch when the page has settled, so the core's reconnect and the first
    /// redraws never land in the middle of the motion.
    private func setPage(_ next: Int) {
        guard next != page else { return }
        page = next
        updateDots()
        if !pageMoving { applyVisibility() }
    }

    private var analyticsShown = false

    private func applyVisibility() {
        let visible = page == 1
        guard visible != analyticsShown else { return }
        analyticsShown = visible
        analytics.setVisible(visible)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === pager else { return }
        showDots()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === pager, !decelerate else { return }
        settled()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === pager else { return }
        settled()
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
        for control in dotControls { control.isHidden = !isRoot }
    }
}

/// Big round power button, state line and the server capsule, as 1.5.0's
/// `AnywhereConnectionView`: glass controls, centred on the screen.
final class MinimalConnectionView: UIView {
    var onChooseServer: (() -> Void)?
    /// Safe area of the page (status bar, tab bar).
    var safeInsets: UIEdgeInsets = .zero {
        didSet { if safeInsets != oldValue { setNeedsLayout() } }
    }

    private let button = TapControl()
    private let buttonGlass = ControlGlassView(circle: true, opacityKey: Prefs.buttonOpacityKey)
    private let power = UIImageView(image: UIImage(systemName: "power", withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)))
    private let dot = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let status = UILabel(font: Theme.font(.headline), color: .secondaryLabel)
    private lazy var statusRow = UIStackView(.horizontal, spacing: 8, alignment: .center, [spinner, status])
    private let capsule = TapControl()
    private let capsuleGlass = ControlGlassView(circle: false, opacityKey: Prefs.serverOpacityKey)
    private let flag = UILabel(font: .systemFont(ofSize: 21))
    private let mark = UIImageView(image: MinimalIcons.home)
    private let name = UILabel(font: Theme.font(17, .medium))
    private let chevron = UIImageView()
    private lazy var capsuleRow = UIStackView(.horizontal, spacing: 8, alignment: .center, [flag, mark, name, UIView(), chevron])

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.ripple = true
        button.addSubview(buttonGlass)
        power.tintColor = .label
        power.contentMode = .scaleAspectFit
        dot.layer.cornerRadius = 2.5
        for view in [power, dot] as [UIView] {
            view.isUserInteractionEnabled = false
            button.addSubview(view)
        }
        button.accessibilityLabel = "Подключение"
        button.onTap = { [weak self] in
            // Without a subscription the button leads to the server panel, as in 1.5.0.
            if App.shared.library.activeSubscription == nil { self?.onChooseServer?() } else { App.shared.toggleConnection() }
        }
        spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        spinner.hidesWhenStopped = true
        status.textAlignment = .center

        capsule.ripple = true
        capsule.addSubview(capsuleGlass)
        mark.tintColor = .label
        mark.contentMode = .scaleAspectFit
        flag.textAlignment = .center
        for view in [flag, mark] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: 26), view.heightAnchor.constraint(equalToConstant: 26)])
        }
        name.lineBreakMode = .byTruncatingTail
        chevron.tintColor = UIColor.label.withAlphaComponent(0.7)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        capsuleRow.isUserInteractionEnabled = false
        capsule.addSubview(capsuleRow)
        capsule.onTap = { [weak self] in Haptics.tap(); self?.onChooseServer?() }

        for view in [button, statusRow, capsule] as [UIView] { addSubview(view) }
        restyle()
        App.shared.tunnel.state.observe(self) { [weak self] in self?.show($0) }
        App.shared.store.library.observe(self) { [weak self] _ in self?.showServer() }
        Prefs.appearanceChanged.observe(self) { [weak self] in
            self?.restyle()
            self?.showServer()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func restyle() {
        status.font = Theme.font(.headline)
        name.font = Theme.font(17, .medium)
        name.textColor = Theme.text
        chevron.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(font: Theme.font(12, .semibold)))
        setNeedsLayout()
    }

    /// 1.5.0 `AnywhereControlLayout`: the group and the capsule, `12 %` of the height
    /// apart (20…100 pt), centred on the screen and kept inside the safe area.
    override func layoutSubviews() {
        super.layoutSubviews()
        let side: CGFloat = 140
        let statusSize = statusRow.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let groupHeight = side + 20 + statusSize.height
        let capsuleWidth = min(bounds.width - 32, 500)
        let capsuleHeight = 16 + max(26, ceil(name.font.lineHeight)) + 16
        let area = bounds.inset(by: safeInsets)
        let room = area.height - groupHeight - capsuleHeight
        let ideal = min(max(area.height * 0.12, 20), 100)
        let spacing = max(min(ideal, room), 20)
        let contentHeight = groupHeight + spacing + capsuleHeight
        let top = max(area.minY, min(bounds.midY - contentHeight / 2, area.maxY - contentHeight))

        button.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        button.center = CGPoint(x: bounds.midX, y: top + side / 2)
        buttonGlass.frame = button.bounds
        let glyph = power.image?.size ?? CGSize(width: 1, height: 1)
        let glyphWidth = 40 * glyph.width / max(glyph.height, 1)
        power.frame = CGRect(x: (side - glyphWidth) / 2, y: (side - 40) / 2, width: glyphWidth, height: 40)
        dot.frame = CGRect(x: side / 2 - 2.5, y: side / 2 + 45 - 2.5, width: 5, height: 5)
        statusRow.frame = CGRect(x: bounds.midX - statusSize.width / 2, y: top + side + 20, width: statusSize.width, height: statusSize.height)
        // bounds and center, never frame: the press scales the capsule, and a frame
        // set under a transform moved it (the jump on tap).
        capsule.bounds = CGRect(x: 0, y: 0, width: capsuleWidth, height: capsuleHeight)
        capsule.center = CGPoint(x: bounds.midX, y: top + groupHeight + spacing + capsuleHeight / 2)
        capsuleGlass.frame = capsule.bounds
        capsuleRow.frame = capsule.bounds.insetBy(dx: 16, dy: 16)
    }

    private func show(_ state: TunnelState) {
        switch state {
        case .connected: status.text = "Подключено"; dot.backgroundColor = Theme.connected
        case .connecting: status.text = "Подключение…"; dot.backgroundColor = .systemOrange
        case .disconnecting: status.text = "Отключение…"; dot.backgroundColor = .systemOrange
        case .reasserting: status.text = "Смена сервера…"; dot.backgroundColor = .systemOrange
        case .disconnected: status.text = "Не подключено"; dot.backgroundColor = UIColor.systemGray.withAlphaComponent(0.8)
        }
        if state.isBusy { spinner.startAnimating() } else { spinner.stopAnimating() }
        button.accessibilityLabel = state.isOn ? "Отключить" : "Подключить"
        button.accessibilityValue = status.text
        setNeedsLayout()
    }

    private func showServer() {
        let library = App.shared.library
        guard let subscription = library.activeSubscription, let node = library.activeNode else {
            name.text = "Выбрать сервер"
            flag.isHidden = true
            mark.isHidden = false
            mark.image = UIImage(systemName: "plus.circle.fill")
            mark.tintColor = Theme.accent
            return
        }
        let label = App.shared.store.label(of: node, in: subscription)
        name.text = Prefs.autoSelect ? "Автовыбор" : label.text
        let emoji = Theme.flag(label.countryCode)
        flag.text = emoji
        flag.isHidden = emoji == nil
        // No flag: the app's mark, as 1.5.0's home capsule showed it.
        mark.isHidden = emoji != nil
        mark.image = MinimalIcons.home
        mark.tintColor = .label
    }
}
