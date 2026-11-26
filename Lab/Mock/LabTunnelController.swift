import Foundation
import TunnelCore
import UIKit

/// PT Lab: the app's `TunnelController` without the system VPN. A start shows
/// «Подключение…» for a moment and then «Подключено», a stop «Отключение…» and
/// then off; nothing is installed and no traffic goes anywhere. Same surface as
/// the app's (App/Sources/Core/TunnelController.swift).
final class TunnelController {
    let state = Observable<TunnelState>(.disconnected)
    let connectedSince = Observable<Date?>(nil)
    let lastError = Observable<String?>(nil)
    let crash = Observable<TunnelCrash?>(nil)
    let loaded = Observable(false)
    let unprotected = Observable<String?>(nil)

    /// How long the pretend tunnel takes to come up and to go down.
    static var connectTime: TimeInterval = 1.6
    static var stopTime: TimeInterval = 0.8

    /// Each change of mind starts a new step; an older step's timer does nothing.
    private var step = 0

    init() {
        DispatchQueue.main.async { self.loaded.set(true) }
    }

    static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "PT Lab"
    }

    func start(config _: String) {
        step += 1
        let current = step
        state.set(.connecting)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTime) { [weak self] in
            guard let self, self.step == current else { return }
            self.connectedSince.set(Date())
            self.state.set(.connected)
        }
    }

    func stop() {
        guard state.value != .disconnected else { return }
        step += 1
        let current = step
        let since = connectedSince.value
        state.set(.disconnecting)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopTime) { [weak self] in
            guard let self, self.step == current else { return }
            // As the extension does when it stops: the session's totals for analytics.
            if let since {
                let totals = App.shared.core.coreTotals
                let summary = SessionSummary(started: Int64(since.timeIntervalSince1970), ended: Int64(Date().timeIntervalSince1970),
                                             up: totals.up, down: totals.down)
                AppGroup.defaults.set(summary.encoded, forKey: SharedKey.lastSession)
            }
            self.connectedSince.set(nil)
            self.state.set(.disconnected)
        }
    }

    func removeConfiguration(_ done: @escaping () -> Void) {
        DispatchQueue.main.async(execute: done)
    }

    func applySettings() {}

    /// A server change while up: a short «Смена сервера…», then up again.
    func reload(_ completion: @escaping (String?) -> Void) {
        guard state.value.isOn else { DispatchQueue.main.async { completion(nil) }; return }
        step += 1
        let current = step
        state.set(.reasserting)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.step == current else { return }
            self.state.set(.connected)
            completion(nil)
        }
    }
}
