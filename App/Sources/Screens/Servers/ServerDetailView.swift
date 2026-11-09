import CoreImage.CIFilterBuiltins
import SwiftUI
import TunnelKit

/// Server parameters, latency history, sharing and editing.
struct ServerDetailView: View {
    let serverID: UUID

    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var showQR = false
    @State private var editingJSON = false
    @State private var confirmDelete = false

    private var server: Server? { model.library.server(id: serverID) }

    var body: some View {
        Group {
            if let server {
                list(server)
            } else {
                Text(L("Сервер удалён")).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(server?.displayName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = server?.name ?? "" }
    }

    private func list(_ server: Server) -> some View {
        let descriptor = server.descriptor
        let outbound = server.outbound
        return StyledList {
            Section {
                TextField(L("Название"), text: $name)
                    .font(appFont(.body))
                    .submitLabel(.done)
                    .onSubmit { rename(server) }
                Button {
                    model.select(server)
                } label: {
                    Label(server.id == model.library.selectedServerID ? L("Выбран") : L("Выбрать"), systemImage: "checkmark.circle")
                }
                .disabled(server.id == model.library.selectedServerID)
                Button {
                    model.toggleFavorite(server.id)
                } label: {
                    Label(server.isFavorite ? L("Убрать из избранного") : L("В избранное"), systemImage: server.isFavorite ? "star.slash" : "star")
                }
            }

            Section(header: HeaderText(L("Параметры"))) {
                row(L("Протокол"), server.protocolTags.first ?? descriptor.protocolName)
                if let host = server.host { row(L("Адрес"), host) }
                if let port = server.port { row(L("Порт"), "\(port)") }
                if let transport = descriptor.transport { row(L("Транспорт"), transport) }
                if let security = descriptor.security { row(L("Шифрование"), security) }
                if let sni = outbound["tls"]?["server_name"]?.text { row("SNI", sni) }
                if let fingerprint = outbound["tls"]?["utls"]?["fingerprint"]?.text { row(L("Отпечаток TLS"), fingerprint) }
                if let flow = outbound["flow"]?.text { row("Flow", flow) }
                if let ports = outbound["server_ports"]?.stringList, !ports.isEmpty { row(L("Смена портов"), ports.joined(separator: ", ")) }
                if descriptor.allowsInsecure {
                    Label(L("Проверка сертификата отключена (insecure). Соединение можно перехватить."), systemImage: "exclamationmark.shield")
                        .font(appFont(.footnote))
                        .foregroundStyle(.orange)
                }
            }

            Section(header: HeaderText(L("Задержка"))) {
                if let record = model.latency.record(server.id) {
                    row(L("Последний замер"), lastSample(record))
                    if !record.history.isEmpty {
                        row(L("Последние URL-тесты"), record.history.map { sample in sample.milliseconds.map { String($0) } ?? "—" }.joined(separator: " · "))
                    }
                    if record.isUnstable {
                        Text(L("Нестабильный: разброс задержки больше 50 % или часть замеров без ответа."))
                            .font(appFont(.footnote))
                            .foregroundStyle(.orange)
                    }
                }
                Button {
                    guard let subscription = model.library.subscription(containing: server.id) else { return }
                    model.testLatency(subscriptionID: subscription.id, visible: [server.id], force: true)
                } label: {
                    Label(model.latency.isRunning ? L("Остановить проверку") : L("Проверить задержку"), systemImage: "bolt.horizontal")
                }
            }

            Section(header: HeaderText(L("Поделиться"))) {
                if let link = server.link {
                    Button {
                        UIPasteboard.general.string = link
                        model.show(.success, L("Ссылка скопирована"))
                    } label: { Label(L("Скопировать ссылку"), systemImage: "doc.on.doc") }
                    Button { showQR = true } label: { Label(L("Показать QR-код"), systemImage: "qrcode") }
                }
                Button {
                    UIPasteboard.general.string = outbound.serialized(pretty: true)
                    model.show(.success, L("Конфигурация скопирована"))
                } label: { Label(L("Скопировать как sing-box JSON"), systemImage: "curlybraces") }
                Button { editingJSON = true } label: { Label(L("Изменить параметры (JSON)"), systemImage: "slider.horizontal.3") }
            }

            Section {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label(L("Удалить сервер"), systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $showQR) {
            if let link = server.link { QRCodeSheet(text: link, title: server.displayName) }
        }
        .sheet(isPresented: $editingJSON) {
            OutboundEditor(server: server)
        }
        .confirmationDialog(L("Удалить сервер?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("Удалить"), role: .destructive) {
                model.deleteServer(server.id)
                dismiss()
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(appFont(.body)).foregroundStyle(palette.primaryText)
            Spacer(minLength: 12)
            Text(value)
                .font(appFont(.body))
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    private func lastSample(_ record: LatencyRecord) -> String {
        guard let value = record.milliseconds else { return L("нет ответа") }
        let kind = record.latest.kind == .url ? "URL" : "TCP"
        return "\(value) " + L("мс") + " (\(kind))"
    }

    private func rename(_ server: Server) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != server.name else { return }
        var updated = server
        updated.name = trimmed
        model.updateServer(updated)
    }
}

/// Edits the sing-box outbound of a server as JSON.
struct OutboundEditor: View {
    let server: Server
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                if let error {
                    Text(error).font(appFont(.footnote)).foregroundStyle(.red)
                }
                Text(L("Это outbound sing-box без поля tag. Неверные параметры приведут к ошибке подключения."))
                    .font(appFont(.caption))
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle(server.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Отмена")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(L("Сохранить"), action: save) }
            }
            .onAppear { text = server.outbound.serialized(pretty: true) }
        }
    }

    private func save() {
        do {
            let json = try JSON.parse(text)
            guard json.object != nil, json["type"]?.text != nil else {
                error = L("Нужен JSON-объект с полем type.")
                return
            }
            var updated = server
            var outbound = json
            outbound["tag"] = nil
            updated.outbound = outbound
            updated.link = nil
            model.updateServer(updated)
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// A QR code for sharing a link.
struct QRCodeSheet: View {
    let text: String
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let image = QRCodeSheet.image(for: text) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280)
                        .padding(16)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
                }
                Text(L("Отсканируйте в другом клиенте. QR-код содержит ключи сервера."))
                    .font(appFont(.footnote))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                ShareLink(item: text) { Label(L("Поделиться ссылкой"), systemImage: "square.and.arrow.up") }
            }
            .padding()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Готово")) { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
