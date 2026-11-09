import Foundation
import Libbox
import NetworkExtension
import Observation
import SwiftUI
import TunnelKit
import UIKit
import WidgetKit

/// A short message shown at the top of the screen.
struct Banner: Identifiable, Equatable {
    enum Kind { case info, success, error }
    let id = UUID()
    let kind: Kind
    let text: String
}

/// The app state and every action the interface can take.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var library: ServerLibrary {
        didSet { scheduleSave() }
    }

    var options: TunnelOptions {
        didSet {
            guard options != oldValue else { return }
            LibraryStore.save(options)
            configurationChanged(reload: true)
        }
    }

    let settings = AppSettings.shared
    let tunnel = TunnelController()
    let core = CoreClient()
    let latency = LatencyService()

    private(set) var refreshing: Set<UUID> = []
    var banner: Banner?
    /// The last error of the extension, shown on the home screen.
    private(set) var tunnelError: String?
    private(set) var isLaunching = true

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    /// Tags of the configuration the tunnel runs, to switch servers live.
    @ObservationIgnored private var runningTags: [UUID: String] = [:]
    @ObservationIgnored private var runningSubscriptionID: UUID?
    @ObservationIgnored private var lastTrafficTotal: Int64 = 0
    private let transport = URLSessionTransport()

    private init() {
        SharedContainer.prepareDirectories()
        var loaded = LibraryStore.loadLibrary() ?? LibraryStore.loadPreviousLibrary()
        var loadedOptions = LibraryStore.loadOptions()
        if loaded == nil, let migrated = LegacyMigration.runIfNeeded() {
            loaded = migrated.library
            if let migratedOptions = migrated.options { loadedOptions = migratedOptions }
            AppSettings.shared.importPreferences(migrated.preferences)
            for (name, data) in migrated.fonts { try? FontLibrary.store(data, named: name) }
        }
        library = loaded ?? ServerLibrary()
        options = loadedOptions
        library.repairSelection()
        if loaded != nil { LibraryStore.save(library) }

        let setup = LibboxSetupOptions()
        setup.basePath = SharedContainer.coreBaseDirectory.path
        setup.workingPath = SharedContainer.coreWorkingDirectory.path
        setup.tempPath = SharedContainer.cacheDirectory.path
        var error: NSError?
        LibboxSetup(setup, &error)

        tunnel.onStatusChange = { [weak self] old, new in
            self?.tunnelStatusChanged(from: old, to: new)
        }
        core.onStatus = { [weak self] status in
            self?.accountTraffic(status)
        }
        latency.onFinish = { [weak self] in
            self?.latencyFinished()
        }
    }

    // MARK: Lifecycle

    func launch() async {
        await tunnel.load()
        tunnelError = SharedContainer.defaults.string(forKey: SharedKey.lastTunnelError)
        if tunnel.isConnected { core.start() }
        isLaunching = false
        try? prepareConfiguration()
        await refreshDue()
    }

    func sceneBecameActive() {
        if tunnel.isConnected { core.start() }
        Task { await refreshDue() }
    }

    func sceneEnteredBackground() {
        core.stop()
        latency.cancel()
        saveNow()
    }

    // MARK: Selection and connection

    var selectedServer: Server? { library.effectiveSelection }

    var selectedSubscription: Subscription? { library.subscription(containing: selectedServer?.id) }

    func select(_ server: Server) {
        guard library.selectedServerID != server.id else { return }
        Haptics.selection()
        library.selectedServerID = server.id
        guard tunnel.isActive else {
            try? prepareConfiguration()
            return
        }
        let subscriptionID = library.subscription(containing: server.id)?.id
        if subscriptionID == runningSubscriptionID, let tag = runningTags[server.id] {
            // Same configuration: switch the selector, no reconnect.
            try? prepareConfiguration()
            Task.detached {
                try? LibboxNewStandaloneCommandClient()?.selectOutbound(BuiltConfiguration.selectorTag, outboundTag: tag)
            }
        } else {
            configurationChanged(reload: true)
        }
    }

    /// The outbound tag of a server in the running configuration.
    func tunnelTag(for id: UUID) -> String? { runningTags[id] }

    func toggleConnection() {
        switch tunnel.status {
        case .connected, .connecting, .reasserting:
            disconnect()
        default:
            Task { await connect() }
        }
    }

    func connect() async {
        latency.cancel()
        Haptics.impact()
        tunnelError = nil
        SharedContainer.defaults.removeObject(forKey: SharedKey.lastTunnelError)
        if settings.connectToBest, let subscription = selectedSubscription,
           let best = latency.best(among: subscription.servers.map(\.id)), best != library.selectedServerID
        {
            library.selectedServerID = best
        }
        do {
            let built = try prepareConfiguration()
            try await AppModel.check(built.json)
            runningTags = built.tags
            runningSubscriptionID = selectedSubscription?.id
            try await tunnel.start(configuration: built.json, serverName: selectedServer?.name ?? "")
        } catch {
            let message = errorText(error)
            tunnelError = message
            show(.error, message)
        }
    }

    func disconnect() {
        latency.cancel()
        Haptics.impact()
        Task { await tunnel.stopDisablingOnDemand() }
    }

    /// Validates a configuration with the core before handing it to the extension.
    nonisolated static func check(_ json: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            var error: NSError?
            LibboxCheckConfig(json, &error)
            if let error { throw TunnelError(Redactor.redact(error.localizedDescription)) }
        }.value
    }

    /// Writes the configuration the tunnel starts with when the app is not
    /// running, and the server name the widget shows.
    @discardableResult
    func prepareConfiguration() throws -> BuiltConfiguration {
        guard let server = library.effectiveSelection, let subscription = library.subscription(containing: server.id) else {
            throw ConfigBuildError.noServers
        }
        let built = try ConfigBuilder.build(
            servers: subscription.servers,
            selected: server.id,
            options: options,
            ruleSetDirectory: TunnelController.ruleSetDirectory
        )
        try SharedContainer.write(Data(built.json.utf8), to: SharedContainer.activeConfigurationURL, excludedFromBackup: LibraryStore.excludesFromBackup)
        let defaults = SharedContainer.defaults
        defaults.set(server.displayName, forKey: SharedKey.activeServerName)
        defaults.set(server.country?.flag ?? "", forKey: SharedKey.activeServerFlag)
        WidgetCenter.shared.reloadAllTimelines()
        return built
    }

    /// Something that shapes the configuration changed: rewrite it and, if
    /// the tunnel runs, restart the core with it.
    private func configurationChanged(reload: Bool) {
        guard let built = try? prepareConfiguration() else { return }
        guard reload, tunnel.isActive else { return }
        Task {
            do {
                try await AppModel.check(built.json)
            } catch {
                show(.error, errorText(error))
                return
            }
            latency.cancel()
            if let response = await tunnel.send(.reload), !response.isEmpty {
                show(.error, localizedMessage(response))
            } else {
                runningTags = built.tags
                runningSubscriptionID = selectedSubscription?.id
            }
        }
    }

    private func tunnelStatusChanged(from old: NEVPNStatus, to new: NEVPNStatus) {
        switch new {
        case .connected:
            tunnelError = nil
            core.resetSession()
            core.start()
            lastTrafficTotal = 0
            Haptics.success()
            if runningTags.isEmpty, let built = try? prepareConfiguration() {
                runningTags = built.tags
                runningSubscriptionID = selectedSubscription?.id
            }
        case .disconnected, .invalid:
            core.stop()
            latency.cancel()
            runningTags = [:]
            runningSubscriptionID = nil
            if old == .connecting || old == .connected || old == .reasserting {
                if let error = SharedContainer.defaults.string(forKey: SharedKey.lastTunnelError), !error.isEmpty {
                    tunnelError = localizedMessage(error)
                }
            }
        default:
            break
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func accountTraffic(_ status: CoreClient.Status) {
        let total = status.uplinkTotal + status.downlinkTotal
        let delta = total >= lastTrafficTotal ? total - lastTrafficTotal : total
        lastTrafficTotal = total
        DailyTraffic.add(delta)
    }

    // MARK: Latency

    /// Tests the servers of a subscription (all enabled ones when `nil`).
    func testLatency(subscriptionID: UUID?, visible: Set<UUID> = [], force: Bool = false) {
        if latency.isRunning {
            latency.cancel()
            return
        }
        let subscriptions = library.subscriptions.filter { $0.isEnabled && (subscriptionID == nil || $0.id == subscriptionID) }
        let tunnelRunning = tunnel.isConnected
        var priority = visible
        if let selected = library.selectedServerID { priority.insert(selected) }
        var targets: [LatencyTarget] = []
        for subscription in subscriptions {
            for server in subscription.servers {
                guard let host = server.host, let port = server.port else { continue }
                if server.isFavorite { priority.insert(server.id) }
                let tag = tunnelRunning && subscription.id == runningSubscriptionID ? runningTags[server.id] : nil
                targets.append(LatencyTarget(id: server.id, host: host, port: port, isUDPBased: server.descriptor.isUDPBased, tunnelTag: tag))
            }
        }
        latency.run(targets, mode: settings.pingMode, priority: priority, force: force, memory: core.extensionMemory)
    }

    private func latencyFinished() {
        guard settings.connectToBest, tunnel.isConnected, let subscription = selectedSubscription,
              let best = latency.best(among: subscription.servers.map(\.id)),
              best != library.selectedServerID, let server = library.server(id: best)
        else { return }
        select(server)
        show(.info, L("Подключено к самому быстрому серверу: %@", server.displayName))
    }

    // MARK: Subscriptions

    func refreshDue() async {
        let due = library.subscriptions.filter { $0.isDue() }.map(\.id)
        for id in due { await refresh(id) }
    }

    func refreshAll() async {
        let ids = library.subscriptions.filter { $0.isRemote && $0.isEnabled }.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.refresh(id, quiet: true) }
            }
        }
    }

    func refresh(_ id: UUID, quiet: Bool = false) async {
        guard let subscription = library.subscriptions.first(where: { $0.id == id }), let url = subscription.url,
              !refreshing.contains(id) else { return }
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        let fetcher = SubscriptionFetcher(transport: transport, device: DeviceIdentity.current) { entry in
            NetworkActivityLog.record(entry)
        }
        do {
            let result = try await fetcher.fetch(url: url, sendsDeviceInfo: subscription.sendsDeviceInfo)
            guard let index = library.subscriptionIndex(id: id) else { return }
            var updated = library.subscriptions[index]
            let before = updated.servers.map(\.fingerprint)
            if !result.content.servers.isEmpty {
                updated.replaceServers(with: result.content.servers)
            }
            updated.skipped = result.content.skipped
            updated.info = result.metadata.info
            if !updated.hasCustomName, let title = result.metadata.title { updated.name = title }
            updated.lastUpdated = Date()
            updated.lastError = result.content.servers.isEmpty ? (result.content.skipped.first?.reason ?? ImportError.empty.description) : nil
            library.subscriptions[index] = updated
            library.repairSelection()
            if updated.servers.map(\.fingerprint) != before, runningSubscriptionID == id {
                configurationChanged(reload: true)
            } else if library.subscription(containing: library.selectedServerID)?.id == id {
                try? prepareConfiguration()
            }
            if !quiet, updated.lastError == nil {
                show(.success, L("«%@» обновлена: %@", updated.name, serversCount(updated.servers.count)))
            }
        } catch is CancellationError {
            return
        } catch {
            let message = errorText(error)
            if let index = library.subscriptionIndex(id: id) {
                library.subscriptions[index].lastError = message
                library.subscriptions[index].lastUpdated = Date()
            }
            if !quiet { show(.error, message) }
        }
    }

    /// Adds a subscription by URL and downloads it.
    func addSubscription(url text: String, name: String? = nil) async {
        let url = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try SubscriptionFetcher.validatedURL(url)
        } catch {
            show(.error, errorText(error))
            return
        }
        if let existing = library.subscriptions.first(where: { $0.url == url }) {
            await refresh(existing.id)
            return
        }
        var subscription = Subscription(name: name?.nonEmptyText ?? URL(string: url)?.host ?? L("Подписка"), url: url)
        subscription.hasCustomName = name?.nonEmptyText != nil
        library.subscriptions.append(subscription)
        settings.expandedSubscriptions.insert(subscription.id.uuidString)
        await refresh(subscription.id)
        library.repairSelection()
    }

    enum ImportOutcome {
        case subscription
        case servers(Int, skipped: Int)
    }

    /// Imports pasted text, an opened link or a file: a subscription URL,
    /// share links or a configuration.
    @discardableResult
    func importContent(_ text: String, sourceName: String? = nil) async -> ImportOutcome? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if (lowered.hasPrefix("http://") || lowered.hasPrefix("https://")), !trimmed.contains("\n"), !trimmed.contains(" ") {
            await addSubscription(url: trimmed)
            return .subscription
        }
        do {
            let content = try ContentDecoder.decode(trimmed)
            guard !content.servers.isEmpty else {
                show(.error, localizedMessage(content.skipped.first?.reason ?? ImportError.empty.description))
                return nil
            }
            let isFile = content.format != .shareLinks && content.format != .base64Links && content.servers.count > 1
            if isFile {
                var subscription = Subscription(name: sourceName ?? localizedMessage(content.format.title), autoUpdate: false)
                subscription.hasCustomName = true
                subscription.replaceServers(with: content.servers)
                subscription.skipped = content.skipped
                library.subscriptions.append(subscription)
            } else {
                let index = library.manualSubscriptionIndex(named: L("Мои серверы"))
                library.subscriptions[index].servers += content.servers.map { Server(imported: $0) }
            }
            library.repairSelection()
            try? prepareConfiguration()
            let message = L("Добавлено: %@", serversCount(content.servers.count))
                + (content.skipped.isEmpty ? "" : " · " + L("пропущено: %d", content.skipped.count))
            show(.success, message)
            Haptics.success()
            return .servers(content.servers.count, skipped: content.skipped.count)
        } catch {
            show(.error, errorText(error))
            return nil
        }
    }

    /// `personaltunnel://`, `sing-box://import-remote-profile` and proxy share links.
    func open(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "personaltunnel", "vpndirect":
            let action = (url.host ?? "").lowercased()
            switch action {
            case "connect": if !tunnel.isActive { Task { await connect() } }
            case "disconnect": if tunnel.isActive { disconnect() }
            case "toggle": toggleConnection()
            case "import", "add":
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if let value = query.first(where: { $0.name == "url" || $0.name == "link" })?.value {
                    Task { await importContent(value, sourceName: query.first(where: { $0.name == "name" })?.value) }
                } else {
                    let rest = String(url.path.dropFirst())
                    if !rest.isEmpty { Task { await importContent(rest.removingPercentEncoding ?? rest) } }
                }
            default:
                break
            }
        case "sing-box":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let remote = components?.queryItems?.first(where: { $0.name == "url" })?.value {
                let name = url.fragment?.removingPercentEncoding
                Task { await addSubscription(url: remote, name: name) }
            }
        default:
            Task { await importContent(url.absoluteString) }
        }
    }

    func deleteSubscription(_ id: UUID) {
        library.subscriptions.removeAll { $0.id == id }
        library.repairSelection()
        configurationChanged(reload: runningSubscriptionID == id)
    }

    func updateSubscription(_ subscription: Subscription) {
        guard let index = library.subscriptionIndex(id: subscription.id) else { return }
        let urlChanged = library.subscriptions[index].url != subscription.url
        library.subscriptions[index] = subscription
        library.repairSelection()
        if urlChanged { Task { await refresh(subscription.id) } }
        configurationChanged(reload: runningSubscriptionID == subscription.id)
    }

    func moveSubscriptions(from source: IndexSet, to destination: Int) {
        library.subscriptions.move(fromOffsets: source, toOffset: destination)
    }

    func setSubscriptionEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = library.subscriptionIndex(id: id) else { return }
        library.subscriptions[index].isEnabled = enabled
        library.repairSelection()
        configurationChanged(reload: true)
    }

    // MARK: Servers

    func toggleFavorite(_ id: UUID) {
        guard var server = library.server(id: id) else { return }
        server.isFavorite.toggle()
        library.updateServer(server)
        Haptics.selection()
    }

    func updateServer(_ server: Server) {
        library.updateServer(server)
        if library.subscription(containing: server.id)?.id == runningSubscriptionID {
            configurationChanged(reload: true)
        }
    }

    func deleteServer(_ id: UUID) {
        let running = library.subscription(containing: id)?.id == runningSubscriptionID
        library.removeServer(id: id)
        configurationChanged(reload: running)
    }

    func moveServers(in subscriptionID: UUID, from source: IndexSet, to destination: Int) {
        guard let index = library.subscriptionIndex(id: subscriptionID) else { return }
        library.subscriptions[index].servers.move(fromOffsets: source, toOffset: destination)
    }

    /// Servers of a subscription in display order (latency order if chosen).
    func orderedServers(_ subscription: Subscription) -> [Server] {
        guard settings.sortByLatency else { return subscription.servers }
        return subscription.servers.enumerated().sorted { lhs, rhs in
            let left = latency.milliseconds(lhs.element.id) ?? Int.max
            let right = latency.milliseconds(rhs.element.id) ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    // MARK: Backups

    func makeBackup() throws -> Data {
        var preferences = settings.exportPreferences()
        let defaults = SharedContainer.defaults
        for key in [SharedKey.includeAllNetworks, SharedKey.excludeLocalNetworks, SharedKey.excludeAPNs, SharedKey.excludeCellularServices, SharedKey.onDemand] {
            if let value = defaults.object(forKey: key) as? Bool { preferences[key] = .bool(value) }
        }
        let archive = BackupArchive(
            appVersion: AppInfo.version,
            library: library,
            tunnelOptions: options,
            preferences: preferences,
            fonts: FontLibrary.files()
        )
        return try archive.encoded()
    }

    func restoreBackup(_ data: Data) throws {
        let archive = try BackupArchive.read(data)
        guard !archive.library.subscriptions.isEmpty else { throw BackupArchive.ReadError.noServers }
        for (name, font) in archive.fonts { try? FontLibrary.store(font, named: name) }
        settings.importPreferences(archive.preferences)
        let defaults = SharedContainer.defaults
        for key in [SharedKey.includeAllNetworks, SharedKey.excludeLocalNetworks, SharedKey.excludeAPNs, SharedKey.excludeCellularServices, SharedKey.onDemand] {
            if let value = archive.preferences[key]?.bool { defaults.set(value, forKey: key) }
        }
        library = archive.library
        library.repairSelection()
        options = archive.tunnelOptions
        latency.clear()
        FontLibrary.applyAppearance(settings)
        configurationChanged(reload: true)
        Task { await tunnel.applySettings() }
        Task { await refreshAll() }
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        LibraryStore.save(library)
        writeRecoveryCopy()
    }

    /// A local copy in Documents, as 1.x kept, so an accidental reset or a
    /// damaged file can be recovered from the Backups page.
    private func writeRecoveryCopy() {
        guard !library.subscriptions.isEmpty, let data = try? makeBackup() else { return }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PersonalTunnelRecovery", isDirectory: true)
        try? SharedContainer.write(data, to: directory.appendingPathComponent("latest-2.ptbackup"), excludedFromBackup: LibraryStore.excludesFromBackup)
    }

    static var recoveryCopyURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PersonalTunnelRecovery", isDirectory: true)
            .appendingPathComponent("latest-2.ptbackup")
    }

    // MARK: Banners

    func show(_ kind: Banner.Kind, _ text: String) {
        let banner = Banner(kind: kind, text: text)
        self.banner = banner
        if kind == .error { Haptics.error() }
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: kind == .error ? 5_000_000_000 : 2_800_000_000)
            guard !Task.isCancelled, self?.banner == banner else { return }
            self?.banner = nil
        }
    }
}

/// A readable, translated message for any error.
func errorText(_ error: Error) -> String {
    if let localized = error as? LocalizedError, let text = localized.errorDescription {
        return localizedMessage(text)
    }
    if let convertible = error as? CustomStringConvertible {
        let text = convertible.description
        if !text.isEmpty, !text.hasPrefix("Error Domain=") { return localizedMessage(text) }
    }
    return localizedMessage(error.localizedDescription)
}

extension String {
    var nonEmptyText: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
    static var sourceCommit: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "PersonalSourceCommit") as? String ?? ""
        return value.isEmpty || value.hasPrefix("$(") ? "—" : value
    }

    static var coreVersion: String { LibboxVersion() }
}
