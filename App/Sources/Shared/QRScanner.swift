import AVFoundation
import UIKit

/// «Отсканировать QR»: the camera until a QR code is read; its text goes to the
/// same import as a pasted link.
final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let onCode: (String) -> Void
    private var done = false

    static func wrapped(onCode: @escaping (String) -> Void) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: QRScannerViewController(onCode: onCode))
        navigation.overrideUserInterfaceStyle = .dark
        return navigation
    }

    init(onCode: @escaping (String) -> Void) {
        self.onCode = onCode
        super.init(nibName: nil, bundle: nil)
        title = L("Отсканировать QR")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { [weak self] in granted ? self?.configure() : self?.denied() }
            }
        default: denied()
        }
    }

    private func configure() {
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            denied()
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        let frame = UIView()
        frame.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        frame.layer.borderWidth = 3
        frame.layer.cornerRadius = 28
        frame.layer.cornerCurve = .continuous
        frame.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(frame)
        let hint = UILabel(L("Наведите камеру на QR-код сервера или подписки."), font: Theme.font(.subheadline), color: .white, lines: 0)
        hint.textAlignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            frame.centerXAnchor.constraint(equalTo: view.centerXAnchor), frame.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            frame.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.7), frame.heightAnchor.constraint(equalTo: frame.widthAnchor),
            hint.topAnchor.constraint(equalTo: frame.bottomAnchor, constant: 24),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32), hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.compactMap { $0 as? AVCaptureVideoPreviewLayer }.forEach { $0.frame = view.bounds }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.stopRunning() }
    }

    private func denied() {
        let label = UILabel(L("Нет доступа к камере. Разрешите его в Настройках → Personal Tunnel."), font: Theme.font(.body), color: .white, lines: 0)
        label.textAlignment = .center
        view.addSubview(label)
        label.pin(to: view, insets: UIEdgeInsets(top: 0, left: 32, bottom: 0, right: 32))
    }

    func metadataOutput(_: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from _: AVCaptureConnection) {
        guard !done, let code = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first, !code.isEmpty else { return }
        done = true
        Haptics.result(true)
        dismiss(animated: true) { [onCode] in onCode(code) }
    }
}
