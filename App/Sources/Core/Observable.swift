import Foundation

/// A value with observers, for the main thread. Observers are released with
/// their owner; a store publishes only when the value really changed.
final class Observable<Value> {
    private struct Entry {
        weak var owner: AnyObject?
        let handler: (Value) -> Void
    }

    private var entries: [Entry] = []

    var value: Value {
        didSet { publish() }
    }

    init(_ value: Value) {
        self.value = value
    }

    func observe(_ owner: AnyObject, fireNow: Bool = true, _ handler: @escaping (Value) -> Void) {
        entries.append(Entry(owner: owner, handler: handler))
        if fireNow { handler(value) }
    }

    func removeObserver(_ owner: AnyObject) {
        entries.removeAll { $0.owner === owner || $0.owner == nil }
    }

    private func publish() {
        entries.removeAll { $0.owner == nil }
        for entry in entries { entry.handler(value) }
    }
}

extension Observable where Value: Equatable {
    /// Assigns and notifies only on a real change.
    func set(_ newValue: Value) {
        if value != newValue { value = newValue }
    }
}

/// An event without a value.
final class Signal {
    private var entries: [(owner: () -> AnyObject?, handler: () -> Void)] = []

    func observe(_ owner: AnyObject, _ handler: @escaping () -> Void) {
        entries.append(({ [weak owner] in owner }, handler))
    }

    func fire() {
        entries.removeAll { $0.owner() == nil }
        for entry in entries { entry.handler() }
    }
}
