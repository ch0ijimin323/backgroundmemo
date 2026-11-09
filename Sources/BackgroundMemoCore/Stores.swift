import AppKit

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
    public static func standard() -> AppPaths { fatalError("unimplemented") }
}

public struct LoadedWorkspace: Sendable {
    public var state: WorkspaceState
    /// Set when workspace.json was corrupt and moved aside to this URL.
    public var corruptBackup: URL?
}

public struct WorkspaceStore: Sendable {
    public init(paths: AppPaths) { fatalError("unimplemented") }

    /// Missing file: initial state. Corrupt file: moved to workspace.corrupt-<timestamp>.json, and
    /// each .rtfd in Documents reopens as its own tab (initial state when there are none).
    public func load() -> LoadedWorkspace { fatalError("unimplemented") }

    /// Atomic write.
    public func save(_ state: WorkspaceState) throws { fatalError("unimplemented") }
}

@MainActor
public final class DocumentStore {
    public init(paths: AppPaths, autosaveDelay: TimeInterval = 1.0) { fatalError("unimplemented") }

    /// Missing document: empty string. Present but unreadable: throws `unreadableDocument`
    /// and that ID is then never written by `save` or `flush`, which preserves the file.
    public func load(id: UUID) throws -> NSAttributedString { fatalError("unimplemented") }

    /// Atomically writes RTFD including attachments, cancelling any pending autosave for this ID.
    public func save(_ text: NSAttributedString, id: UUID) throws { fatalError("unimplemented") }

    /// Debounced save: restarts the delay for this ID. The closure is read when the delay fires.
    public func scheduleSave(id: UUID, content: @escaping @MainActor () -> NSAttributedString) { fatalError("unimplemented") }

    /// Immediately writes every pending autosave.
    public func flush() { fatalError("unimplemented") }

    /// Cancels pending saves and moves the document to the system Trash. Missing file is not an error.
    public func trash(id: UUID) throws { fatalError("unimplemented") }
}
