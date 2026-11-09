import Foundation
import os

// CONTRACT: signatures are fixed. Bodies are implemented by the core workstream.

/// Planner entries by day ("yyyy-MM-dd") then hour (6...23). Blank entries are not stored.
public struct PlannerState: Codable, Equatable, Sendable {
    public var days: [String: [Int: String]]
    public init(days: [String: [Int: String]] = [:]) { self.days = days }

    public static let hours = 6...23

    /// Local-calendar key, "yyyy-MM-dd" with Gregorian digits regardless of the user's locale.
    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        func padded(_ value: Int, width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(padded(parts.year ?? 0, width: 4))-\(padded(parts.month ?? 0, width: 2))-\(padded(parts.day ?? 0, width: 2))"
    }

    public func entry(day: String, hour: Int) -> String { days[day]?[hour] ?? "" }

    /// Stores the text. Whitespace-only text removes the entry, and a day left empty is removed.
    /// Hours outside `hours` are ignored.
    public mutating func setEntry(day: String, hour: Int, text: String) {
        guard Self.hours.contains(hour) else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            days[day]?[hour] = nil
            if days[day]?.isEmpty == true { days[day] = nil }
        } else {
            days[day, default: [:]][hour] = text
        }
    }
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
    public init(items: [TodoItem] = []) {
        self.items = items.filter { !$0.isDone } + items.filter(\.isDone)
    }

    private enum CodingKeys: String, CodingKey { case items }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(items: try container.decode([TodoItem].self, forKey: .items))
    }

    /// Trims the title and inserts after the last open item. Blank titles add nothing and return nil.
    @discardableResult public mutating func add(title: String) -> TodoItem? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let item = TodoItem(title: title)
        items.insert(item, at: items.firstIndex(where: \.isDone) ?? items.endIndex)
        return item
    }

    /// Done items move to the top of the done group; reopened items move to the end of the open group.
    public mutating func toggle(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.isDone.toggle()
        items.insert(item, at: items.firstIndex(where: \.isDone) ?? items.endIndex)
    }

    /// A blank title leaves the item unchanged.
    public mutating func rename(id: UUID, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].title = title
    }

    public mutating func delete(id: UUID) {
        items.removeAll { $0.id == id }
    }
}

/// Owns planner.json and todos.json under `AppPaths.root`.
/// Missing file: empty state. Corrupt file: moved to <name>.corrupt-<timestamp>.json, then empty state.
/// Unreadable file, or a corrupt file that could not be backed up: empty state, and that file is
/// never written during this session; it is reported by `flush`.
@MainActor
public final class PlanStore {
    private static let logger = Logger(subsystem: "BackgroundMemo", category: "PlanStore")
    private enum FileKind: String, CaseIterable {
        case planner = "planner.json"
        case todos = "todos.json"
    }
    private struct Pending {
        var task: Task<Void, Never>?
        let generation: UUID
    }

    public private(set) var planner: PlannerState
    public private(set) var todos: TodoState
    private let paths: AppPaths
    private let autosaveDelay: TimeInterval
    private var blocked: Set<FileKind>
    private var pending: [FileKind: Pending] = [:]

    public init(paths: AppPaths, autosaveDelay: TimeInterval = 1.0) {
        self.paths = paths
        self.autosaveDelay = autosaveDelay
        let loadedPlanner = Self.load(PlannerState(), from: paths.root.appendingPathComponent(FileKind.planner.rawValue))
        let loadedTodos = Self.load(TodoState(), from: paths.root.appendingPathComponent(FileKind.todos.rawValue))
        planner = loadedPlanner.state
        todos = loadedTodos.state
        blocked = Set([FileKind.planner, .todos].filter {
            $0 == .planner ? loadedPlanner.blocked : loadedTodos.blocked
        })
    }

    /// Applies the change and schedules a debounced atomic save.
    public func updatePlanner(_ change: (inout PlannerState) -> Void) {
        let previous = planner
        change(&planner)
        if planner != previous { schedule(.planner) }
    }
    public func updateTodos(_ change: (inout TodoState) -> Void) {
        let previous = todos
        change(&todos)
        if todos != previous { schedule(.todos) }
    }

    /// Writes pending changes now and returns the file names that failed ("planner.json", "todos.json").
    /// Failed saves stay pending and retry, matching `DocumentStore`.
    @discardableResult public func flush() -> [String] {
        var failed = blocked
        for kind in FileKind.allCases where pending[kind] != nil {
            guard let entry = pending[kind] else { continue }
            entry.task?.cancel()
            pending[kind]?.task = nil
            do { try write(kind) }
            catch {
                failed.insert(kind)
                Self.logger.error("\(kind.rawValue, privacy: .public) save failed: \(String(describing: error), privacy: .public)")
                if !blocked.contains(kind) { arm(kind, generation: entry.generation, retry: true) }
            }
        }
        return FileKind.allCases.filter { failed.contains($0) }.map(\.rawValue)
    }

    private static func load<State: Decodable>(_ empty: State, from file: URL) -> (state: State, blocked: Bool) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else { return (empty, false) }
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch {
            logger.error("\(file.lastPathComponent, privacy: .public) read failed: \(String(describing: error), privacy: .public)")
            return (empty, true)
        }
        do { return (try JSONDecoder().decode(State.self, from: data), false) }
        catch {
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let base = file.deletingPathExtension().lastPathComponent
            let backup = file.deletingLastPathComponent().appendingPathComponent("\(base).corrupt-\(stamp)-\(UUID().uuidString).json")
            let moved = (try? manager.moveItem(at: file, to: backup)) != nil
            let backedUp = moved || (try? manager.copyItem(at: file, to: backup)) != nil
            if !backedUp {
                logger.error("Could not back up corrupt \(file.lastPathComponent, privacy: .public)")
            }
            return (empty, !backedUp)
        }
    }

    private func schedule(_ kind: FileKind) {
        pending.removeValue(forKey: kind)?.task?.cancel()
        let generation = UUID()
        pending[kind] = Pending(task: nil, generation: generation)
        if !blocked.contains(kind) { arm(kind, generation: generation) }
    }

    private func arm(_ kind: FileKind, generation: UUID, retry: Bool = false) {
        let delay = retry ? max(1, autosaveDelay) : max(0, autosaveDelay)
        pending[kind]?.task = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, self.pending[kind]?.generation == generation else { return }
            do { try self.write(kind) }
            catch {
                Self.logger.error("\(kind.rawValue, privacy: .public) save failed: \(String(describing: error), privacy: .public)")
                if !self.blocked.contains(kind) { self.arm(kind, generation: generation, retry: true) }
            }
        }
    }

    private func write(_ kind: FileKind) throws {
        guard !blocked.contains(kind) else { throw PlanStoreError.saveBlocked(kind.rawValue) }
        let data: Data
        switch kind {
        case .planner: data = try JSONEncoder().encode(planner)
        case .todos: data = try JSONEncoder().encode(todos)
        }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try data.write(to: paths.root.appendingPathComponent(kind.rawValue), options: .atomic)
        pending.removeValue(forKey: kind)?.task?.cancel()
    }
}

private enum PlanStoreError: Error {
    case saveBlocked(String)
}
