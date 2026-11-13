import Foundation

/// What the packet tunnel leaves behind for the app: its memory and its last
/// events. When the system ends the extension without stopping it (out of
/// memory, a crash), this is all the app can read about why.
public struct MemorySample: Codable, Equatable, Sendable {
    /// Memory the system counts against the extension, MiB.
    public var used: Double
    /// The highest it has been since the extension started, MiB.
    public var peak: Double
    /// What is left before the system ends the extension, MiB (0 when unknown).
    public var available: Double
    public var date: Date

    public init(used: Double, peak: Double, available: Double, date: Date = Date()) {
        self.used = used; self.peak = peak; self.available = available; self.date = date
    }

    /// The extension's limit is about 50 MiB: closer than this counts as near it.
    public static let nearLimitMiB: Double = 5

    public var isNearLimit: Bool { available > 0 && available < MemorySample.nearLimitMiB }

    /// `[mem] занято 21.4 МиБ, пик 25.0 МиБ, доступно 28.6 МиБ`
    public var line: String {
        func mib(_ value: Double) -> String { String(format: "%.1f", value) }
        var text = "[mem] занято \(mib(used)) МиБ, пик \(mib(peak)) МиБ"
        if available > 0 { text += ", доступно \(mib(available)) МиБ" }
        return text
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
    public static func decode(_ data: Data?) -> MemorySample? { data.flatMap { try? JSONDecoder().decode(MemorySample.self, from: $0) } }
}

/// The extension's own short log in the shared container. It outlives the
/// extension, unlike the core's log, which lives in its memory.
public enum TunnelEvents {
    public static let keep = 200

    public static func file(_ paths: SharedPaths) -> URL { paths.data.appendingPathComponent("tunnel-events.log") }

    /// Appends a line with its time, keeping the last `keep` lines. The text must
    /// already be redacted.
    public static func append(_ line: String, to url: URL, date: Date = Date()) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let entry = formatter.string(from: date) + " " + line.replacingOccurrences(of: "\n", with: " ")
        var lines = read(url)
        lines.append(entry)
        if lines.count > keep { lines.removeFirst(lines.count - keep) }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    public static func read(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

/// Puts together why the tunnel ended without being stopped.
public enum CrashReport {
    /// - Parameters:
    ///   - systemReason: the system's last disconnect error, if any.
    ///   - memory: the extension's last memory sample.
    ///   - events: the extension's last events, oldest first.
    ///   - coreCrash: what the core wrote before it fell (Go panic), if anything.
    public static func text(startedAt: Date?, systemReason: String?, memory: MemorySample?, events: [String], coreCrash: String?) -> (cause: String, details: String) {
        let cause: String
        if let coreCrash, !coreCrash.isEmpty {
            cause = CoreText.t("Ядро завершилось с ошибкой.")
        } else if let memory, memory.isNearLimit {
            cause = CoreText.t("Системе не хватило памяти для туннеля: расширение было у предела (около 50 МиБ).")
        } else if let systemReason, !systemReason.isEmpty {
            cause = systemReason
        } else {
            cause = CoreText.t("Система завершила туннель без остановки. Точная причина неизвестна.")
        }
        var parts: [String] = []
        let formatter = ISO8601DateFormatter()
        if let startedAt { parts.append(CoreText.f("Запущен: %@", formatter.string(from: startedAt))) }
        if let systemReason, !systemReason.isEmpty { parts.append(CoreText.f("Система: %@", systemReason)) }
        if let memory { parts.append(CoreText.f("Память (%@): %@", formatter.string(from: memory.date), memory.line)) }
        if let coreCrash, !coreCrash.isEmpty {
            // The reason (`panic: …`) and the failing goroutine come first in the file.
            let lines = coreCrash.split(separator: "\n").map(String.init)
            let kept = lines.count <= 100 ? lines : Array(lines.prefix(70)) + ["…"] + Array(lines.suffix(20))
            parts.append(CoreText.t("Ядро:") + "\n" + Redactor.redact(kept.joined(separator: "\n")))
        }
        if !events.isEmpty {
            parts.append(CoreText.t("Последние события расширения:") + "\n" + events.suffix(40).map(Redactor.redact).joined(separator: "\n"))
        }
        return (cause, parts.joined(separator: "\n\n"))
    }
}
