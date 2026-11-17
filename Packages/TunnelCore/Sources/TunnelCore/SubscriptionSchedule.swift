import Foundation

/// 3.2.10: when a subscription is due for its automatic update — once every 24
/// hours, or once a day after a chosen hour (7:00, say): the first time the app
/// is open after that hour, if the subscription was not updated since.
public enum SubscriptionSchedule {
    /// The setting's value for «every 24 hours».
    public static let everyDay = -1
    public static let interval: TimeInterval = 24 * 60 * 60

    /// `hour`: `everyDay`, or 0–23.
    public static func isDue(updatedAt: Date?, now: Date = Date(), hour: Int, calendar: Calendar = .current) -> Bool {
        guard let updatedAt else { return true }
        guard (0 ... 23).contains(hour) else { return now.timeIntervalSince(updatedAt) >= interval }
        return updatedAt < lastOccurrence(of: hour, before: now, calendar: calendar)
    }

    /// The latest moment at `hour`:00 that is not after `now`.
    public static func lastOccurrence(of hour: Int, before now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        if today <= now { return today }
        return calendar.date(byAdding: .day, value: -1, to: today) ?? today
    }
}
