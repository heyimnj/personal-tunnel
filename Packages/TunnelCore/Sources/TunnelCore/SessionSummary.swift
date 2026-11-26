import Foundation

/// 3.6.8 (the owner): the last session's totals for analytics while the VPN is
/// off. Written once by the extension when the tunnel stops (`SharedKey.lastSession`),
/// so it is kept even when the app is not running then.
public struct SessionSummary: Equatable, Sendable {
    /// Seconds since 1970.
    public var started: Int64
    public var ended: Int64
    /// Bytes over the session.
    public var up: Int64
    public var down: Int64

    public init(started: Int64, ended: Int64, up: Int64, down: Int64) {
        self.started = started
        self.ended = ended
        self.up = up
        self.down = down
    }

    /// How long the session lasted, in seconds.
    public var seconds: Int64 { max(0, ended - started) }

    public var total: Int64 { up + down }

    /// 32 bytes: started, ended, up, down, little-endian.
    public var encoded: Data {
        var data = Data(capacity: 32)
        for value in [started, ended, up, down] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    public init?(encoded data: Data) {
        guard data.count == 32 else { return nil }
        let bytes = [UInt8](data)
        func value(_ offset: Int) -> Int64 {
            var result: UInt64 = 0
            for index in 0 ..< 8 { result |= UInt64(bytes[offset + index]) << (8 * UInt64(index)) }
            return Int64(bitPattern: result)
        }
        self.init(started: value(0), ended: value(8), up: value(16), down: value(24))
    }
}
