import Foundation
import TunnelCore
import UIKit

/// Whether traffic really goes through the connected server (3.2.12, for the
/// connection button's ring): the system says «connected» as soon as the tunnel
/// is up, also when the server behind it has hung. While the VPN is on and the
/// app is in front, one URL test through the server (the one «Проверка
/// соединения» makes) every 45 s; two failures in a row make it `failing`, one
/// answer makes it `ok` again. Nothing runs in the background.
final class ConnectionHealth {
    enum State: Equatable { case unknown, ok, failing }

    let state = Observable<State>(.unknown)
    private var timer: Timer?
    private var failures = 0
    private var running = false
    private var generation = 0
    private var inBackground = false
    private static let interval: TimeInterval = 45

    init(tunnel: TunnelController) {
        tunnel.state.observe(self) { [weak self] state in
            guard let self else { return }
            if state == .connected { self.start() } else { self.stop() }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.inBackground = true
            self?.timer?.invalidate()
            self?.timer = nil
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.inBackground = false
            if self.running { self.schedule(after: 1) }
        }
    }

    private func start() {
        guard !running else { return }
        running = true
        failures = 0
        state.set(.unknown)
        // A moment for the routes to settle, as the subscriptions' refresh waits.
        if !inBackground { schedule(after: 2) }
    }

    private func stop() {
        running = false
        generation += 1
        timer?.invalidate()
        timer = nil
        failures = 0
        state.set(.unknown)
    }

    private func schedule(after delay: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.check() }
        timer.tolerance = min(5, delay / 4)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func check() {
        guard running, !inBackground else { return }
        // Nothing to test through: the ring does not wait for a test that cannot come.
        guard let node = App.shared.library.activeNode else {
            state.set(.ok)
            return
        }
        generation += 1
        let token = generation
        Task { @MainActor [weak self] in
            let probes = NetworkProbes()
            let result = await LatencyRunner.deadline(seconds: 8) { await probes.url(tag: node.id, link: ConfigBuilder.probeURL, timeoutMs: 6000) }
            guard let self, self.running, token == self.generation else { return }
            switch result {
            case .delay:
                self.failures = 0
                self.state.set(.ok)
                self.schedule(after: Self.interval)
            case .failed:
                self.failures += 1
                if self.failures >= 2 {
                    self.state.set(.failing)
                    self.schedule(after: Self.interval)
                } else {
                    // Once more soon: one lost test is not a hung server.
                    self.schedule(after: 5)
                }
            }
        }
    }
}
