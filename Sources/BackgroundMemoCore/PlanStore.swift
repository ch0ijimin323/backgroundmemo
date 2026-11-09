import Foundation

// CONTRACT: signatures are fixed. Bodies are implemented by the core workstream.

/// Planner entries by day ("yyyy-MM-dd") then hour (6...23). Blank entries are not stored.
public struct PlannerState: Codable, Equatable, Sendable {
    public var days: [String: [Int: String]]
    public init(days: [String: [Int: String]] = [:]) { self.days = days }

    public static let hours = 6...23

    /// Local-calendar key, "yyyy-MM-dd" with Gregorian digits regardless of the user's locale.
    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String { fatalError("unimplemented") }

    public func entry(day: String, hour: Int) -> String { fatalError("unimplemented") }

    /// Stores the text. Whitespace-only text removes the entry, and a day left empty is removed.
    /// Hours outside `hours` are ignored.
    public mutating func setEntry(day: String, hour: Int, text: String) { fatalError("unimplemented") }
}

public struct TodoItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var isDone: Bool
    public init(id: UUID = UUID(), title: String, isDone: Bool = false) {
        self.id = id
        self.title = title
        self.isDone = isDone
    }
}

/// Invariant: open items come first, then done items, each group keeping its relative order.
public struct TodoState: Codable, Equatable, Sendable {
    public var items: [TodoItem]
    public init(items: [TodoItem] = []) { self.items = items }

    /// Trims the title and inserts after the last open item. Blank titles add nothing and return nil.
    @discardableResult public mutating func add(title: String) -> TodoItem? { fatalError("unimplemented") }

    /// Done items move to the top of the done group; reopened items move to the end of the open group.
    public mutating func toggle(id: UUID) { fatalError("unimplemented") }

    /// A blank title leaves the item unchanged.
    public mutating func rename(id: UUID, title: String) { fatalError("unimplemented") }

    public mutating func delete(id: UUID) { fatalError("unimplemented") }
}

/// Owns planner.json and todos.json under `AppPaths.root`.
/// Missing file: empty state. Corrupt file: moved to <name>.corrupt-<timestamp>.json, then empty state.
/// Unreadable file, or a corrupt file that could not be backed up: empty state, and that file is
/// never written during this session; it is reported by `flush`.
@MainActor
public final class PlanStore {
    public private(set) var planner: PlannerState
    public private(set) var todos: TodoState

    public init(paths: AppPaths, autosaveDelay: TimeInterval = 1.0) { fatalError("unimplemented") }

    /// Applies the change and schedules a debounced atomic save.
    public func updatePlanner(_ change: (inout PlannerState) -> Void) { fatalError("unimplemented") }
    public func updateTodos(_ change: (inout TodoState) -> Void) { fatalError("unimplemented") }

    /// Writes pending changes now and returns the file names that failed ("planner.json", "todos.json").
    /// Failed saves stay pending and retry, matching `DocumentStore`.
    @discardableResult public func flush() -> [String] { fatalError("unimplemented") }
}
