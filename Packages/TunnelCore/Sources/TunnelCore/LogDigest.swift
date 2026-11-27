import Foundation

/// 3.5: the copied log, made readable. The owner found it full of noise, short
/// of useful lines and carrying old sessions: the same connection error hundreds
/// of times, a memory line for every megabyte, the extension's events of days
/// ago, an Xray log and a crash from long-gone connections.
public enum LogDigest {
    /// One line of the service log: its level word, the time the app received it
    /// (nil: it came with the core's buffer, before the app was listening) and its text.
    public struct Entry: Equatable, Sendable {
        public var level: String
        public var time: String?
        public var text: String

        public init(level: String, time: String?, text: String) {
            self.level = level; self.time = time; self.text = text
        }
    }

    /// The core's seconds since it started («[0031] »): they say nothing once
    /// copied; the app shows the time it received the line instead.
    private static let uptime = try! NSRegularExpression(pattern: #"^\[\d+\]\s*"#)
    /// A connection's number and age («[2639462006 15.12s] »): the same error of
    /// many connections differs only by them.
    private static let connection = try! NSRegularExpression(pattern: #"\[\d+ [0-9.]+[a-zµ]*\]\s*"#)

    public static func dropUptime(_ text: String) -> String {
        uptime.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// What makes two lines «the same»: the level and the text without connection numbers.
    static func key(_ entry: Entry) -> String {
        let text = entry.text
        return entry.level + " " + connection.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// 3.6.19 (the owner's screenshot: a screen of the same DNS warning): the live
    /// log shows a run of the same line (level and text without connection
    /// numbers) once. Returns each run's first index and its length, in order.
    public static func runs(levels: [Int32], texts: [String]) -> [(first: Int, count: Int)] {
        var result: [(first: Int, count: Int)] = []
        var lastKey: String?
        for (index, (level, text)) in zip(levels, texts).enumerated() {
            let key = Self.key(Entry(level: "\(level)", time: nil, text: text))
            if key == lastKey, let last = result.indices.last {
                result[last].count += 1
            } else {
                result.append((index, 1))
                lastKey = key
            }
        }
        return result
    }

    /// 3.5.14: the log keeps its order and its detail (the owner found 3.5's copy too
    /// short: every repeat stood once, at its first place). A run of the same line
    /// stands once with its count; a line stands where it came up to `keep` times,
    /// and its later repeats are counted on its last place:
    /// «(×37, последний раз 12:04:51)».
    public static func collapse(_ entries: [Entry], keep: Int = 3) -> [String] {
        var lines: [(entry: Entry, count: Int, last: String?)] = []
        var lastKey: String?
        var shown: [String: Int] = [:]
        var place: [String: Int] = [:]
        for entry in entries {
            let key = key(entry)
            if key == lastKey, let index = lines.indices.last {
                lines[index].count += 1
                if let time = entry.time { lines[index].last = time }
                continue
            }
            if shown[key, default: 0] < keep {
                shown[key, default: 0] += 1
                lines.append((entry, 1, entry.time))
                place[key] = lines.count - 1
                lastKey = key
            } else if let index = place[key] {
                lines[index].count += 1
                if let time = entry.time { lines[index].last = time }
                lastKey = nil
            }
        }
        return lines.map { item in
            var line = item.entry.level + " " + (item.entry.time ?? "--:--:--") + " " + item.entry.text
            if item.count > 1 {
                if let latest = item.last, latest != item.entry.time {
                    line += " " + CoreText.f("(×%@, последний раз %@)", "\(item.count)", latest)
                } else {
                    line += " " + CoreText.f("(×%@)", "\(item.count)")
                }
            }
            return line
        }
    }
}

extension TunnelEvents {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(of line: String) -> Date? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        return formatter.date(from: String(line[..<space]))
    }

    /// A start of the extension, successful or not («запуск, ядро …», «запуск не удался: …»).
    static func isStart(_ line: String) -> Bool {
        guard let space = line.firstIndex(of: " ") else { return false }
        return line[line.index(after: space)...].hasPrefix("запуск")
    }

    /// When the extension started, oldest first.
    public static func starts(_ lines: [String]) -> [Date] {
        lines.filter(isStart).compactMap(date(of:))
    }

    /// 3.5: the events worth copying — the last `sessions` starts of the
    /// extension and what followed, nothing older than `maxAge`; of the memory
    /// lines each session keeps its highest and its last.
    public static func digest(_ lines: [String], now: Date = Date(), sessions: Int = 3, maxAge: TimeInterval = 3 * 86_400) -> [String] {
        let oldest = now.addingTimeInterval(-maxAge)
        var recent = lines.filter { (date(of: $0) ?? now) >= oldest }
        let startIndices = recent.indices.filter { isStart(recent[$0]) }
        if startIndices.count > sessions { recent = Array(recent[startIndices[startIndices.count - sessions]...]) }
        // Sessions: from one start to the next.
        var keep = Array(repeating: true, count: recent.count)
        var segment: [Int] = []
        func closeSegment() {
            let memory = segment.filter { recent[$0].contains("[mem]") }
            guard memory.count > 2 else { segment = []; return }
            let highest = memory.max { used(recent[$0]) < used(recent[$1]) }
            for index in memory where index != memory.last && index != highest { keep[index] = false }
            segment = []
        }
        for index in recent.indices {
            if isStart(recent[index]) { closeSegment() }
            segment.append(index)
        }
        closeSegment()
        return recent.indices.filter { keep[$0] }.map { recent[$0] }
    }

    private static let usedPattern = try! NSRegularExpression(pattern: #"\[mem\] \D*([0-9]+(?:\.[0-9]+)?)"#)

    /// The memory in use a `[mem]` line reports, MiB.
    static func used(_ line: String) -> Double {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = usedPattern.firstMatch(in: line, range: range), let value = Range(match.range(at: 1), in: line) else { return 0 }
        return Double(line[value]) ?? 0
    }
}
