import AppKit
import Darwin

// CONTRACT: signatures are fixed. Bodies are implemented by the core workstream.

public enum StoreError: Error, Equatable {
    case unreadableDocument(UUID)
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
}

public struct WorkspaceStore: Sendable {
    private let paths: AppPaths
    public init(paths: AppPaths) { self.paths = paths }

    /// Missing file: initial state. Corrupt file: moved to workspace.corrupt-<timestamp>.json, and
    /// each .rtfd in Documents reopens as its own tab (initial state when there are none).
    public func load() -> LoadedWorkspace {
        let manager = FileManager.default
        guard manager.fileExists(atPath: paths.workspaceFile.path) else {
            return LoadedWorkspace(state: .initial(), corruptBackup: nil)
        }
        do {
            let state = try JSONDecoder().decode(WorkspaceState.self, from: Data(contentsOf: paths.workspaceFile))
            guard state.isValid else { throw CocoaError(.coderReadCorrupt) }
            return LoadedWorkspace(state: state, corruptBackup: nil)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let backup = paths.root.appendingPathComponent("workspace.corrupt-\(stamp)-\(UUID().uuidString).json")
            let moved = (try? manager.moveItem(at: paths.workspaceFile, to: backup)) != nil
            let documents = (try? manager.contentsOfDirectory(at: paths.documentsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            let ids = documents.filter { $0.pathExtension.lowercased() == "rtfd" }
                .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
                .sorted { $0.uuidString < $1.uuidString }
            var state = WorkspaceState.initial()
            if !ids.isEmpty {
                state.tabs = ids.enumerated().map { index, id in
                    let pane = Pane(documentID: id)
                    return Tab(title: "메모 \(index + 1)", root: .pane(pane), focusedPaneID: pane.id)
                }
                state.selectedTabID = state.tabs[0].id
            }
            return LoadedWorkspace(state: state, corruptBackup: moved ? backup : nil)
        }
    }

    /// Atomic write.
    public func save(_ state: WorkspaceState) throws {
        guard state.isValid else { throw CocoaError(.coderInvalidValue) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: paths.workspaceFile, options: .atomic)
    }
}

private extension WorkspaceState {
    var isValid: Bool {
        guard !tabs.isEmpty, tabs.contains(where: { $0.id == selectedTabID }),
              Set(tabs.map(\.id)).count == tabs.count else { return false }
        let panes = tabs.flatMap { $0.root.panes }
        guard Set(panes.map(\.id)).count == panes.count,
              Set(panes.map(\.documentID)).count == panes.count else { return false }
        return tabs.allSatisfy { tab in
            tab.root.panes.contains(where: { $0.id == tab.focusedPaneID }) && tab.root.validRatios
        }
    }
}

private extension SplitNode {
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
    private let paths: AppPaths
    private let autosaveDelay: TimeInterval
    private var unreadableIDs: Set<UUID> = []
    private var pending: [UUID: PendingSave] = [:]

    private struct PendingSave {
        let task: Task<Void, Never>
        let content: @MainActor () -> NSAttributedString
    }

    public init(paths: AppPaths, autosaveDelay: TimeInterval = 1.0) {
        self.paths = paths
        self.autosaveDelay = autosaveDelay
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
            pending.removeValue(forKey: id)?.task.cancel()
            throw StoreError.unreadableDocument(id)
        }
    }

    /// Atomically writes RTFD including attachments, cancelling any pending autosave for this ID.
    public func save(_ text: NSAttributedString, id: UUID) throws {
        pending.removeValue(forKey: id)?.task.cancel()
        guard !unreadableIDs.contains(id) else { throw StoreError.unreadableDocument(id) }
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
    }

    /// Debounced save: restarts the delay for this ID. The closure is read when the delay fires.
    public func scheduleSave(id: UUID, content: @escaping @MainActor () -> NSAttributedString) {
        guard !unreadableIDs.contains(id) else { return }
        pending.removeValue(forKey: id)?.task.cancel()
        let delay = autosaveDelay
        let task = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, let entry = self.pending.removeValue(forKey: id) else { return }
            try? self.save(entry.content(), id: id)
        }
        pending[id] = PendingSave(task: task, content: content)
    }

    /// Immediately writes every pending autosave.
    public func flush() {
        let saves = pending
        pending.removeAll()
        for (id, entry) in saves {
            entry.task.cancel()
            if !unreadableIDs.contains(id) { try? save(entry.content(), id: id) }
        }
    }

    /// Cancels pending saves and moves the document to the system Trash. Missing file is not an error.
    public func trash(id: UUID) throws {
        pending.removeValue(forKey: id)?.task.cancel()
        let file = url(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        var resulting: NSURL?
        try FileManager.default.trashItem(at: file, resultingItemURL: &resulting)
    }
}
