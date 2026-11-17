import Foundation
import Network
import NetworkExtension

/// 3.2.11: the Wi-Fi network the device is on. The name needs the app's
/// «Access Wi-Fi Information» entitlement (and a VPN configuration of the app,
/// which it has); without it the name is nil while `onWiFi` still says whether
/// the device is on Wi-Fi.
enum CurrentWiFi {
    static func fetch(_ done: @escaping (_ ssid: String?, _ onWiFi: Bool) -> Void) {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        let once = Once()
        monitor.pathUpdateHandler = { path in
            guard once.first() else { return }
            let onWiFi = path.status == .satisfied
            NEHotspotNetwork.fetchCurrent { network in
                let name = network?.ssid.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    monitor.cancel()
                    done(name.flatMap { $0.isEmpty ? nil : $0 }, onWiFi || name != nil)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "personaltunnel.current-wifi"))
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func first() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
