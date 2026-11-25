import TunnelCore
import UIKit

/// A scroll view that hands a downward drag at its top edge to the pager outside it.
final class HandoffScrollView: UIScrollView {
    /// While this list is dragged and already at its top, how far the finger pulls
    /// past the top (points, 0 when back). The list holds still; the page follows.
    var onPull: ((CGFloat) -> Void)?
    /// The pull ended; the finger's speed in points per second (positive downwards).
    var onPullEnd: ((CGFloat) -> Void)?
    /// 3.5: whether the list may take a drag now. While the page is still moving
    /// (or heading back to the connection page) a swipe belongs to the pager: the
    /// list used to take it, scrolled to its end, and the page swipe was lost.
    /// 3.5.7: told which way the finger goes (`upward`: into the list).
    var acceptsDrag: ((_ upward: Bool) -> Bool)?
    private var anchor: CGFloat?
    /// How far past its top the list stood when the pull began (a drag that
    /// caught it in the bounce after a flick); the pull starts from there.
    private var base: CGFloat = 0
    private var pulling = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        panGestureRecognizer.addTarget(self, action: #selector(tracked(_:)))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    /// The hand-off inside the drag itself. A touch that lands while the list is
    /// still settling is given to the list by iOS (to stop it); so once the list
    /// is at its top, pulling further moves the page instead, whoever got the touch.
    ///
    /// 3.0.5: a drag that catches the list in its bounce past the top keeps it
    /// (see gestureRecognizerShouldBegin), and the page starts as far down as the
    /// bounce showed: the list returns to its top and the page moves down by the
    /// same amount in the same frame, so nothing on screen moves. 3.0.4 gave such
    /// a drag to the pager, which started from its own resting place a moment
    /// later: the screen jumped about 30 pt up and then slid down under the finger.
    @objc private func tracked(_ pan: UIPanGestureRecognizer) {
        guard onPull != nil else { return }
        let top = -adjustedContentInset.top
        let translation = pan.translation(in: self).y
        switch pan.state {
        case .began, .changed:
            if anchor == nil, contentOffset.y <= top + 1 { anchor = translation }
            guard var start = anchor else { return }
            if !pulling {
                guard translation > start else {
                    // A drag up (in the bounce or not) stays the list's own.
                    if contentOffset.y > top + 1 { anchor = nil }
                    return
                }
                // From here the page follows the finger. When the list stands past
                // its top (the bounce this drag caught, or its own stretch), the
                // page starts as far down as the list shows.
                pulling = true
                base = max(0, top - contentOffset.y)
                if base > 0.5 {
                    start = translation
                    anchor = start
                }
            }
            let pull = base + translation - start
            if pull > 0 {
                if contentOffset.y != top { contentOffset.y = top }
                onPull?(pull)
            } else {
                pulling = false
                onPull?(0)
                anchor = nil
                base = 0
            }
        case .ended, .cancelled, .failed:
            if pulling {
                // No bounce of the list: the page takes the motion from here.
                setContentOffset(CGPoint(x: contentOffset.x, y: top), animated: false)
                onPullEnd?(pan.velocity(in: self).y)
            }
            pulling = false
            anchor = nil
            base = 0
        default:
            break
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            if let acceptsDrag {
                let velocity = panGestureRecognizer.velocity(in: self).y
                let motion = velocity != 0 ? velocity : panGestureRecognizer.translation(in: self).y
                if !acceptsDrag(motion < 0) { return false }
            }
            let top = -adjustedContentInset.top
            let velocity = panGestureRecognizer.velocity(in: self)
            let downward = velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
            // Resting at the top edge, a pull down belongs to the page's own drag.
            // In the bounce past the top the list keeps it: `tracked` hands the
            // motion to the page from exactly where the content shows. A drag up
            // stays with the list, bounce or not.
            if contentOffset.y <= top + 1, downward, top - contentOffset.y <= 0.5 {
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
final class MinimalHomeViewController: UIViewController, UIScrollViewDelegate, UINavigationControllerDelegate, UIGestureRecognizerDelegate {
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

    /// 3.5: the owner's own colours behind both pages (`Wallpaper`).
    private var wallpaper: UIImageView?

    override func viewDidLoad() {
        super.viewDidLoad()
        Wallpaper.apply(to: view, holder: &wallpaper)
        // 3.5: the connection events come while Home is up, so analytics has its
        // data the first time it is opened (they are prepared off the main thread
        // and drawn only while the page shows).
        App.shared.core.setConnectionsStreamed(true)
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
        let press = UILongPressGestureRecognizer(target: self, action: #selector(touchDown(_:)))
        press.minimumPressDuration = 0
        press.cancelsTouchesInView = false
        press.delaysTouchesBegan = false
        press.delaysTouchesEnded = false
        press.delegate = self
        pager.addGestureRecognizer(press)
        view.addSubview(pager)
        pager.addSubview(connection)
        analyticsNavigation.delegate = self
        analyticsNavigation.setNavigationBarHidden(true, animated: false)
        // The wallpaper shows through analytics too.
        analyticsNavigation.view.backgroundColor = .clear
        addChild(analyticsNavigation)
        pager.addSubview(analyticsNavigation.view)
        analyticsNavigation.didMove(toParent: self)
        analytics.onPull = { [weak self] pull in self?.pullPage(pull) }
        analytics.onPullEnd = { [weak self] velocity in self?.releasePage(velocity) }
        analytics.acceptsDrag = { [weak self] upward in self?.analyticsTakesDrag(upward: upward) ?? true }
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
            guard let self else { return }
            Wallpaper.apply(to: self.view, holder: &self.wallpaper)
            self.updateDots()
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

    /// The analytics list takes a drag only once its page is (nearly) in place
    /// and staying: a swipe while the page still moves, or while it heads back to
    /// the connection page, goes to the pager, which catches the page mid-way.
    ///
    /// 3.5.7 (the owner: after a quick swipe up from Home the page stopped dead
    /// at the top of analytics and the list did not move until the finger was
    /// lifted — the pager, already at its end, took the next swipe up): while the
    /// page still rises to analytics, a swipe up is the list's and scrolls on with
    /// its own momentum, as before 3.5; the page finishes its way meanwhile.
    private func analyticsTakesDrag(upward: Bool) -> Bool {
        let height = pager.bounds.height
        guard height > 0 else { return true }
        if pullingPage || pager.isDragging { return false }
        guard page == 1 else { return false }
        return upward || pager.contentOffset.y >= height * 0.92
    }

    private var pageMoving: Bool { animatingPage || pullingPage || pager.isDragging || pager.isDecelerating }
    /// The page follows a pull handed over by the analytics list.
    private var pullingPage = false

    private func pullPage(_ pull: CGFloat) {
        let height = pager.bounds.height
        guard height > 0 else { return }
        stopPageAnimator()
        if pageSpring.isRunning {
            pageSpring.stop()
            animatingPage = false
        }
        // The finger went back up past where the pull began: the list scrolls again,
        // and the page is settled (3.0.4 stayed «pulling» here until the next pull,
        // so the dots never faded and the page's insets were not applied).
        if pull <= 0 {
            guard pullingPage else { return }
            pullingPage = false
            pager.contentOffset = CGPoint(x: 0, y: height)
            setPage(1)
            settled()
            return
        }
        if !pullingPage {
            pullingPage = true
            showDots()
        }
        pager.contentOffset = CGPoint(x: 0, y: max(0, height - pull))
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
        // The page stands: analytics may draw again (before it is told it shows).
        moveEnded()
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
    /// `byTap`: the tab's tap (see animatePage).
    private func go(to next: Int, animated: Bool, velocity: CGFloat = 0, feel: SpringDriver.Feel = .page, byTap: Bool = false) {
        guard pager.bounds.height > 0 else { return }
        // A Core Animation move still running stops where it shows; whatever comes
        // next starts from there.
        stopPageAnimator()
        // 3.5: leaving analytics, a fling of its list stops where it is (it ran on
        // to the end of the page under the moving page).
        if next == 0 { analytics.stopScrolling() }
        let target = CGFloat(next) * pager.bounds.height
        if animated, !UIAccessibility.isReduceMotionEnabled {
            animatingPage = true
            showDots()
            // A flick may be faster than the page can take without looking thrown.
            // 3.5.7: a page already moving keeps its speed into the new spring (a
            // second tap on the tab restarted it from rest).
            let carried = velocity == 0 && pageSpring.isRunning ? pageSpring.velocity : velocity
            let speed = max(-6000, min(6000, carried))
            let done: () -> Void = { [weak self] in
                guard let self else { return }
                self.animatingPage = false
                self.settled()
            }
            if byTap, carried == 0 {
                pageSpring.stop()
                animatePage(to: target, completion: done)
            } else {
                pageSpring.run(from: pager.contentOffset.y, to: target, velocity: speed, feel: feel, completion: done)
            }
        } else {
            pageSpring.stop()
            animatingPage = false
            pager.contentOffset = CGPoint(x: 0, y: target)
        }
        setPage(next)
    }

    /// 3.5.9 (the owner: the tab's way to Home still stuttered; the recording lost
    /// frames all through the page's move, while the list's own way up beside it
    /// ran clean): a move set off by a tap is a Core Animation spring, run by the
    /// render server, so no busy moment of the app's main thread can drop its
    /// frames. A finger stops it where it shows (`touchDown`); swipes keep the
    /// per-frame spring, which carries the finger's speed.
    private var pageAnimator: UIViewPropertyAnimator?

    private func animatePage(to target: CGFloat, completion: @escaping () -> Void) {
        let distance = target - pager.contentOffset.y
        guard abs(distance) > 0.5 else {
            pager.contentOffset = CGPoint(x: 0, y: target)
            completion()
            return
        }
        // Under way from the first frame, settling without a bounce.
        // 3.5.12 (the owner: too fast, it seemed to stutter): longer and gentler at its start.
        let timing = UISpringTimingParameters(dampingRatio: 1, initialVelocity: CGVector(dx: 0, dy: 0.6))
        let animator = UIViewPropertyAnimator(duration: 0.58, timingParameters: timing)
        animator.addAnimations { [weak self] in
            self?.pager.contentOffset = CGPoint(x: 0, y: target)
        }
        animator.addCompletion { [weak self, weak animator] _ in
            guard let self, let animator, self.pageAnimator === animator else { return }
            self.pageAnimator = nil
            completion()
        }
        pageAnimator = animator
        animator.startAnimation()
    }

    /// Ends a Core Animation move where it shows (no completion: whoever stops it goes on).
    private func stopPageAnimator() {
        guard let animator = pageAnimator else { return }
        pageAnimator = nil
        animator.stopAnimation(true)
        animatingPage = false
    }

    /// A finger came down anywhere on the pages: a tap's move stops under it
    /// before any drag reads the page's place.
    @objc private func touchDown(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began:
            if page == 0 { analytics.aboutToShow() }
            guard pageAnimator != nil else { return }
            stopPageAnimator()
            caughtPage = true
        case .ended, .cancelled, .failed:
            guard caughtPage else { return }
            caughtPage = false
            // A finger that held the page and let go without a swipe: the page goes
            // on to where it was heading (a swipe settles it itself).
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.pageMoving, !self.pageSpring.isRunning, self.pageAnimator == nil else { return }
                let height = self.pager.bounds.height
                guard height > 0 else { return }
                if abs(self.pager.contentOffset.y - CGFloat(self.page) * height) > 0.5 {
                    self.go(to: self.page, animated: true)
                } else {
                    self.settled()
                }
            }
        default:
            break
        }
    }

    private var caughtPage = false

    // MARK: 3.5.10 — a page change: analytics holds still, and the frames are counted

    private var meter: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var frames = 0
    private var dropped = 0
    private var longest: CFTimeInterval = 0

    /// The page began to move: analytics stops updating until it stands still,
    /// and every frame of the move is timed (for the service log).
    private func moveStarted() {
        guard meter == nil else { return }
        analytics.moving = true
        analytics.resetCounters()
        frames = 0
        dropped = 0
        longest = 0
        lastFrame = 0
        let link = CADisplayLink(target: FrameMeterProxy(self), selector: #selector(FrameMeterProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        meter = link
    }

    fileprivate func meterTick(_ link: CADisplayLink) {
        let expected = max(1.0 / 120, link.targetTimestamp - link.timestamp)
        if lastFrame > 0 {
            let gap = link.timestamp - lastFrame
            frames += 1
            longest = max(longest, gap)
            if gap > expected * 1.5 { dropped += max(1, Int((gap / expected).rounded()) - 1) }
        }
        lastFrame = link.timestamp
        if !pageMoving { moveEnded() }
    }

    private func moveEnded() {
        guard let link = meter else { return }
        link.invalidate()
        meter = nil
        analytics.moving = false
        let ms = { (seconds: CFTimeInterval) in String(format: "%.0f", seconds * 1000) }
        let text = Lf("Переход страницы: кадров %@, пропущено %@, самый долгий %@ мс; раскладок аналитики %@, её обновлений %@ (%@ мс).",
                      "\(frames)", "\(dropped)", ms(longest), "\(analytics.layoutPasses)", "\(analytics.updates)", ms(analytics.updateTime))
        // Written a moment later: preparing a log line takes the main thread a
        // little, and the list may still be gliding.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { App.shared.core.note(text) }
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
        stopPageAnimator()
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
        guard scrollView === pager, !decelerate, !animatingPage, !pageSpring.isRunning, pageAnimator == nil else { return }
        // A drag that ended exactly on a page.
        if pager.contentOffset.y.truncatingRemainder(dividingBy: max(1, pager.bounds.height)) == 0 { settled() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === pager else { return }
        settled()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === pager, pageMoving { moveStarted() }
        guard scrollView === pager, pager.bounds.height > 0, pager.isDragging || pullingPage else { return }
        setPage(pager.contentOffset.y > pager.bounds.height / 2 ? 1 : 0)
    }

    /// Tapping Home again: close an open analytics child page, then scroll
    /// analytics to the top, then return to the connection page.
    ///
    /// 3.5.7: both quick (the owner: slow, and two quick taps jerked). A second
    /// tap while the list is still on its way up goes to the connection page at
    /// once; the list finishes its way up under the leaving page.
    func reselect() {
        if analyticsNavigation.viewControllers.count > 1 {
            analyticsNavigation.popToRootViewController(animated: true)
        } else if page == 1, !analytics.isAtTop, !analytics.isScrollingToTop {
            analytics.scrollToTop()
        } else if page == 1 {
            go(to: 0, animated: true, byTap: true)
        }
    }

    /// The touch-down watcher never takes a touch from anyone.
    func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool { true }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        let isRoot = viewController === analytics
        pager.isScrollEnabled = isRoot
        navigationController.setNavigationBarHidden(isRoot, animated: animated)
        for control in dotControls { control.isHidden = !isRoot }
    }
}

/// Keeps the frame meter's display link from holding Home.
private final class FrameMeterProxy: NSObject {
    weak var owner: MinimalHomeViewController?
    init(_ owner: MinimalHomeViewController) {
        self.owner = owner
        super.init()
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let owner else { link.invalidate(); return }
        owner.meterTick(link)
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
    /// 3.5: a switch of our own in place of the power symbol, and a ring round
    /// the button in place of the dot under it.
    private let power = SwitchGlyph()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let status = UILabel(font: Theme.font(.headline), color: .secondaryLabel)
    private lazy var statusRow = UIStackView(.horizontal, spacing: 8, alignment: .center, [spinner, status])
    private let capsule = TapControl()
    private let capsuleGlass = ControlGlassView(circle: false, opacityKey: Prefs.serverOpacityKey)
    private let flag = UILabel(font: .systemFont(ofSize: 21))
    private let mark = UIImageView(image: MinimalIcons.home)
    private let name = UILabel(font: Theme.font(17, .medium))
    /// 3.5 beta 2 (the owner: the capsule wanted something at its end, not the
    /// old up-and-down chevrons): the server's delay, and a small chevron up — the
    /// servers come up from below.
    private let delay = UILabel(font: UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .regular), color: .secondaryLabel)
    private let opener = UIImageView(image: UIImage(systemName: "chevron.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
    private lazy var capsuleRow = UIStackView(.horizontal, spacing: 8, alignment: .center, [flag, mark, name, UIView(), delay, opener])

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.ripple = true
        button.addSubview(buttonGlass)
        for view in [power] as [UIView] {
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
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        delay.setContentHuggingPriority(.required, for: .horizontal)
        delay.setContentCompressionResistancePriority(.required, for: .horizontal)
        opener.tintColor = .tertiaryLabel
        opener.contentMode = .center
        opener.setContentHuggingPriority(.required, for: .horizontal)
        capsuleRow.setCustomSpacing(10, after: delay)
        capsuleRow.isUserInteractionEnabled = false
        capsule.addSubview(capsuleRow)
        capsule.onTap = { [weak self] in Haptics.tap(); self?.onChooseServer?() }

        for view in [button, statusRow, capsule] as [UIView] { addSubview(view) }
        restyle()
        App.shared.tunnel.state.observe(self) { [weak self] in self?.show($0) }
        App.shared.health.state.observe(self, fireNow: false) { [weak self] _ in self?.showRing(animated: true) }
        App.shared.store.library.observe(self) { [weak self] _ in self?.showServer() }
        App.shared.latency.changed.observe(self, fireNow: false) { [weak self] _ in self?.showDelay() }
        // 3.5 beta 4 (the owner): the chevron points down while the servers are open.
        MinimalServersViewController.shown.observe(self) { [weak self] open in self?.pointOpener(down: open) }
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
        let glyph = SwitchGlyph.size
        power.frame = CGRect(x: (side - glyph.width) / 2, y: (side - glyph.height) / 2, width: glyph.width, height: glyph.height)
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
        case .connected: status.text = L("Подключено")
        case .connecting: status.text = L("Подключение…")
        case .disconnecting: status.text = L("Отключение…")
        case .reasserting: status.text = L("Смена сервера…")
        case .disconnected: status.text = L("Не подключено")
        }
        // The switch is on from the moment the tunnel is asked to come up.
        power.set(on: state == .connecting || state.isOn, animated: window != nil)
        showRing(animated: window != nil)
        if state.isBusy { spinner.startAnimating() } else { spinner.stopAnimating() }
        button.accessibilityLabel = state.isOn ? L("Отключить") : L("Подключить")
        button.accessibilityValue = status.text
        setNeedsLayout()
    }

    private func showRing(animated: Bool) {
        let look: SwitchGlyph.Look
        switch App.shared.tunnel.state.value {
        case .disconnected: look = .off
        case .connecting, .disconnecting, .reasserting: look = .working
        // 3.5.4 (the owner: «Подключено» stood beside a running ring for seconds):
        // green as soon as the system says connected; red only when tests through
        // the server fail (two in a row).
        case .connected:
            switch App.shared.health.state.value {
            case .unknown: look = .ok
            case .ok: look = .ok
            case .failing: look = .failing
            }
            let text = look == .failing ? L("Сервер не отвечает") : L("Подключено")
            if status.text != text {
                status.text = text
                button.accessibilityValue = text
                setNeedsLayout()
            }
        }
        power.show(look, animated: animated)
    }

    private func showServer() {
        let library = App.shared.library
        guard let subscription = library.activeSubscription, let node = library.activeNode else {
            name.text = L("Выбрать сервер")
            flag.isHidden = true
            mark.isHidden = false
            mark.image = UIImage(systemName: "plus.circle.fill")
            mark.tintColor = Theme.accent
            showDelay()
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
        showDelay()
    }

    private func pointOpener(down: Bool) {
        let turn = down ? CGAffineTransform(rotationAngle: .pi) : .identity
        guard opener.transform != turn else { return }
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else { opener.transform = turn; return }
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            // A hair off the half turn, so it turns the same way (clockwise) each time.
            self.opener.transform = down ? CGAffineTransform(rotationAngle: .pi - 0.0001) : .identity
        }
    }

    /// The chosen server's last delay; nothing until it has one.
    private func showDelay() {
        let library = App.shared.library
        var text: String?
        if !Prefs.autoSelect, let subscription = library.activeSubscription, let node = library.activeNode,
           case let .delay(value)? = App.shared.latency.entry(subscription.id, node.id)?.result {
            text = "\(value) ms"
        }
        guard delay.text != text else { return }
        delay.text = text
        delay.isHidden = text == nil
    }
}

/// The connection button's glyph: a flat power mark of two thin lines (3.5 beta 2,
/// the owner: the standing switch of beta 1 stood out too much), an open circle
/// and a stroke through its gap, in the grey of the status text.
///
/// 3.5 beta 4 (the owner): the state rides on the mark itself, not on a ring
/// round the button — the same way as the ring did: yellow while the tunnel comes
/// up or goes down (a stretch of colour runs round the circle), green when it is
/// up and traffic goes through the server (the colour closes round the circle),
/// red and breathing when the server does not answer; it fades back to grey
/// when the tunnel ends.
final class SwitchGlyph: UIView {
    enum Look: Equatable { case off, working, ok, failing }

    private let arc = CAShapeLayer()
    private let stem = CAShapeLayer()
    /// The state's colour over the circle.
    private let glow = CAShapeLayer()
    private(set) var isOn = false
    private(set) var look: Look = .off
    static let size = CGSize(width: 44, height: 44)
    private static let line: CGFloat = 2.5

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for item in [arc, glow, stem] {
            item.fillColor = nil
            item.lineWidth = Self.line
            item.lineCap = .round
            layer.addSublayer(item)
        }
        glow.strokeStart = 0
        glow.strokeEnd = 0
        glow.opacity = 0
        restyle()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { Self.size }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        restyle()
    }

    private static func color(_ look: Look) -> UIColor {
        switch look {
        case .off, .working: return .systemYellow
        case .ok: return .systemGreen
        case .failing: return .systemRed
        }
    }

    private var ink: UIColor { UIColor.secondaryLabel.resolvedColor(with: traitCollection) }

    private func restyle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.strokeColor = ink.cgColor
        stem.strokeColor = (look == .off ? ink : Self.color(look)).cgColor
        glow.strokeColor = Self.color(look).cgColor
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let center = CGPoint(x: bounds.midX, y: bounds.midY + 1)
        let radius = min(bounds.width, bounds.height) / 2 - Self.line - 1
        // The open circle: from just right of the top, clockwise to just left of it.
        let gap: CGFloat = .pi / 5
        let circle = UIBezierPath(arcCenter: center, radius: radius, startAngle: -.pi / 2 + gap, endAngle: .pi * 1.5 - gap, clockwise: true).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in [arc, glow, stem] { item.frame = bounds }
        arc.path = circle
        glow.path = circle
        let stroke = UIBezierPath()
        stroke.move(to: CGPoint(x: center.x, y: center.y - radius - 1))
        stroke.addLine(to: CGPoint(x: center.x, y: center.y - radius * 0.15))
        stem.path = stroke.cgPath
        CATransaction.commit()
    }

    /// The switch itself: kept for VoiceOver and the callers; the look shows the state.
    func set(on: Bool, animated _: Bool) {
        isOn = on
    }

    func show(_ next: Look, animated: Bool) {
        guard next != look else { return }
        let previous = look
        look = next
        let still = !animated || UIAccessibility.isReduceMotionEnabled
        func animate(_ target: CALayer, _ key: String, to value: Any, duration: CFTimeInterval, timing: CAMediaTimingFunctionName = .easeInEaseOut) {
            let from = target.presentation()?.value(forKeyPath: key) ?? target.value(forKeyPath: key)
            target.setValue(value, forKeyPath: key)
            guard !still else { return }
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from
            animation.toValue = value
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: timing)
            target.add(animation, forKey: key)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        animate(glow, "strokeColor", to: Self.color(next).cgColor, duration: 0.45)
        animate(stem, "strokeColor", to: (next == .off ? ink : Self.color(next)).cgColor, duration: 0.45)
        switch next {
        case .working:
            animate(glow, "opacity", to: Float(1), duration: 0.25)
            glow.removeAnimation(forKey: "pulse")
            startRunning()
        case .ok, .failing:
            stopRunning()
            animate(glow, "opacity", to: Float(1), duration: 0.25)
            // The running stretch closes round the circle.
            animate(glow, "strokeStart", to: CGFloat(0), duration: previous == .working ? 0.6 : 0.3, timing: .easeOut)
            animate(glow, "strokeEnd", to: CGFloat(1), duration: previous == .working ? 0.6 : 0.3, timing: .easeOut)
            if next == .failing, !still { pulse() } else { glow.removeAnimation(forKey: "pulse") }
        case .off:
            // The colour leaves the circle from its start and fades.
            stopRunning()
            glow.removeAnimation(forKey: "pulse")
            animate(glow, "strokeStart", to: CGFloat(1), duration: 0.5)
            animate(glow, "opacity", to: Float(0), duration: 0.5)
            DispatchQueue.main.asyncAfter(deadline: .now() + (still ? 0 : 0.55)) { [weak self] in
                guard let self, self.look == .off else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.glow.strokeStart = 0
                self.glow.strokeEnd = 0
                CATransaction.commit()
            }
        }
        CATransaction.commit()
    }

    /// A quarter of the circle runs round it, from the stroke's right to its left.
    private func startRunning() {
        guard glow.animation(forKey: "run") == nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.strokeStart = 0
        glow.strokeEnd = 0.28
        CATransaction.commit()
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let head = CAKeyframeAnimation(keyPath: "strokeEnd")
        head.values = [0, 0.28, 1, 1]
        head.keyTimes = [0, 0.2, 0.8, 1]
        let tail = CAKeyframeAnimation(keyPath: "strokeStart")
        tail.values = [0, 0, 0.72, 1]
        tail.keyTimes = [0, 0.2, 0.8, 1]
        let run = CAAnimationGroup()
        run.animations = [head, tail]
        run.duration = 1.2
        run.repeatCount = .infinity
        run.isRemovedOnCompletion = false
        glow.add(run, forKey: "run")
    }

    /// Stops the run where the stretch shows, so the closing starts from there.
    private func stopRunning() {
        guard glow.animation(forKey: "run") != nil else { return }
        let start = (glow.presentation()?.strokeStart) ?? 0
        let end = (glow.presentation()?.strokeEnd) ?? 0.28
        glow.removeAnimation(forKey: "run")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.strokeStart = start
        glow.strokeEnd = end
        CATransaction.commit()
    }

    /// Red breathes softly, so a hung server is noticed.
    private func pulse() {
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = 0.35
        breathe.duration = 1.1
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.beginTime = CACurrentMediaTime() + 0.6
        glow.add(breathe, forKey: "pulse")
    }

    /// The run is lost when the app leaves the screen; it starts again on return.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, look == .working { startRunning() }
    }
}
