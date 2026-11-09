import AppKit
import BackgroundMemoCore

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(description: message) }
}

private func temporaryPaths() throws -> AppPaths {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundMemoCoreChecks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return AppPaths(root: root)
}

@MainActor
private func check(_ name: String, _ body: @MainActor () async throws -> Void) async -> Bool {
    do {
        try await body()
        print("PASS \(name)")
        return true
    } catch {
        print("FAIL \(name): \(error)")
        return false
    }
}

@MainActor
private func run() async -> Int {
    var failures = 0
    func record(_ passed: Bool) { if !passed { failures += 1 } }

    record(await check("split and sibling promotion") {
        var state = WorkspaceState.initial()
        let original = state.selectedTab.root.panes[0]
        let second = try require(state.splitPane(id: original.id, axis: .horizontal), "split returned nil")
        try expect(state.selectedTab.root.panes.map(\.id) == [original.id, second.id], "split pane order")
        let result = state.closePane(id: original.id)
        try expect(result == .closedPane(documentID: original.documentID), "close result")
        try expect(state.selectedTab.root == .pane(second), "sibling not promoted")
        try expect(state.selectedTab.focusedPaneID == second.id, "invalid focus after close")
    })

    record(await check("closing last pane") {
        var state = WorkspaceState.initial()
        let frame = WindowFrame(x: 20, y: 30, width: 600, height: 400)
        state.windowFrame = frame
        let old = state.selectedTab.root.panes[0]
        try expect(state.closePane(id: old.id) == .replacedLastTab(documentID: old.documentID), "last pane result")
        try expect(state.tabs.count == 1 && state.selectedTab.root.panes.count == 1, "empty workspace")
        try expect(!state.allDocumentIDs.contains(old.documentID), "old document retained")
        try expect(state.windowFrame == frame, "closing last tab lost window frame")
        let second = state.addTab()
        let secondPane = second.root.panes[0]
        try expect(state.closePane(id: secondPane.id) == .closedTab(documentID: secondPane.documentID), "multi-tab last pane result")
        try expect(state.tabs.count == 1 && state.selectedTabID == state.tabs[0].id, "invalid selection after tab close")
    })

    record(await check("tab add move close") {
        var state = WorkspaceState.initial()
        let first = state.selectedTab.id
        let second = state.addTab()
        let third = state.addTab()
        try expect(second.title == "메모 2" && third.title == "메모 3", "tab titles")
        state.moveTab(from: 2, to: 0)
        try expect(state.tabs.map(\.id) == [third.id, first, second.id], "tab move")
        let documents = state.closeTab(id: third.id)
        try expect(documents.count == 1 && state.selectedTabID == first, "tab close selection")
        let replacement = state.addTab()
        try expect(replacement.title == "메모 3", "lowest unused title")
        state.selectTab(id: second.id)
        state.renameTab(id: second.id, title: "Named")
        try expect(state.selectedTab.title == "Named", "select or rename")
    })

    record(await check("focus wrap and ratio clamp") {
        var state = WorkspaceState.initial()
        let first = state.selectedTab.root.panes[0]
        let second = try require(state.splitPane(id: first.id, axis: .vertical), "split returned nil")
        state.moveFocus(delta: 1)
        try expect(state.selectedTab.focusedPaneID == first.id, "forward wrap")
        state.moveFocus(delta: -1)
        try expect(state.selectedTab.focusedPaneID == second.id, "backward wrap")
        guard case .split(let split) = state.selectedTab.root else { throw CheckFailure(description: "no split") }
        state.setRatio(splitID: split.id, ratio: -1)
        guard case .split(let low) = state.selectedTab.root else { throw CheckFailure(description: "no split") }
        try expect(low.ratio == 0.1, "lower clamp")
        state.setRatio(splitID: split.id, ratio: 5)
        guard case .split(let high) = state.selectedTab.root else { throw CheckFailure(description: "no split") }
        try expect(high.ratio == 0.9, "upper clamp")
        state.setRatio(splitID: split.id, ratio: .nan)
        guard case .split(let reset) = state.selectedTab.root else { throw CheckFailure(description: "no split") }
        try expect(reset.ratio == 0.5, "NaN ratio was not reset")
    })

    record(await check("JSON round trip and missing file") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = WorkspaceStore(paths: paths)
        try expect(store.load().state.tabs.count == 1, "missing workspace")
        var state = WorkspaceState.initial()
        _ = state.splitPane(id: state.selectedTab.root.panes[0].id, axis: .horizontal)
        state.windowFrame = WindowFrame(x: 1, y: 2, width: 300, height: 400)
        try store.save(state)
        try expect(store.load().state == state, "JSON round trip")
    })

    record(await check("corrupt JSON recovers surviving documents") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let docs = DocumentStore(paths: paths)
        let a = UUID(), b = UUID()
        try docs.save(NSAttributedString(string: "one"), id: a)
        try docs.save(NSAttributedString(string: "two"), id: b)
        try Data("{broken".utf8).write(to: paths.workspaceFile)
        let loaded = WorkspaceStore(paths: paths).load()
        try expect(loaded.corruptBackup != nil, "no corrupt backup")
        try expect(loaded.state.tabs.count == 2 && loaded.state.allDocumentIDs == Set([a, b]), "documents not recovered")
        try expect(FileManager.default.fileExists(atPath: loaded.corruptBackup!.path), "backup absent")
        try expect(!loaded.saveBlocked, "backed-up workspace blocked saving")
        try expect(WorkspaceStore(paths: paths).load().state.allDocumentIDs == Set([a, b]), "recovery was not saved immediately")
    })

    record(await check("missing JSON recovers documents immediately") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = UUID()
        try DocumentStore(paths: paths).save(NSAttributedString(string: "survivor"), id: id)
        let loaded = WorkspaceStore(paths: paths).load()
        try expect(loaded.state.allDocumentIDs == Set([id]), "missing JSON did not scan documents")
        try expect(!loaded.saveBlocked && loaded.corruptBackup == nil, "missing JSON recovery flags")
        try expect(FileManager.default.fileExists(atPath: paths.workspaceFile.path), "recovery was not saved in load")
    })

    record(await check("unreadable workspace blocks saving") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.workspaceFile, withIntermediateDirectories: false)
        let store = WorkspaceStore(paths: paths)
        let loaded = store.load()
        try expect(loaded.saveBlocked && loaded.corruptBackup == nil, "read failure was treated as corrupt JSON")
        try expect(FileManager.default.fileExists(atPath: paths.workspaceFile.path), "unreadable workspace moved")
        do { try store.save(.initial()); throw CheckFailure(description: "blocked workspace saved") }
        catch StoreError.workspaceSaveBlocked { }
    })

    record(await check("failed corrupt backup blocks saving") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.root.path); try? FileManager.default.removeItem(at: paths.root) }
        try Data("{broken".utf8).write(to: paths.workspaceFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: paths.root.path)
        let store = WorkspaceStore(paths: paths)
        let loaded = store.load()
        try expect(loaded.saveBlocked && loaded.corruptBackup == nil, "failed backup did not block saving")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.root.path)
        do { try store.save(.initial()); throw CheckFailure(description: "session save was not blocked") }
        catch StoreError.workspaceSaveBlocked { }
        try expect(try Data(contentsOf: paths.workspaceFile) == Data("{broken".utf8), "corrupt source changed")
    })

    record(await check("invalid-invariant JSON is corrupt") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = WorkspaceStore(paths: paths)
        var invalid = WorkspaceState.initial()
        invalid.tabs = []
        try JSONEncoder().encode(invalid).write(to: paths.workspaceFile)
        try expect(store.load().corruptBackup != nil, "empty tabs accepted")
        invalid = .initial()
        invalid.selectedTabID = UUID()
        try JSONEncoder().encode(invalid).write(to: paths.workspaceFile)
        try expect(store.load().corruptBackup != nil, "missing selected tab accepted")
        invalid = .initial()
        let pane = invalid.selectedTab.root.panes[0]
        invalid.tabs[0].root = .split(Split(axis: .horizontal, first: .pane(pane), second: .pane(pane)))
        try JSONEncoder().encode(invalid).write(to: paths.workspaceFile)
        try expect(store.load().corruptBackup != nil, "duplicate pane ID accepted")
        invalid = .initial()
        let splitPane = invalid.tabs[0].root.panes[0]
        let other = Pane()
        let splitID = UUID()
        invalid.tabs[0].root = .split(Split(id: splitID, axis: .horizontal,
            first: .pane(splitPane), second: .split(Split(id: splitID, axis: .vertical,
                first: .pane(other), second: .pane(Pane())))))
        try JSONEncoder().encode(invalid).write(to: paths.workspaceFile)
        try expect(store.load().corruptBackup != nil, "duplicate split ID accepted")
    })

    record(await check("RTFD formatting and image round trip") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = UUID()
        let text = NSMutableAttributedString(string: "Bold red ")
        text.addAttributes([.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.red],
                           range: NSRange(location: 0, length: 8))
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL/nwAAAABJRU5ErkJggg==")!
        text.append(NSAttributedString(attachment: NSTextAttachment(data: png, ofType: "public.png")))
        let store = DocumentStore(paths: paths)
        try store.save(text, id: id)
        let file = paths.documentsDirectory.appendingPathComponent("\(id.uuidString).rtfd", isDirectory: true)
        var isDirectory: ObjCBool = false
        try expect(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                   "RTFD was not saved as a package")
        let loaded = try store.load(id: id)
        try expect(loaded.string.hasPrefix("Bold red "), "text lost")
        let font = loaded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        try expect(font != nil && NSFontManager.shared.traits(of: font!).contains(.boldFontMask), "bold lost")
        let color = loaded.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        try expect(color != nil && color!.usingColorSpace(.deviceRGB)!.redComponent > 0.8, "color lost")
        let attachment = loaded.attribute(.attachment, at: loaded.length - 1, effectiveRange: nil) as? NSTextAttachment
        try expect(attachment != nil && attachment!.fileWrapper != nil, "image attachment lost")
        try expect(attachment!.fileWrapper!.regularFileContents != nil, "image data lost")
        try store.save(NSAttributedString(string: "replacement"), id: id)
        try expect(try store.load(id: id).string == "replacement", "replacement save failed")
        let files = try FileManager.default.contentsOfDirectory(atPath: paths.documentsDirectory.path)
        try expect(files == ["\(id.uuidString).rtfd"], "replacement left a temporary package")
    })

    record(await check("autosave debounce and flush") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = DocumentStore(paths: paths, autosaveDelay: 0.20)
        let id = UUID()
        let value = StringBox("first")
        let file = paths.documentsDirectory.appendingPathComponent("\(id.uuidString).rtfd")
        store.scheduleSave(id: id) { value.calls += 1; return NSAttributedString(string: value.text) }
        try await Task.sleep(for: .milliseconds(100))
        value.text = "second"
        store.scheduleSave(id: id) { value.calls += 1; return NSAttributedString(string: value.text) }
        try await Task.sleep(for: .milliseconds(120))
        try expect(!FileManager.default.fileExists(atPath: file.path), "autosave fired before latest delay")
        value.text = "latest"
        try await Task.sleep(for: .milliseconds(150))
        try expect(value.calls == 1, "debounce evaluated more than one closure")
        try expect(try store.load(id: id).string == "latest", "content was not read when delay fired")
        value.text = "flushed"
        store.scheduleSave(id: id) { NSAttributedString(string: value.text) }
        try expect(store.flush().isEmpty, "flush reported failure")
        try expect(try store.load(id: id).string == "flushed", "flush failed")
    })

    record(await check("failed save preserves original and retries") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.documentsDirectory.path); try? FileManager.default.removeItem(at: paths.root) }
        let store = DocumentStore(paths: paths, autosaveDelay: 0.08)
        let id = UUID()
        try store.save(NSAttributedString(string: "old"), id: id)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: paths.documentsDirectory.path)
        var saveFailed = false
        do { try store.save(NSAttributedString(string: "new"), id: id) }
        catch { saveFailed = true }
        try expect(saveFailed, "write unexpectedly succeeded")
        try expect(try store.load(id: id).string == "old", "failed save damaged previous document")
        let files = try FileManager.default.contentsOfDirectory(atPath: paths.documentsDirectory.path)
        try expect(files == ["\(id.uuidString).rtfd"], "failed save left a temporary package")
        store.scheduleSave(id: id) { NSAttributedString(string: "retry") }
        try await Task.sleep(for: .milliseconds(160))
        try expect(store.flush() == [id], "failed flush did not return pending ID")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.documentsDirectory.path)
        try await Task.sleep(for: .milliseconds(1200))
        try expect(try store.load(id: id).string == "retry", "autosave did not retry after failure")
        try expect(store.flush().isEmpty, "successful retry remained pending")
    })

    record(await check("Trash on close") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fakeTrash = paths.root.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        let id = UUID()
        let file = paths.documentsDirectory.appendingPathComponent("\(id.uuidString).rtfd", isDirectory: true)
        let destination = fakeTrash.appendingPathComponent(file.lastPathComponent, isDirectory: true)
        let store = DocumentStore(paths: paths, autosaveDelay: 0.02) { source in
            try FileManager.default.moveItem(at: source, to: fakeTrash.appendingPathComponent(source.lastPathComponent))
        }
        try store.save(NSAttributedString(string: "trash me"), id: id)
        store.scheduleSave(id: id) { NSAttributedString(string: "resurrect") }
        try store.trash(id: id)
        try expect(!FileManager.default.fileExists(atPath: file.path), "document still at source")
        try expect(FileManager.default.fileExists(atPath: destination.path), "document was deleted instead of moved")
        try await Task.sleep(for: .milliseconds(60))
        try expect(!FileManager.default.fileExists(atPath: file.path), "pending save resurrected document")
        store.scheduleSave(id: id) { NSAttributedString(string: "resurrect") }
        try expect(store.flush().isEmpty, "trashed document entered pending saves")
        do { try store.save(NSAttributedString(string: "resurrect"), id: id); throw CheckFailure(description: "trashed document saved") }
        catch StoreError.trashedDocument { }
        try expect(!FileManager.default.fileExists(atPath: file.path), "explicit save resurrected document")
    })

    record(await check("failed Trash leaves document writable") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = UUID()
        let store = DocumentStore(paths: paths, trashAction: { _ in throw CheckFailure(description: "injected Trash failure") })
        try store.save(NSAttributedString(string: "before"), id: id)
        do { try store.trash(id: id); throw CheckFailure(description: "Trash unexpectedly succeeded") }
        catch let error as CheckFailure { try expect(error.description == "injected Trash failure", "Trash unexpectedly succeeded") }
        try store.save(NSAttributedString(string: "after"), id: id)
        try expect(try store.load(id: id).string == "after", "failed Trash blocked future saves")
    })

    record(await check("unreadable document preserved") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.documentsDirectory, withIntermediateDirectories: true)
        let id = UUID()
        let file = paths.documentsDirectory.appendingPathComponent("\(id.uuidString).rtfd")
        let original = Data("not an RTFD package".utf8)
        try original.write(to: file)
        let store = DocumentStore(paths: paths, autosaveDelay: 0.01)
        store.scheduleSave(id: id) { NSAttributedString(string: "queued overwrite") }
        do { _ = try store.load(id: id); throw CheckFailure(description: "invalid document loaded") }
        catch StoreError.unreadableDocument(let failedID) { try expect(failedID == id, "wrong unreadable ID") }
        do { try store.save(NSAttributedString(string: "overwrite"), id: id); throw CheckFailure(description: "save succeeded") }
        catch StoreError.unreadableDocument { }
        store.scheduleSave(id: id) { NSAttributedString(string: "overwrite") }
        store.flush()
        try await Task.sleep(for: .milliseconds(50))
        try expect(try Data(contentsOf: file) == original, "unreadable file changed")
    })

    record(await check("unreadable RTFD packages preserved") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.documentsDirectory, withIntermediateDirectories: true)
        for contents in [Data(), Data("not RTF".utf8)] {
            let id = UUID()
            let package = paths.documentsDirectory.appendingPathComponent("\(id.uuidString).rtfd", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
            if !contents.isEmpty { try contents.write(to: package.appendingPathComponent("TXT.rtf")) }
            let store = DocumentStore(paths: paths, autosaveDelay: 0.01)
            do { _ = try store.load(id: id); throw CheckFailure(description: "bad package loaded") }
            catch StoreError.unreadableDocument { }
            do { try store.save(NSAttributedString(string: "overwrite"), id: id); throw CheckFailure(description: "bad package overwritten") }
            catch StoreError.unreadableDocument { }
            store.scheduleSave(id: id) { NSAttributedString(string: "overwrite") }
            try expect(store.flush().isEmpty, "unreadable package entered pending saves")
            let entries = try FileManager.default.contentsOfDirectory(atPath: package.path)
            if contents.isEmpty {
                try expect(entries.isEmpty, "empty package changed")
            } else {
                try expect(entries == ["TXT.rtf"], "package entries changed")
                try expect(try Data(contentsOf: package.appendingPathComponent("TXT.rtf")) == contents, "package bytes changed")
            }
        }
    })

    print("\(failures == 0 ? "All checks passed" : "\(failures) check(s) failed")")
    return failures
}

private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw CheckFailure(description: message) }
    return value
}

@MainActor
private final class StringBox {
    var text: String
    var calls = 0
    init(_ text: String) { self.text = text }
}

@main
struct CoreChecks {
    @MainActor static func main() async {
        let failures = await run()
        if failures != 0 { exit(1) }
    }
}
