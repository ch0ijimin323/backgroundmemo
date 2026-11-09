import Foundation

/// A class as it appears in one planner slot.
public struct SlotLesson: Equatable, Sendable {
    public var entry: TimetableEntry
    public var startMinute: Int
    /// True only for the slot where the class begins.
    public var isFirstSlot: Bool
    public init(entry: TimetableEntry, startMinute: Int, isFirstSlot: Bool) {
        self.entry = entry
        self.startMinute = startMinute
        self.isFirstSlot = isFirstSlot
    }
}

/// The school's bell schedule, in minutes from midnight.
public enum SchoolBell {
    public static let classLength = 50
    public static let startMinutes: [Int: Int] = [
        1: 8 * 60 + 40,
        2: 9 * 60 + 40,
        3: 10 * 60 + 40,
        4: 11 * 60 + 40,
        5: 13 * 60 + 30,
        6: 14 * 60 + 30,
        7: 15 * 60 + 30,
        8: 16 * 60 + 20,
    ]

    /// The class occupying `minute`, or nil for a non-slot value or free time.
    /// Periods without a bell time never appear.
    public static func lesson(atSlot minute: Int, in day: TimetableDay) -> SlotLesson? {
        guard PlannerState.isSlot(minute) else { return nil }
        for entry in day.entries {
            guard let start = startMinutes[entry.period], (start..<(start + classLength)).contains(minute) else { continue }
            return SlotLesson(entry: entry, startMinute: start, isFirstSlot: minute == start)
        }
        return nil
    }
}
