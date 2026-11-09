import AppKit
import Darwin
import os

// CONTRACT: signatures are fixed. Bodies are implemented by the core workstream.

public enum StoreError: Error, Equatable {
    case unreadableDocument(UUID)
    case trashedDocument(UUID)
    case workspaceSaveBlocked
}

public struct AppPaths: Sendable {
    public let root: URL
    public var workspaceFile: URL { root.appendingPathComponent("workspace.json") }
    public var documentsDirectory: URL { root.appendingPathComponent("Documents", isDirectory: true) }
    public init(root: URL) { self.root = root }
    /// ~/Library/Application Support/BackgroundMemo
    public static func standard() -> AppPaths {
        AppPaths(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackgroundMemo", isDirectory: true))
    }
}

public struct LoadedWorkspace: Sendable {
    public var state: WorkspaceState
    /// Set when workspace.json was corrupt and moved aside to this URL.
    public var corruptBackup: URL?
    /// True when the existing workspace could not be read or backed up, so saving is unsafe.
    public var saveBlocked: Bool
}

public struct WorkspaceStore: Sendable {
    private static let logger = Logger(subsystem: "BackgroundMemo", category: "WorkspaceStore")
    private let paths: AppPaths
    private let saveGuard = WorkspaceSaveGuard()
    public init(paths: AppPaths) { self.paths = paths }

    /// Missing file: surviving documents reopen as tabs, or initial state when there are none.
    /// Corrupt file: backed up to workspace.corrupt-<timestamp>.json before the same recovery.
    /// Recovery is saved immediately; unreadable or unbacked-up files block saving this session.
    public func load() -> LoadedWorkspace {
        let manager = FileManager.default
        guard manager.fileExists(atPath: paths.workspaceFile.path) else {
            return recover(backup: nil, saveBlocked: false)
        }
        let data: Data
        do {
            data = try Data(contentsOf: paths.workspaceFile)
        } catch {
            saveGuard.block()
            Self.logger.error("Workspace read failed: \(String(describing: error), privacy: .public)")
            return LoadedWorkspace(state: recoveredState(), corruptBackup: nil, saveBlocked: true)
        }
        do {
            let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)
            guard !decoded.tabs.isEmpty, decoded.tabs.contains(where: { $0.id == decoded.selectedTabID })
            else { throw CocoaError(.coderReadCorrupt) }
            var state = decoded
            state.ensureFixedTabs()
            guard state.isValid else { throw CocoaError(.coderReadCorrupt) }
            if state != decoded && !saveGuard.isBlocked {
                do { try save(state) }
                catch { Self.logger.error("Migrated workspace save failed: \(String(describing: error), privacy: .public)") }
            }
            return LoadedWorkspace(state: state, corruptBackup: nil, saveBlocked: saveGuard.isBlocked)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let backup = paths.root.appendingPathComponent("workspace.corrupt-\(stamp)-\(UUID().uuidString).json")
            var backedUp = (try? manager.moveItem(at: paths.workspaceFile, to: backup)) != nil
            if !backedUp {
                backedUp = (try? manager.copyItem(at: paths.workspaceFile, to: backup)) != nil
            }
            if !backedUp {
                saveGuard.block()
                Self.logger.error("Could not back up corrupt workspace at \(self.paths.workspaceFile.path, privacy: .public)")
            }
            return recover(backup: backedUp ? backup : nil, saveBlocked: !backedUp)
        }
    }

    /// Atomic write.
    public func save(_ state: WorkspaceState) throws {
        guard !saveGuard.isBlocked else { throw StoreError.workspaceSaveBlocked }
        guard state.isValid else { throw CocoaError(.coderInvalidValue) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: paths.workspaceFile, options: .atomic)
    }

    private func recover(backup: URL?, saveBlocked: Bool) -> LoadedWorkspace {
        var state = recoveredState()
        state.ensureFixedTabs()
        if !saveBlocked && !saveGuard.isBlocked {
            do { try save(state) }
            catch { Self.logger.error("Recovered workspace save failed: \(String(describing: error), privacy: .public)") }
        }
        return LoadedWorkspace(state: state, corruptBackup: backup, saveBlocked: saveBlocked || saveGuard.isBlocked)
    }

    private func recoveredState() -> WorkspaceState {
        let documents = (try? FileManager.default.contentsOfDirectory(at: paths.documentsDirectory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let ids = documents.filter { $0.pathExtension.lowercased() == "rtfd" }
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.uuidString < $1.uuidString }
        guard !ids.isEmpty else { return .initial() }
        var state = WorkspaceState.initial()
        let recoveredTabs = ids.enumerated().map { index, id in
            let pane = Pane(documentID: id)
            return Tab(title: "메모 \(index + 1)", root: .pane(pane), focusedPaneID: pane.id)
        }
        state.tabs.removeAll { $0.kind == .memo }
        state.tabs.append(contentsOf: recoveredTabs)
        state.selectedTabID = recoveredTabs[0].id
        return state
    }
}

private final class WorkspaceSaveGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var blocked = false
    var isBlocked: Bool { lock.withLock { blocked } }
    func block() { lock.withLock { blocked = true } }
}

private extension WorkspaceState {
    var isValid: Bool {
        guard !tabs.isEmpty, tabs.contains(where: { $0.id == selectedTabID }),
              Set(tabs.map(\.id)).count == tabs.count else { return false }
        guard tabs.filter({ $0.kind == .planner }).count == 1,
              tabs.filter({ $0.kind == .todo }).count == 1,
              tabs.contains(where: { $0.kind == .memo }) else { return false }
        let panes = tabs.flatMap { $0.root.panes }
        guard Set(panes.map(\.id)).count == panes.count,
              Set(panes.map(\.documentID)).count == panes.count else { return false }
        let splitIDs = tabs.flatMap { $0.root.splitIDs }
        guard Set(splitIDs).count == splitIDs.count else { return false }
        return tabs.allSatisfy { tab in
            tab.root.panes.contains(where: { $0.id == tab.focusedPaneID }) && tab.root.validRatios
        }
    }
}

private extension SplitNode {
    var splitIDs: [UUID] {
        switch self {
        case .pane: []
        case .split(let split): [split.id] + split.first.splitIDs + split.second.splitIDs
        }
    }

    var validRatios: Bool {
        switch self {
        case .pane: true
        case .split(let split):
            split.ratio.isFinite && (0.1...0.9).contains(split.ratio)
                && split.first.validRatios && split.second.validRatios
        }
    }
}

@MainActor
public final class DocumentStore {
    private static let logger = Logger(subsystem: "BackgroundMemo", category: "DocumentStore")
    private let paths: AppPaths
    private let autosaveDelay: TimeInterval
    private let trashAction: @MainActor (URL) throws -> Void
    private var unreadableIDs: Set<UUID> = []
    private var trashedIDs: Set<UUID> = []
    private var pending: [UUID: PendingSave] = [:]

    private struct PendingSave {
        var task: Task<Void, Never>?
        let content: @MainActor () -> NSAttributedString
        let generation: UUID
    }

    public init(paths: AppPaths, autosaveDelay: TimeInterval = 1.0,
                trashAction: @escaping @MainActor (URL) throws -> Void = { file in
                    var resulting: NSURL?
                    try FileManager.default.trashItem(at: file, resultingItemURL: &resulting)
                }) {
        self.paths = paths
        self.autosaveDelay = autosaveDelay
        self.trashAction = trashAction
    }

    private func url(for id: UUID) -> URL {
        paths.documentsDirectory.appendingPathComponent("\(id.uuidString).rtfd", isDirectory: true)
    }

    /// Missing document: empty string. Present but unreadable: throws `unreadableDocument`
    /// and that ID is then never written by `save` or `flush`, which preserves the file.
    public func load(id: UUID) throws -> NSAttributedString {
        if unreadableIDs.contains(id) { throw StoreError.unreadableDocument(id) }
        let file = url(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return NSAttributedString(string: "") }
        do {
            return try NSAttributedString(url: file, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                          documentAttributes: nil)
        } catch {
            unreadableIDs.insert(id)
            pending.removeValue(forKey: id)?.task?.cancel()
            throw StoreError.unreadableDocument(id)
        }
    }

    /// Atomically writes RTFD including attachments, cancelling any pending autosave for this ID.
    public func save(_ text: NSAttributedString, id: UUID) throws {
        guard !unreadableIDs.contains(id) else { throw StoreError.unreadableDocument(id) }
        guard !trashedIDs.contains(id) else { throw StoreError.trashedDocument(id) }
        let manager = FileManager.default
        try manager.createDirectory(at: paths.documentsDirectory, withIntermediateDirectories: true)
        let destination = url(for: id)
        let temporary = paths.documentsDirectory.appendingPathComponent(".\(id.uuidString)-\(UUID().uuidString).rtfd", isDirectory: true)
        let wrapper = try text.fileWrapper(from: NSRange(location: 0, length: text.length),
                                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        do {
            try wrapper.write(to: temporary, options: [], originalContentsURL: nil)
            if manager.fileExists(atPath: destination.path) {
                let status = temporary.path.withCString { temporaryPath in
                    destination.path.withCString { destinationPath in
                        renameatx_np(AT_FDCWD, temporaryPath, AT_FDCWD, destinationPath, UInt32(RENAME_SWAP))
                    }
                }
                if status != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                try? manager.removeItem(at: temporary)
            } else {
                try manager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
        pending.removeValue(forKey: id)?.task?.cancel()
    }

    /// Debounced save: restarts the delay for this ID. The closure is read when the delay fires.
    public func scheduleSave(id: UUID, content: @escaping @MainActor () -> NSAttributedString) {
        guard !unreadableIDs.contains(id), !trashedIDs.contains(id) else { return }
        pending.removeValue(forKey: id)?.task?.cancel()
        let generation = UUID()
        pending[id] = PendingSave(task: nil, content: content, generation: generation)
        armSave(id: id, generation: generation)
    }

    /// Immediately attempts every pending autosave and returns IDs that failed.
    @discardableResult public func flush() -> [UUID] {
        var failed: [UUID] = []
        for id in Array(pending.keys).sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let entry = pending[id] else { continue }
            entry.task?.cancel()
            pending[id]?.task = nil
            do {
                try save(entry.content(), id: id)
            } catch {
                failed.append(id)
                Self.logger.error("Document save failed for \(id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
                armSave(id: id, generation: entry.generation, retry: true)
            }
        }
        return failed
    }

    private func armSave(id: UUID, generation: UUID, retry: Bool = false) {
        let delay = retry ? max(1, autosaveDelay) : max(0, autosaveDelay)
        pending[id]?.task = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, let entry = self.pending[id], entry.generation == generation else { return }
            do {
                try self.save(entry.content(), id: id)
            } catch {
                Self.logger.error("Document save failed for \(id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
                self.armSave(id: id, generation: generation, retry: true)
            }
        }
    }

    /// Cancels pending saves and moves the document to the system Trash. Missing file is not an error.
    public func trash(id: UUID) throws {
        if trashedIDs.contains(id) { return }
        let file = url(for: id)
        if FileManager.default.fileExists(atPath: file.path) { try trashAction(file) }
        pending.removeValue(forKey: id)?.task?.cancel()
        trashedIDs.insert(id)
    }
}
