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
        let old = state.selectedTab.root.panes[0]
        try expect(state.closePane(id: old.id) == .replacedLastTab(documentID: old.documentID), "last pane result")
        try expect(state.tabs.count == 1 && state.selectedTab.root.panes.count == 1, "empty workspace")
        try expect(!state.allDocumentIDs.contains(old.documentID), "old document retained")
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
        let store = DocumentStore(paths: paths, autosaveDelay: 0.15)
        let id = UUID()
        let value = StringBox("first")
        store.scheduleSave(id: id) { NSAttributedString(string: value.text) }
        value.text = "second"
        store.scheduleSave(id: id) { NSAttributedString(string: value.text) }
        try await Task.sleep(for: .milliseconds(250))
        try expect(try store.load(id: id).string == "second", "debounce did not read latest content")
        value.text = "flushed"
        store.scheduleSave(id: id) { NSAttributedString(string: value.text) }
        store.flush()
        try expect(try store.load(id: id).string == "flushed", "flush failed")
    })

    record(await check("Trash on close") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.documentsDirectory, withIntermediateDirectories: true)
        let id = UUID()
        let file = paths.documentsDirectory.appendingPathComponent("\(id.uuidString).rtfd")
        try Data("temporary test file".utf8).write(to: file)
        try DocumentStore(paths: paths).trash(id: id)
        try expect(!FileManager.default.fileExists(atPath: file.path), "document still at source")
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

    print("\(failures == 0 ? "All checks passed" : "\(failures) check(s) failed")")
    return failures
}

private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw CheckFailure(description: message) }
    return value
}

@MainActor
private final class StringBox { var text: String; init(_ text: String) { self.text = text } }

@main
struct CoreChecks {
    @MainActor static func main() async {
        let failures = await run()
        if failures != 0 { exit(1) }
    }
}
