import LocalAuthentication
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var cover: UIView?

    func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options _: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = RootViewController()
        window.overrideUserInterfaceStyle = Theme.userInterfaceStyle
        window.makeKeyAndVisible()
        self.window = window
        lockIfNeeded()
    }

    func sceneDidEnterBackground(_: UIScene) {
        if Prefs.appLock { showCover() }
    }

    func sceneWillEnterForeground(_: UIScene) {
        lockIfNeeded()
        App.shared.autoPing()
    }

    private func showCover() {
        guard cover == nil, let window else { return }
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        view.frame = window.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let button = UIButton(type: .system)
        button.setTitle(L("Разблокировать"), for: .normal)
        button.titleLabel?.font = Theme.font(17, .semibold)
        button.addAction(UIAction { [weak self] _ in self?.authenticate() }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.contentView.addSubview(button)
        NSLayoutConstraint.activate([button.centerXAnchor.constraint(equalTo: view.centerXAnchor), button.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        window.addSubview(view)
        cover = view
    }

    private func lockIfNeeded() {
        guard Prefs.appLock else { return }
        showCover()
        authenticate()
    }

    private func authenticate() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode on the device: nothing to lock with.
            cover?.removeFromSuperview()
            cover = nil
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L("Открыть Personal Tunnel")) { [weak self] ok, _ in
            DispatchQueue.main.async {
                guard ok else { return }
                self?.cover?.removeFromSuperview()
                self?.cover = nil
            }
        }
    }
}
