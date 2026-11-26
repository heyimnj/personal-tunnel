import UIKit

/// PTLab 2.0: a small flask at the left edge of the app's window opens the
/// screen of variants (`LabHomeViewController`) as a sheet. Drag it up or down
/// to get it out of the way.
enum LabOverlay {
    static func install(in window: UIWindow) {
        let button = LabFlaskButton(frame: CGRect(x: 0, y: window.bounds.height * 0.42, width: 34, height: 44))
        button.autoresizingMask = [.flexibleTopMargin, .flexibleBottomMargin, .flexibleRightMargin]
        button.addAction(UIAction { [weak window] _ in
            guard let top = window?.rootViewController?.topmost else { return }
            let lab = LabHomeViewController()
            lab.modalPresentationStyle = .pageSheet
            top.present(lab, animated: true)
        }, for: .touchUpInside)
        window.addSubview(button)
    }
}

private final class LabFlaskButton: UIControl {
    private let plate = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let icon = UIImageView(image: UIImage(systemName: "testtube.2", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)))
    private var dragStart: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        plate.isUserInteractionEnabled = false
        plate.clipsToBounds = true
        plate.layer.cornerRadius = 14
        plate.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        icon.tintColor = .systemPurple
        icon.contentMode = .center
        icon.isUserInteractionEnabled = false
        addSubview(plate)
        addSubview(icon)
        accessibilityLabel = "PTLab"
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        addGestureRecognizer(drag)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        plate.frame = bounds
        icon.frame = bounds
        superview?.bringSubviewToFront(self)
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        guard let host = superview else { return }
        if gesture.state == .began { dragStart = center.y }
        let y = dragStart + gesture.translation(in: host).y
        let margin = host.safeAreaInsets.top + bounds.height
        center.y = min(max(y, margin), host.bounds.height - host.safeAreaInsets.bottom - bounds.height)
    }
}

private extension UIViewController {
    /// The controller on top of everything presented from this one.
    var topmost: UIViewController {
        var top = self
        while let next = top.presentedViewController { top = next }
        return top
    }
}
