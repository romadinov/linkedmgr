import Foundation

/// When posts go out: one slot per enabled weekday at a fixed local time.
///
/// Defaults follow the midweek, late-morning/midday windows that 2026 engagement
/// studies agree on (Sprout Social, Buffer); weekends are off. Tune them against your
/// own LinkedIn analytics in Settings.
struct PostingSchedule: Codable, Equatable {
    struct Slot: Codable, Equatable {
        var enabled: Bool
        var hour: Int
        var minute: Int
    }

    /// Keyed by `Calendar` weekday: 1 = Sunday … 7 = Saturday.
    var slots: [Int: Slot]
    /// Days to skip (holidays, vacation), stored as start-of-day dates.
    var skipDays: [Date] = []

    static let `default` = PostingSchedule(slots: [
        1: Slot(enabled: false, hour: 10, minute: 0),
        2: Slot(enabled: true, hour: 10, minute: 0),
        3: Slot(enabled: true, hour: 10, minute: 30),
        4: Slot(enabled: true, hour: 11, minute: 0),
        5: Slot(enabled: true, hour: 11, minute: 0),
        6: Slot(enabled: true, hour: 10, minute: 0),
        7: Slot(enabled: false, hour: 10, minute: 0),
    ])

    /// Posting times strictly after `start`, in order, up to `limit` of them.
    func upcomingSlots(after start: Date, limit: Int, calendar: Calendar = .current) -> [Date] {
        var result: [Date] = []
        var day = calendar.startOfDay(for: start)
        let skip = Set(skipDays.map { calendar.startOfDay(for: $0) })
        // Two years of days is plenty to find `limit` slots, and bounds a schedule with no enabled days.
        for _ in 0..<730 where result.count < limit {
            let weekday = calendar.component(.weekday, from: day)
            if let slot = slots[weekday], slot.enabled, !skip.contains(day),
               let time = calendar.date(bySettingHour: slot.hour, minute: slot.minute, second: 0, of: day),
               time > start {
                result.append(time)
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }

    /// The first slot after `start` that isn't already taken by a scheduled post.
    func nextFreeSlot(after start: Date, taken: [Date], calendar: Calendar = .current) -> Date? {
        let takenDays = Set(taken.map { calendar.startOfDay(for: $0) })
        return upcomingSlots(after: start, limit: 400, calendar: calendar)
            .first { !takenDays.contains(calendar.startOfDay(for: $0)) }
    }

    func slot(forWeekday weekday: Int) -> Slot {
        slots[weekday] ?? Slot(enabled: false, hour: 10, minute: 0)
    }
}

extension PostingSchedule {
    private static let key = "postingSchedule"

    static func load(from defaults: UserDefaults = .standard) -> PostingSchedule {
        guard let data = defaults.data(forKey: key),
              let schedule = try? JSONDecoder().decode(PostingSchedule.self, from: data) else { return .default }
        return schedule
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}
