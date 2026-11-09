import SwiftUI
import TunnelKit
import UniformTypeIdentifiers

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .data] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Saving and restoring subscriptions, servers and settings.
struct BackupsView: View {
    @Environment(AppModel.self) private var model
    @State private var document: BackupDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var pending: Data?

    private var recoveryCopies: [URL] {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PersonalTunnelRecovery", isDirectory: true)
        return ["latest-2.ptbackup", "latest.ptbackup"]
            .map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var body: some View {
        StyledList {
            Section(footer: Text(L("В файле — подписки, серверы с ключами, настройки и импортированные шрифты в открытом виде. Храните его в личной папке.")).font(appFont(.caption))) {
                Button {
                    do {
                        document = BackupDocument(data: try model.makeBackup())
                        exporting = true
                    } catch {
                        model.show(.error, errorText(error))
                    }
                } label: { Label(L("Сохранить копию в Файлы"), systemImage: "square.and.arrow.down") }
                Button { importing = true } label: { Label(L("Восстановить из файла"), systemImage: "square.and.arrow.up") }
            }
            if !recoveryCopies.isEmpty {
                Section(header: HeaderText(L("Локальные копии")), footer: Text(L("Приложение само сохраняет копию после изменений. Копия версии 1.x тоже читается.")).font(appFont(.caption))) {
                    ForEach(recoveryCopies, id: \.self) { url in
                        Button {
                            pending = try? Data(contentsOf: url)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent == "latest.ptbackup" ? L("Копия Personal Tunnel 1.x") : L("Последняя автокопия"))
                                if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                                    Text(Format.relative(date)).font(appFont(.caption)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(L("Резервные копии"))
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "PersonalTunnel-backup-\(BackupsView.stamp())") { result in
            if case .success = result { model.show(.success, L("Копия сохранена")) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data, .item]) { result in
            guard case let .success(url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            pending = try? Data(contentsOf: url)
            if pending == nil { model.show(.error, L("Не удалось прочитать файл.")) }
        }
        .confirmationDialog(L("Заменить подписки, серверы и настройки содержимым копии?"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button(L("Восстановить"), role: .destructive) {
                guard let data = pending else { return }
                pending = nil
                do {
                    try model.restoreBackup(data)
                    model.show(.success, L("Копия восстановлена"))
                } catch {
                    model.show(.error, errorText(error))
                }
            }
        }
    }

    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

/// Version, provenance and licences.
struct AboutView: View {
    @Environment(AppModel.self) private var model
    @State private var showHWID = false

    var body: some View {
        StyledList {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("Personal Tunnel").font(appFont(.title2, weight: .bold))
                    Text(L("Личный VPN-клиент без аккаунтов, рекламы и аналитики. Серверы и подписки добавляете вы."))
                        .font(appFont(.footnote))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section(header: HeaderText(L("Сборка"))) {
                row(L("Версия"), "\(AppInfo.version) (\(AppInfo.build))")
                row(L("Коммит исходников"), AppInfo.sourceCommit)
                row(L("Ядро"), "sing-box \(AppInfo.coreVersion)")
                row("App Group", SharedContainer.groupIdentifier)
            }
            Section(header: HeaderText(L("Устройство")), footer: Text(L("HWID отправляется только подпискам, для которых это включено.")).font(appFont(.caption))) {
                Button {
                    showHWID.toggle()
                } label: {
                    row("HWID", showHWID ? DeviceIdentity.hwid : Redactor.mask(DeviceIdentity.hwid))
                }
                .buttonStyle(.plain)
                row(L("Модель"), DeviceIdentity.modelIdentifier)
            }
            Section(header: HeaderText(L("Лицензии"))) {
                Text(L("Personal Tunnel распространяется по GPL-3.0-or-later. Использует sing-box (SagerNet, GPL-3.0) в сборке sing-box-lx (Leadaxe), списки доменов v2fly/domain-list-community и SagerNet/sing-geosite (реклама) и runetfreedom/russia-v2ray-rules-dat (обход).")
                )
                .font(appFont(.footnote))
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L("О приложении"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(appFont(.body))
    }
}
