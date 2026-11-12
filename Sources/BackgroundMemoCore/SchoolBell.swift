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

/// A school's bell schedule, in minutes from midnight, built from its settings.
public struct SchoolBell: Equatable, Sendable {
    public var classLength: Int
    /// Period number to start minute.
    public var startMinutes: [Int: Int]

    public init(periodStartMinutes: [Int], classLength: Int) {
        self.classLength = classLength
        startMinutes = Dictionary(uniqueKeysWithValues: periodStartMinutes.enumerated().map { ($0.offset + 1, $0.element) })
    }

    public init(settings: SchoolSettings) {
        self.init(periodStartMinutes: settings.periodStartMinutes, classLength: settings.classLength)
    }

    /// The class occupying `minute`, or nil for a non-slot value or free time.
    /// Periods without a bell time never appear. A class starting between slots, such as at 08:45,
    /// is labeled on the first slot inside it.
    public func lesson(atSlot minute: Int, in day: TimetableDay) -> SlotLesson? {
        guard PlannerState.isSlot(minute) else { return nil }
        for entry in day.entries {
            guard let start = startMinutes[entry.period], (start..<(start + classLength)).contains(minute) else { continue }
            return SlotLesson(entry: entry, startMinute: start, isFirstSlot: minute - start < 10)
        }
        return nil
    }
}
