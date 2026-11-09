import AVFoundation
import SwiftUI
import VisionKit

/// Adds a subscription by link, or servers from pasted text.
struct AddSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var name = ""
    @State private var working = false
    @State private var scanning = false
    @FocusState private var focused: Bool

    private var isURL: Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (value.hasPrefix("http://") || value.hasPrefix("https://")) && !value.contains("\n")
    }

    var body: some View {
        NavigationStack {
            StyledList {
                Section(header: HeaderText(L("Ссылка подписки или серверов")), footer: Text(L("Подписка: ссылка http(s). Серверы: vless://, vmess://, trojan://, ss://, hy2://, tuic://, wireguard:// — по одной на строке, Base64-список, sing-box или Xray JSON, Clash YAML.")).font(appFont(.caption))) {
                    TextField("https://…", text: $text, axis: .vertical)
                        .font(appFont(.callout))
                        .lineLimit(1 ... 8)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                    if isURL {
                        TextField(L("Название (необязательно)"), text: $name)
                            .font(appFont(.body))
                    }
                }
                Section {
                    Button {
                        if let pasted = UIPasteboard.general.string { text = pasted }
                    } label: { Label(L("Вставить из буфера"), systemImage: "doc.on.clipboard") }
                    Button { scanning = true } label: { Label(L("Сканировать QR-код"), systemImage: "qrcode.viewfinder") }
                }
            }
            .navigationTitle(L("Добавить"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Отмена")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button(L("Добавить"), action: add)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .onAppear {
                focused = true
                if let pasted = UIPasteboard.general.string, AddSheet.looksImportable(pasted), text.isEmpty {
                    text = pasted
                }
            }
            .sheet(isPresented: $scanning) {
                QRScannerSheet { value in
                    scanning = false
                    text = value
                }
            }
        }
    }

    static func looksImportable(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefixes = ["http://", "https://", "vless://", "vmess://", "trojan://", "ss://", "hy2://", "hysteria2://", "hysteria://", "tuic://", "wireguard://", "wg://", "anytls://", "naive+"]
        return prefixes.contains { value.hasPrefix($0) }
    }

    private func add() {
        working = true
        let value = text
        let title = name
        Task {
            if isURL {
                await model.addSubscription(url: value, name: title)
            } else {
                await model.importContent(value)
            }
            working = false
            dismiss()
        }
    }
}

/// Camera QR-code scanner.
struct QRScannerSheet: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var denied = false

    var body: some View {
        NavigationStack {
            Group {
                if !DataScannerViewController.isSupported {
                    unavailable(L("Сканер QR-кодов недоступен на этом устройстве."))
                } else if denied {
                    unavailable(L("Нет доступа к камере. Разрешите его в Настройках iOS."))
                } else {
                    QRScannerRepresentable(onScan: onScan)
                        .ignoresSafeArea()
                }
            }
            .navigationTitle(L("Сканирование"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Закрыть")) { dismiss() } } }
            .task {
                let status = AVCaptureDevice.authorizationStatus(for: .video)
                if status == .notDetermined {
                    denied = !(await AVCaptureDevice.requestAccess(for: .video))
                } else {
                    denied = status != .authorized
                }
            }
        }
    }

    private func unavailable(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill").font(.largeTitle).foregroundStyle(.secondary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 32)
        }
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_: DataScannerViewController, context _: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator _: Coordinator) {
        controller.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var delivered = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(_: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems _: [RecognizedItem]) {
            guard !delivered else { return }
            for item in addedItems {
                if case let .barcode(barcode) = item, let value = barcode.payloadStringValue, !value.isEmpty {
                    delivered = true
                    onScan(value)
                    return
                }
            }
        }
    }
}
