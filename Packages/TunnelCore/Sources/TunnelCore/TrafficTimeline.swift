import Foundation

/// 3.5.23: the session's traffic over time, for «Трафик по времени» in analytics.
/// The extension notes the core's running totals on the timer it already has
/// (every two minutes, while the device lets it run) and keeps them in memory;
/// they reach the app with the memory sample it already stores (at most every
/// ten minutes): no wake-up and no write of their own.
public struct TrafficTimeline: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        /// Seconds since 1970.
        public var time: Int64
        /// The core's running totals, in bytes, since the tunnel started.
        public var up: Int64
        public var down: Int64

        public init(time: Int64, up: Int64, down: Int64) {
            self.time = time; self.up = up; self.down = down
        }
    }

    /// A day and a half at one sample per two minutes; older ones go first.
    public static let capacity = 1080

    public private(set) var samples: [Sample] = []

    public init(samples: [Sample] = []) { self.samples = samples }

    public mutating func append(_ sample: Sample) {
        if let last = samples.last, sample.time <= last.time { return }
        samples.append(sample)
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    /// 24 bytes a sample: time, up, down, little-endian.
    public var encoded: Data {
        var data = Data(capacity: samples.count * 24)
        for sample in samples {
            for value in [sample.time, sample.up, sample.down] {
                withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    public init?(encoded data: Data) {
        guard data.count % 24 == 0 else { return nil }
        let bytes = [UInt8](data)
        func value(_ offset: Int) -> Int64 {
            var raw: UInt64 = 0
            for index in 0 ..< 8 { raw |= UInt64(bytes[offset + index]) << (8 * UInt64(index)) }
            return Int64(bitPattern: raw)
        }
        samples = stride(from: 0, to: bytes.count, by: 24).map { Sample(time: value($0), up: value($0 + 8), down: value($0 + 16)) }
    }

    /// One column of the chart: what moved in `[start, start + width)`.
    public struct Bucket: Equatable, Sendable {
        public var start: Int64
        public var up: Int64
        public var down: Int64
        public var total: Int64 { up + down }
    }

    /// The session from `start` to the last point, in equal columns of `width`
    /// seconds. What moved between two points is spread evenly over the time
    /// between them (the device may have slept through several columns). A total
    /// lower than the one before (the core started again) counts from zero.
    /// `now`: the app's own latest totals, after the stored points.
    public func buckets(from start: Int64, width: Int64 = 120, now: Sample? = nil) -> [Bucket] {
        guard width > 0 else { return [] }
        var points = [Sample(time: start, up: 0, down: 0)] + samples.filter { $0.time >= start }
        if let now, now.time > (points.last?.time ?? start) { points.append(now) }
        guard let end = points.last?.time, end > start else { return [] }
        let count = Int((end - start + width - 1) / width)
        var up = [Double](repeating: 0, count: count), down = [Double](repeating: 0, count: count)
        for (previous, next) in zip(points, points.dropFirst()) {
            let span = Double(next.time - previous.time)
            guard span > 0 else { continue }
            let deltaUp = Double(next.up >= previous.up ? next.up - previous.up : next.up)
            let deltaDown = Double(next.down >= previous.down ? next.down - previous.down : next.down)
            var from = previous.time
            while from < next.time {
                let index = Int((from - start) / width)
                let to = min(next.time, start + Int64(index + 1) * width)
                let share = Double(to - from) / span
                if index < count { up[index] += deltaUp * share; down[index] += deltaDown * share }
                from = to
            }
        }
        return (0 ..< count).map { Bucket(start: start + Int64($0) * width, up: Int64(up[$0].rounded()), down: Int64(down[$0].rounded())) }
    }

    /// Columns joined so that there are at most `limit` (a long session stays readable):
    /// 2 minutes, then 10, 30, 60 and so on.
    public static func coarsened(_ buckets: [Bucket], width: Int64, limit: Int) -> (buckets: [Bucket], width: Int64) {
        guard limit > 0, buckets.count > limit else { return (buckets, width) }
        let steps: [Int64] = [5, 15, 30, 60, 120, 240, 720]
        let factor = steps.first { (buckets.count + Int($0) - 1) / Int($0) <= limit } ?? Int64((buckets.count + limit - 1) / limit)
        var joined: [Bucket] = []
        for chunk in stride(from: 0, to: buckets.count, by: Int(factor)) {
            let part = buckets[chunk ..< min(buckets.count, chunk + Int(factor))]
            joined.append(Bucket(start: part.first!.start, up: part.reduce(0) { $0 + $1.up }, down: part.reduce(0) { $0 + $1.down }))
        }
        return (joined, width * factor)
    }
}
