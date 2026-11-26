import Foundation
import TunnelCore

/// PT Lab's own storage and its sample subscriptions. The Lab keeps everything in
/// its own Application Support folder, never in the app's group: a signing tool
/// may hand it the same group as the app, and the Lab must not touch that data.
enum LabData {
    static let paths: SharedPaths = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PTLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return SharedPaths(container: base)
    }()

    private static let seededKey = "lab.seededExamples"

    /// On the first launch: two sample subscriptions (addresses under example.com,
    /// no real server), so every screen has something to show. Own subscriptions
    /// can be added as in the app; connecting only pretends.
    static func seedIfEmpty(_ store: LibraryStore) {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        UserDefaults.standard.set(true, forKey: seededKey)
        guard store.library.value.subscriptions.isEmpty else { return }
        let uuid = "00000000-0000-4000-8000-00000000000"
        func vless(_ n: Int, _ host: String, _ name: String) -> String {
            "vless://\(uuid)\(n)@\(host).example.com:443?encryption=none&security=tls&type=ws&host=\(host).example.com&path=%2Fws&sni=\(host).example.com#\(name)"
        }
        func trojan(_ host: String, _ name: String) -> String {
            "trojan://lab-password@\(host).example.com:443?security=tls&sni=\(host).example.com#\(name)"
        }
        func hysteria(_ host: String, _ name: String) -> String {
            "hysteria2://lab-password@\(host).example.com:443?sni=\(host).example.com#\(name)"
        }
        let europe = [
            vless(1, "fast", "Самый быстрый"),
            vless(2, "de", "Germany"), vless(3, "nl", "Netherlands"), vless(4, "fi", "Finland"),
            vless(5, "fr", "France"), vless(6, "uk", "United Kingdom"), trojan("se", "Sweden"),
            trojan("pl", "Poland"), vless(7, "reserve", "Резерв"),
        ]
        let world = [
            hysteria("us", "USA"), hysteria("jp", "Japan"), trojan("sg", "Singapore"),
            vless(8, "tr", "Turkey"), vless(9, "kz", "Kazakhstan"),
        ]
        store.update { library in
            for (name, links) in [("Лаборатория · Европа", europe), ("Лаборатория · Мир", world)] {
                guard let result = try? ContentImporter.parse(links.joined(separator: "\n")) else { continue }
                let nodes = NodeAssembler.assemble(result.nodes)
                guard !nodes.isEmpty else { continue }
                let id = library.allocateID()
                library.subscriptions.append(Subscription(id: id, name: name, nodes: nodes, updatedAt: Date()))
                if library.activeSubscriptionID == nil { library.activeSubscriptionID = id }
            }
        }
    }
}

/// A believable delay for a server, the same for it every time (with a little
/// jitter); now and then a server does not answer.
enum LabPing {
    static func probe(_ key: String) async -> ProbeResult {
        var hash: UInt64 = 5381
        for byte in key.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        let failing = hash % 11 == 0
        let base = 45 + Int(hash % 380)
        let jitter = Int.random(in: -base / 8 ... base / 8)
        let wait = failing ? 1.4 : Double(base + jitter) / 1000 + 0.15
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        return failing ? .failed(.timeout) : .delay(max(1, base + jitter))
    }
}

/// The app's own core's server tests, pretended (the app has no core in the Lab).
final class LocalCoreProbes: LatencyProbes, @unchecked Sendable {
    var report: ((String) -> Void)?

    static func start(_: [Subscription], options _: TunnelOptions, interface _: String?, exit _: ProbeExit? = nil) -> (probes: LocalCoreProbes, failed: [Int64: String]) {
        (LocalCoreProbes(), [:])
    }

    func close() {}

    func tcp(host: String, port _: Int, timeout _: TimeInterval) async -> ProbeResult {
        await LabPing.probe(host)
    }

    func url(tag: String, link _: String, timeoutMs _: Int) async -> ProbeResult {
        await LabPing.probe(tag)
    }
}
