import TunnelCore
import UIKit

/// A scroll view that hands a downward drag at its top edge to the pager outside it.
final class HandoffScrollView: UIScrollView {
    /// While this list is dragged and already at its top, how far the finger pulls
    /// past the top (points, 0 when back). The list holds still; the page follows.
    var onPull: ((CGFloat) -> Void)?
    /// The pull ended; the finger's speed in points per second (positive downwards).
    var onPullEnd: ((CGFloat) -> Void)?
    private var anchor: CGFloat?
    private var pulling = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        panGestureRecognizer.addTarget(self, action: #selector(tracked(_:)))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    /// The hand-off inside the drag itself. A touch that lands while the list is
    /// still settling is given to the list by iOS (to stop it), and the check below
    /// is never asked; so once the list is at its top, pulling further moves the
    /// page instead, whoever got the touch.
    @objc private func tracked(_ pan: UIPanGestureRecognizer) {
        guard onPull != nil else { return }
        let top = -adjustedContentInset.top
        let translation = pan.translation(in: self).y
        switch pan.state {
        case .began, .changed:
            if anchor == nil, contentOffset.y <= top + 1 { anchor = translation }
            guard let anchor else { return }
            let pull = translation - anchor
            if pull > 0 {
                pulling = true
                if contentOffset.y != top { contentOffset.y = top }
                onPull?(pull)
            } else if pulling {
                pulling = false
                onPull?(0)
                self.anchor = nil
            } else if contentOffset.y > top + 1 {
                self.anchor = nil
            }
        case .ended, .cancelled, .failed:
            if pulling {
                // No bounce of the list: the page takes the motion from here.
                setContentOffset(CGPoint(x: contentOffset.x, y: top), animated: false)
                onPullEnd?(pan.velocity(in: self).y)
            }
            pulling = false
            anchor = nil
        default:
            break
        }
    }

    /// The page took a drag while the list stood past its top (the bounce after a
    /// flick): how far past, so the page can start from there instead of the list
    /// jumping back to its top in one frame.
    var onHandOff: ((CGFloat) -> Void)?

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let top = -adjustedContentInset.top
            let velocity = panGestureRecognizer.velocity(in: self)
            let downward = velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
            // At the top edge (resting, or still in the bounce after a flick) a pull
            // down belongs to the page. A drag up stays with the list, bounce or not
            // (3.0.2 gave every drag in the bounce to the page, which cut the bounce
            // off with a jump and nudged the page).
            if contentOffset.y <= top + 1, downward {
                let past = top - contentOffset.y
                if past > 0.5 {
                    setContentOffset(CGPoint(x: contentOffset.x, y: top), animated: false)
                    onHandOff?(past)
                }
                return false
            }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

/// Reports every change of its safe area, so Home can keep the pages pushed on
/// analytics (diagnostics, the log) clear of the status bar.
final class AnalyticsNavigationController: UINavigationController {
    var onSafeAreaChange: (() -> Void)?

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        onSafeAreaChange?()
    }
}

/// The Home tab: the connection page and, one swipe up, analytics.
final class MinimalHomeViewController: UIViewController, UIScrollViewDelegate, UINavigationControllerDelegate {
    private let pager = UIScrollView()
    private let connection = MinimalConnectionView()
    private let analytics = MinimalAnalyticsViewController()
    private lazy var analyticsNavigation: AnalyticsNavigationController = {
        let navigation = AnalyticsNavigationController(rootViewController: analytics)
        // UIKit may change its part of the insets at any time; follow it at once.
        navigation.onSafeAreaChange = { [weak self] in self?.applyAnalyticsInsets() }
        return navigation
    }()
    private let dots = [UIView(), UIView()]
    private var dotControls: [TapControl] = []
    private var page = 0
    /// A programmatic page change is running its spring.
    private var animatingPage = false
    private var hideDots: DispatchWorkItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        // Paging is ours (see scrollViewWillEndDragging): the page settles with a
        // spring that carries the finger's speed, and while it does the new page
        // already takes touches, so a second swipe scrolls analytics at once
        // instead of being spent on stopping the pager's deceleration.
        pager.isPagingEnabled = false
        pager.decelerationRate = .fast
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
        analytics.onPull = { [weak self] pull in self?.pullPage(pull) }
        analytics.onHandOff = { [weak self] past in self?.handOff(past) }
        analytics.onPullEnd = { [weak self] velocity in self?.releasePage(velocity) }
        connection.onChooseServer = { [weak self] in
            self?.present(MinimalServersViewController.wrapped(), animated: true)
        }
        for (index, dot) in dots.enumerated() {
            dot.layer.cornerRadius = 3
            dot.isUserInteractionEnabled = false
            let control = TapControl()
            control.addSubview(dot)
            control.onTap = { [weak self] in self?.go(to: index, animated: true) }
            control.accessibilityLabel = index == 0 ? L("Подключение") : L("Аналитика")
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
        analytics.pageInsets = view.safeAreaInsets
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
        analytics.pageInsets = view.safeAreaInsets
        applyAnalyticsInsets()
    }

    private var pageMoving: Bool { animatingPage || pullingPage || pager.isDragging || pager.isDecelerating }
    /// The page follows a pull handed over by the analytics list.
    private var pullingPage = false

    private func pullPage(_ pull: CGFloat) {
        let height = pager.bounds.height
        guard height > 0 else { return }
        if pageSpring.isRunning {
            pageSpring.stop()
            animatingPage = false
        }
        if pull > 0, !pullingPage {
            pullingPage = true
            showDots()
        }
        pager.contentOffset = CGPoint(x: 0, y: max(0, height - pull))
    }

    /// The list gave up a drag while bouncing past its top: the page moves down by
    /// that much (what was on screen stays where it was) and its own drag carries
    /// on from there. Should no drag follow, it settles back on the page.
    private func handOff(_ past: CGFloat) {
        let height = pager.bounds.height
        guard height > 0, page == 1, !animatingPage else { return }
        pager.contentOffset = CGPoint(x: 0, y: max(0, height - past))
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.pager.isDragging, !self.pullingPage, !self.animatingPage else { return }
            self.go(to: self.page, animated: true)
        }
    }

    private func releasePage(_ velocity: CGFloat) {
        let height = pager.bounds.height
        guard pullingPage, height > 0 else { return }
        pullingPage = false
        let position = pager.contentOffset.y / height
        let next: Int
        if velocity > 300 { next = 0 } else if velocity < -300 { next = 1 } else { next = position < 0.5 ? 0 : 1 }
        // The page's offset moves against the finger.
        go(to: next, animated: true, velocity: -velocity)
    }

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

    /// The page's offset, stepped every frame (3.0.4; was a Core Animation spring,
    /// whose speed was lost when a finger caught the page mid-way and which jumped
    /// to its end value under a touch). Bounded to the two pages: no overshoot
    /// shows the wallpaper past the edge.
    private lazy var pageSpring = SpringDriver { [weak self] y in
        guard let self else { return }
        let limit = self.pager.contentSize.height - self.pager.bounds.height
        self.pager.contentOffset = CGPoint(x: 0, y: max(0, min(limit, y)))
    }

    /// `velocity`: the page offset's speed in points per second (from the finger),
    /// carried into the spring.
    private func go(to next: Int, animated: Bool, velocity: CGFloat = 0) {
        guard pager.bounds.height > 0 else { return }
        let target = CGFloat(next) * pager.bounds.height
        if animated, !UIAccessibility.isReduceMotionEnabled {
            animatingPage = true
            showDots()
            // A flick may be faster than the page can take without looking thrown.
            let speed = max(-6000, min(6000, velocity))
            pageSpring.run(from: pager.contentOffset.y, to: target, velocity: speed, feel: .page) { [weak self] in
                guard let self else { return }
                self.animatingPage = false
                self.settled()
            }
        } else {
            pageSpring.stop()
            animatingPage = false
            pager.contentOffset = CGPoint(x: 0, y: target)
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
        // Caught mid-way: the page is where it shows; the finger takes it from there.
        if pageSpring.isRunning {
            pageSpring.stop()
            animatingPage = false
        }
        showDots()
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard scrollView === pager, pager.bounds.height > 0 else { return }
        // velocity is in points per millisecond here.
        let speed = velocity.y * 1000
        let position = pager.contentOffset.y / pager.bounds.height
        let next: Int
        if speed > 300 { next = 1 } else if speed < -300 { next = 0 } else { next = position > 0.5 ? 1 : 0 }
        // No deceleration: the spring takes it from here, on the next turn (the
        // scroll view finishes its own end of drag first).
        targetContentOffset.pointee = pager.contentOffset
        DispatchQueue.main.async { self.go(to: next, animated: true, velocity: speed) }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === pager, !decelerate, !animatingPage, !pageSpring.isRunning else { return }
        // A drag that ended exactly on a page.
        if pager.contentOffset.y.truncatingRemainder(dividingBy: max(1, pager.bounds.height)) == 0 { settled() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === pager else { return }
        settled()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === pager, pager.bounds.height > 0, pager.isDragging || pullingPage else { return }
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
        button.accessibilityLabel = L("Подключение")
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
        case .connected: status.text = L("Подключено"); dot.backgroundColor = Theme.connected
        case .connecting: status.text = L("Подключение…"); dot.backgroundColor = .systemOrange
        case .disconnecting: status.text = L("Отключение…"); dot.backgroundColor = .systemOrange
        case .reasserting: status.text = L("Смена сервера…"); dot.backgroundColor = .systemOrange
        case .disconnected: status.text = L("Не подключено"); dot.backgroundColor = UIColor.systemGray.withAlphaComponent(0.8)
        }
        if state.isBusy { spinner.startAnimating() } else { spinner.stopAnimating() }
        button.accessibilityLabel = state.isOn ? L("Отключить") : L("Подключить")
        button.accessibilityValue = status.text
        setNeedsLayout()
    }

    private func showServer() {
        let library = App.shared.library
        guard let subscription = library.activeSubscription, let node = library.activeNode else {
            name.text = L("Выбрать сервер")
            flag.isHidden = true
            mark.isHidden = false
            mark.image = UIImage(systemName: "plus.circle.fill")
            mark.tintColor = Theme.accent
            return
        }
        let label = App.shared.store.label(of: node, in: subscription)
        name.text = Prefs.autoSelect ? L("Автовыбор") : label.text
        let emoji = Theme.flag(label.countryCode)
        flag.text = emoji
        flag.isHidden = emoji == nil
        // No flag: the app's mark, as 1.5.0's home capsule showed it.
        mark.isHidden = emoji != nil
        mark.image = MinimalIcons.home
        mark.tintColor = .label
    }
}
