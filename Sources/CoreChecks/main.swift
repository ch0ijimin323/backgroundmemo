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
        try expect(state.tabs.count == 3 && state.selectedTab.root.panes.count == 1, "last memo was not replaced")
        try expect(!state.allDocumentIDs.contains(old.documentID), "old document retained")
        try expect(state.windowFrame == frame, "closing last tab lost window frame")
        let second = state.addTab()
        let secondPane = second.root.panes[0]
        try expect(state.closePane(id: secondPane.id) == .closedTab(documentID: secondPane.documentID), "multi-tab last pane result")
        try expect(state.tabs.count == 3 && state.selectedTab.kind == .memo, "invalid selection after tab close")
    })

    record(await check("tab add move close") {
        var state = WorkspaceState.initial()
        let plannerID = state.tabs[0].id
        let todoID = state.tabs[1].id
        let first = state.selectedTab.id
        let second = state.addTab()
        let third = state.addTab()
        try expect(second.title == "메모 2" && third.title == "메모 3", "tab titles")
        state.moveTab(from: 4, to: 0)
        try expect(state.tabs.map(\.id) == [third.id, plannerID, todoID, first, second.id], "tab move")
        let documents = state.closeTab(id: third.id)
        try expect(documents.count == 1 && state.selectedTabID == first, "tab close selection")
        let replacement = state.addTab()
        try expect(replacement.title == "메모 3", "lowest unused title")
        state.selectTab(id: second.id)
        state.renameTab(id: second.id, title: "Named")
        try expect(state.selectedTab.title == "Named", "select or rename")
    })

    record(await check("fixed tab rules") {
        var state = WorkspaceState.initial()
        try expect(state.tabs.map(\.kind) == [.planner, .todo, .memo], "initial tab kinds")
        try expect(state.tabs.map(\.title) == ["계획", "할 일", "메모 1"], "initial titles")
        try expect(state.selectedTab.kind == .memo, "initial selection")
        let planner = state.tabs[0]
        let todo = state.tabs[1]
        let old = state
        try expect(state.closeTab(id: planner.id).isEmpty, "planner closed")
        try expect(state.closePane(id: todo.root.panes[0].id) == .notFound, "todo pane closed")
        try expect(state.splitPane(id: planner.root.panes[0].id, axis: .horizontal) == nil, "planner split")
        try expect(state == old, "fixed tab operation changed state")
        state.moveTab(from: 0, to: 2)
        try expect(state.tabs.map(\.kind) == [.todo, .memo, .planner], "fixed tab did not reorder")
        state.ensureFixedTabs()
        try expect(state.tabs.map(\.kind) == [.todo, .memo, .planner], "ensureFixedTabs changed existing order")
        let memo = state.addTab()
        try expect(memo.title == "메모 2", "fixed titles affected memo numbering")
        try expect(state.tabs.filter { $0.kind == .memo }.count == 2, "memo tab not added")
    })

    record(await check("legacy workspace migration preserves memos") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var legacy = WorkspaceState.initial()
        legacy.tabs.removeAll { $0.kind != .memo }
        let originalPane = legacy.selectedTab.root.panes[0]
        _ = legacy.splitPane(id: originalPane.id, axis: .vertical)
        let originalMemo = legacy.tabs[0]
        let frame = WindowFrame(x: 1, y: 2, width: 500, height: 300)
        legacy.windowFrame = frame
        var json = try require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any], "legacy JSON shape")
        var tabs = try require(json["tabs"] as? [[String: Any]], "legacy tabs shape")
        for index in tabs.indices { tabs[index].removeValue(forKey: "kind") }
        json["tabs"] = tabs
        try JSONSerialization.data(withJSONObject: json).write(to: paths.workspaceFile)
        let store = WorkspaceStore(paths: paths)
        let loaded = store.load()
        try expect(loaded.corruptBackup == nil && !loaded.saveBlocked, "legacy JSON treated as corrupt")
        try expect(loaded.state.tabs.map(\.kind) == [.planner, .todo, .memo], "fixed tabs missing from migration")
        try expect(loaded.state.tabs[2] == originalMemo, "legacy memo or split changed")
        try expect(loaded.state.windowFrame == frame && loaded.state.selectedTabID == originalMemo.id, "legacy frame or selection changed")
        try expect(store.load().state == loaded.state, "migrated workspace was not saved immediately")
        let documents = (try? FileManager.default.contentsOfDirectory(at: paths.documentsDirectory,
            includingPropertiesForKeys: nil)) ?? []
        try expect(documents.isEmpty, "fixed placeholder document was created")
    })

    record(await check("duplicate fixed tabs are normalized") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var state = WorkspaceState.initial()
        let original = state.tabs[0]
        let pane = Pane()
        let duplicate = Tab(title: "duplicate", kind: .planner, root: .pane(pane), focusedPaneID: pane.id)
        state.tabs.append(duplicate)
        state.selectedTabID = duplicate.id
        try JSONEncoder().encode(state).write(to: paths.workspaceFile)
        let loaded = WorkspaceStore(paths: paths).load()
        try expect(loaded.corruptBackup == nil, "duplicate fixed tab treated as corrupt")
        try expect(loaded.state.tabs.map(\.kind) == [.planner, .todo, .memo], "duplicate fixed tab survived")
        try expect(loaded.state.selectedTabID == original.id, "selected duplicate was not remapped")
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
        try expect(store.load().state.tabs.count == 3, "missing workspace")
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
        try expect(loaded.state.tabs.count == 4 && memoDocumentIDs(loaded.state) == Set([a, b]), "documents not recovered")
        try expect(FileManager.default.fileExists(atPath: loaded.corruptBackup!.path), "backup absent")
        try expect(!loaded.saveBlocked, "backed-up workspace blocked saving")
        try expect(memoDocumentIDs(WorkspaceStore(paths: paths).load().state) == Set([a, b]), "recovery was not saved immediately")
    })

    record(await check("missing JSON recovers documents immediately") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = UUID()
        try DocumentStore(paths: paths).save(NSAttributedString(string: "survivor"), id: id)
        let loaded = WorkspaceStore(paths: paths).load()
        try expect(memoDocumentIDs(loaded.state) == Set([id]), "missing JSON did not scan documents")
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

    record(await check("planner entries and Gregorian day key") {
        var planner = PlannerState()
        planner.setEntry(day: "2026-11-10", hour: 5, text: "ignored")
        planner.setEntry(day: "2026-11-10", hour: 24, text: "ignored")
        try expect(planner.days.isEmpty, "out-of-range hour stored")
        planner.setEntry(day: "2026-11-10", hour: 6, text: "  morning  ")
        planner.setEntry(day: "2026-11-10", hour: 23, text: "night")
        try expect(planner.entry(day: "2026-11-10", hour: 6) == "  morning  ", "entry text changed")
        planner.setEntry(day: "2026-11-10", hour: 6, text: " \n ")
        try expect(planner.entry(day: "2026-11-10", hour: 6).isEmpty && planner.days.count == 1, "blank entry not removed")
        planner.setEntry(day: "2026-11-10", hour: 23, text: "\t")
        try expect(planner.days.isEmpty, "empty day not removed")
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let date = try require(gregorian.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12)), "date creation")
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = gregorian.timeZone
        try expect(PlannerState.dayKey(for: date, calendar: buddhist) == "2026-11-10", "day key used non-Gregorian year")
        let encoded = try JSONEncoder().encode(PlannerState(days: ["2026-11-10": [6: "early", 23: "late"]]))
        let decoded = try JSONDecoder().decode(PlannerState.self, from: encoded)
        try expect(decoded.days["2026-11-10"] == [6: "early", 23: "late"], "integer-hour JSON round trip")
    })

    record(await check("todo ordering and edits") {
        var todos = TodoState()
        try expect(todos.add(title: " \n ") == nil, "blank todo added")
        let a = try require(todos.add(title: " A "), "A not added")
        let b = try require(todos.add(title: "B"), "B not added")
        try expect(todos.items.map(\.title) == ["A", "B"], "title trim or initial order")
        todos.toggle(id: a.id)
        let c = try require(todos.add(title: "C"), "C not added")
        try expect(todos.items.map(\.id) == [b.id, c.id, a.id], "done item not below open items")
        todos.toggle(id: b.id)
        try expect(todos.items.map(\.id) == [c.id, b.id, a.id], "newly done item not first in done group")
        todos.toggle(id: a.id)
        try expect(todos.items.map(\.id) == [c.id, a.id, b.id], "reopened item not last in open group")
        todos.rename(id: c.id, title: "  ")
        try expect(todos.items[0].title == "C", "blank rename changed item")
        todos.rename(id: c.id, title: " C2 ")
        try expect(todos.items[0].title == "C2", "rename did not trim")
        todos.delete(id: a.id)
        try expect(todos.items.map(\.id) == [c.id, b.id], "delete failed")
        let unsorted = TodoState(items: [TodoItem(title: "done", isDone: true), TodoItem(title: "open")])
        try expect(unsorted.items.map(\.isDone) == [false, true], "initializer violated ordering")
        let decoded = try JSONDecoder().decode(TodoState.self, from: JSONEncoder().encode(unsorted))
        try expect(decoded == unsorted, "todo JSON round trip")
    })

    record(await check("PlanStore round trip and debounce") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = PlanStore(paths: paths, autosaveDelay: 0.15)
        let plannerFile = paths.root.appendingPathComponent("planner.json")
        store.updatePlanner { $0.setEntry(day: "2026-11-10", hour: 6, text: "first") }
        try await Task.sleep(for: .milliseconds(75))
        store.updatePlanner { $0.setEntry(day: "2026-11-10", hour: 6, text: "second") }
        try await Task.sleep(for: .milliseconds(90))
        try expect(!FileManager.default.fileExists(atPath: plannerFile.path), "planner saved before debounce ended")
        store.updateTodos { _ = $0.add(title: "task") }
        try await Task.sleep(for: .milliseconds(120))
        try expect(store.flush().isEmpty, "PlanStore flush failed")
        let restored = PlanStore(paths: paths)
        try expect(restored.planner.entry(day: "2026-11-10", hour: 6) == "second", "planner did not round trip")
        try expect(restored.todos.items.map(\.title) == ["task"], "todos did not round trip")
    })

    record(await check("PlanStore failures retry and report") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.root.path); try? FileManager.default.removeItem(at: paths.root) }
        let store = PlanStore(paths: paths, autosaveDelay: 0.05)
        store.updatePlanner { $0.setEntry(day: "2026-11-10", hour: 6, text: "old") }
        try expect(store.flush().isEmpty, "initial planner save failed")
        let oldBytes = try Data(contentsOf: paths.root.appendingPathComponent("planner.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: paths.root.path)
        store.updatePlanner { $0.setEntry(day: "2026-11-10", hour: 6, text: "retry") }
        store.updateTodos { _ = $0.add(title: "retry") }
        try await Task.sleep(for: .milliseconds(120))
        try expect(Set(store.flush()) == Set(["planner.json", "todos.json"]), "failed file names not reported")
        try expect(try Data(contentsOf: paths.root.appendingPathComponent("planner.json")) == oldBytes,
                   "failed planner save changed previous file")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.root.path)
        try await Task.sleep(for: .milliseconds(1200))
        try expect(store.flush().isEmpty, "retry remained pending")
        let restored = PlanStore(paths: paths)
        try expect(restored.planner.entry(day: "2026-11-10", hour: 6) == "retry", "planner retry failed")
        try expect(restored.todos.items.map(\.title) == ["retry"], "todo retry failed")
    })

    record(await check("PlanStore corrupt backup and blocked files") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.root.path); try? FileManager.default.removeItem(at: paths.root) }
        let plannerFile = paths.root.appendingPathComponent("planner.json")
        let todosFile = paths.root.appendingPathComponent("todos.json")
        try Data("{broken".utf8).write(to: plannerFile)
        let recovered = PlanStore(paths: paths)
        try expect(recovered.planner.days.isEmpty, "corrupt planner not reset")
        let backups = try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
        try expect(backups.contains(where: { $0.hasPrefix("planner.corrupt-") }), "corrupt planner not backed up")
        recovered.updatePlanner { $0.setEntry(day: "2026-11-10", hour: 6, text: "new") }
        try expect(recovered.flush().isEmpty, "backed-up planner stayed blocked")
        try FileManager.default.createDirectory(at: todosFile, withIntermediateDirectories: false)
        let unreadable = PlanStore(paths: paths)
        try expect(unreadable.flush() == ["todos.json"], "unreadable todos not reported")
        unreadable.updateTodos { _ = $0.add(title: "must not write") }
        try expect(unreadable.flush() == ["todos.json"], "unreadable todos update not blocked")
        try expect(FileManager.default.fileExists(atPath: todosFile.path), "unreadable todos moved")
        try FileManager.default.removeItem(at: todosFile)
        try Data("{broken".utf8).write(to: todosFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: paths.root.path)
        let unbacked = PlanStore(paths: paths)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.root.path)
        unbacked.updateTodos { _ = $0.add(title: "must not write") }
        try expect(unbacked.flush() == ["todos.json"], "unbacked todos not reported")
        try expect(try Data(contentsOf: todosFile) == Data("{broken".utf8), "unbacked todos overwritten")
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

    record(await check("timetable parses a normal response") {
        let day = try NEISTimetable.parse(Data(timetableJSON(total: 2, rows: [("1", "공통수학2"), ("2", "영어")]).utf8), ymd: "20261109")
        try expect(day.entries == [TimetableEntry(period: 1, subject: "공통수학2"), TimetableEntry(period: 2, subject: "영어")], "entries")
        try expect(!day.isPartial, "complete response marked partial")
        let otherDay = try NEISTimetable.parse(Data(timetableJSON(total: 1, rows: [("1", "국어")], ymd: "20261110").utf8), ymd: "20261109")
        try expect(otherDay.entries.isEmpty, "row from another date accepted")
    })

    record(await check("timetable sorts and removes duplicate periods") {
        let rows = [("3", "과학"), ("1", "국어"), ("3", "중복"), ("2", "영어"), ("1", "중복")]
        let day = try NEISTimetable.parse(Data(timetableJSON(total: 5, rows: rows).utf8))
        try expect(day.entries.map(\.period) == [1, 2, 3], "period order")
        try expect(day.entries.map(\.subject) == ["국어", "영어", "과학"], "first subject per period")
        try expect(!day.isPartial, "duplicates counted as partial")
    })

    record(await check("timetable marks partial responses") {
        let day = try NEISTimetable.parse(Data(timetableJSON(total: 7, rows: [("1", "국어"), ("2", "영어")]).utf8))
        try expect(day.isPartial && day.entries.count == 2, "partial flag")
    })

    record(await check("timetable INFO-200 means no classes") {
        let day = try NEISTimetable.parse(Data(#"{"RESULT":{"CODE":"INFO-200","MESSAGE":"none"}}"#.utf8))
        try expect(day == TimetableDay(), "not an empty day")
    })

    record(await check("timetable ERROR responses fail") {
        let top = Data(#"{"RESULT":{"CODE":"ERROR-300","MESSAGE":"bad"}}"#.utf8)
        try expect(parseError(top) == .api(code: "ERROR-300"), "top-level error")
        let badKey = Data(#"{"RESULT":{"CODE":"INFO-300","MESSAGE":"bad"}}"#.utf8)
        try expect(parseError(badKey) == .api(code: "INFO-300"), "non-200 INFO code")
        let head = Data(#"{"hisTimetable":[{"head":[{"list_total_count":1},{"RESULT":{"CODE":"ERROR-500"}}]}]}"#.utf8)
        try expect(parseError(head) == .api(code: "ERROR-500"), "head error")
    })

    record(await check("timetable rejects rows for another day or without a date") {
        let wrongDay = Data(#"{"hisTimetable":[{"head":[{"list_total_count":1},{"RESULT":{"CODE":"INFO-000"}}]},{"row":[{"ALL_TI_YMD":"20261111","PERIO":"1","ITRT_CNTNT":"수학"}]}]}"#.utf8)
        let noDate = Data(#"{"hisTimetable":[{"head":[{"list_total_count":1},{"RESULT":{"CODE":"INFO-000"}}]},{"row":[{"PERIO":"1","ITRT_CNTNT":"수학"}]}]}"#.utf8)
        for data in [wrongDay, noDate] {
            do {
                _ = try NEISTimetable.parse(data, ymd: "20261110")
                throw CheckFailure(description: "expected malformed response")
            } catch TimetableError.malformedResponse {}
        }
    })

    record(await check("timetable waits before retrying a failed day") {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = LockedCounter()
        let store = TimetableStore(paths: AppPaths(root: root), autosaveDelay: 0, failureCooldown: 60, apiKey: { nil }, transport: { _ in
            calls.increment()
            return (Data(), 500)
        })
        let monday = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 11, day: 9, hour: 12).date!
        store.request(date: monday)
        try await Task.sleep(for: .milliseconds(100))
        store.request(date: monday)
        try await Task.sleep(for: .milliseconds(100))
        if calls.value != 1 { throw CheckFailure(description: "expected one request, got \(calls.value)") }
    })

    record(await check("timetable broken JSON fails") {
        try expect(parseError(Data("{broken".utf8)) == .malformedResponse, "broken JSON")
        try expect(parseError(Data("[]".utf8)) == .malformedResponse, "wrong root")
        try expect(parseError(Data(#"{"hisTimetable":[{"head":[{"RESULT":{"CODE":"INFO-000"}}]}]}"#.utf8)) == .malformedResponse, "missing rows")
        let badPeriod = timetableJSON(total: 1, rows: [("첫째", "국어")])
        try expect(parseError(Data(badPeriod.utf8)) == .malformedResponse, "bad period")
    })

    record(await check("timetable request stays within the keyless limit") {
        let keyless = try require(NEISTimetable.requestURL(dayKey: "2026-11-09", apiKey: nil), "no URL")
        let query = queryItems(keyless)
        try expect(query["pSize"] == "5" && query["pIndex"] == "1" && query["KEY"] == nil, "keyless query")
        try expect(query["TI_FROM_YMD"] == "20261109" && query["TI_TO_YMD"] == "20261109", "single day")
        try expect(query["ATPT_OFCDC_SC_CODE"] == "G10" && query["SD_SCHUL_CODE"] == "7430310", "school")
        try expect(query["GRADE"] == "1" && query["CLASS_NM"] == "1", "class")
        let keyed = queryItems(try require(NEISTimetable.requestURL(dayKey: "2026-11-09", apiKey: "abc"), "no URL"))
        try expect(keyed["pSize"] == "30" && keyed["pIndex"] == "1" && keyed["KEY"] == "abc", "keyed query")
        try expect(queryItems(try require(NEISTimetable.requestURL(dayKey: "2026-11-09", apiKey: "  "), "no URL"))["KEY"] == nil, "blank key used")
    })

    record(await check("timetable failures never overwrite the cache") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let date = try gregorianDate(2026, 11, 9)
        let good = Data(timetableJSON(total: 1, rows: [("1", "국어")]).utf8)
        let first = TimetableStore(paths: paths, autosaveDelay: 0, failureCooldown: 0, apiKey: { nil }, transport: { _ in (good, 200) })
        first.request(date: date)
        try await waitUntilSettled(first, date)
        first.flush()
        let file = paths.root.appendingPathComponent("timetable.json")
        try await waitForFile(file)
        let saved = try Data(contentsOf: file)
        let expected = TimetableDay(entries: [TimetableEntry(period: 1, subject: "국어")])

        let failures: [TimetableTransport] = [
            { _ in (Data("{broken".utf8), 200) },
            { _ in (Data(#"{"RESULT":{"CODE":"ERROR-300"}}"#.utf8), 200) },
            { _ in (good, 500) },
            { _ in throw URLError(.notConnectedToInternet) },
        ]
        for transport in failures {
            let store = TimetableStore(paths: paths, autosaveDelay: 0, failureCooldown: 0, apiKey: { nil }, transport: transport)
            store.request(date: date)
            try await waitUntilSettled(store, date)
            let snapshot = store.snapshot(for: date)
            try expect(snapshot.status == .failed && snapshot.day == expected, "cache not shown after failure")
            store.flush()
            try await Task.sleep(for: .milliseconds(20))
            try expect(try Data(contentsOf: file) == saved, "failure rewrote the cache")
        }
    })

    record(await check("timetable fetches once per day and skips weekends") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let counter = RequestCounter()
        let body = Data(timetableJSON(total: 1, rows: [("1", "국어")]).utf8)
        let store = TimetableStore(paths: paths, autosaveDelay: 0, failureCooldown: 0, apiKey: { nil }, transport: { _ in
            counter.increment()
            return (body, 200)
        })
        let monday = try gregorianDate(2026, 11, 9)
        store.request(date: monday)
        store.request(date: monday)
        try await waitUntilSettled(store, monday)
        store.request(date: monday)
        try await Task.sleep(for: .milliseconds(20))
        try expect(counter.count == 1, "fetched \(counter.count) times")
        let saturday = try gregorianDate(2026, 11, 14)
        store.request(date: saturday)
        try await Task.sleep(for: .milliseconds(20))
        try expect(counter.count == 1, "weekend fetched")
        try expect(store.snapshot(for: saturday) == TimetableSnapshot(day: TimetableDay(), status: .loaded), "weekend snapshot")
        store.flush()
    })

    record(await check("timetable refetches partial days after a new key") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let counter = RequestCounter()
        let key = StringBox("")
        let store = TimetableStore(paths: paths, autosaveDelay: 0, failureCooldown: 0, apiKey: { key.text.isEmpty ? nil : key.text }, transport: { url in
            counter.increment()
            let keyed = url.query?.contains("KEY=") == true
            let rows = keyed ? [("1", "국어"), ("2", "영어")] : [("1", "국어")]
            return (Data(timetableJSON(total: 2, rows: rows).utf8), 200)
        })
        let date = try gregorianDate(2026, 11, 9)
        store.request(date: date)
        try await waitUntilSettled(store, date)
        try expect(store.snapshot(for: date).day?.isPartial == true, "keyless day not partial")
        key.text = "abc"
        store.apiKeyDidChange(refreshing: date)
        try await waitUntilSettled(store, date)
        try expect(counter.count == 2, "partial day not refetched")
        try expect(store.snapshot(for: date).day?.isPartial == false, "keyed result not applied")
        store.apiKeyDidChange(refreshing: date)
        try await Task.sleep(for: .milliseconds(20))
        try expect(counter.count == 2, "complete day refetched")
        store.flush()
    })

    record(await check("timetable late response stays on its own day") {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = TimetableStore(paths: paths, autosaveDelay: 0, failureCooldown: 0, apiKey: { nil }, transport: { url in
            let isMonday = url.query?.contains("TI_FROM_YMD=20261109") == true
            if isMonday { try await Task.sleep(for: .milliseconds(60)) }
            let rows = isMonday ? [("1", "월요일")] : [("1", "화요일")]
            return (Data(timetableJSON(total: 1, rows: rows, ymd: isMonday ? "20261109" : "20261110").utf8), 200)
        })
        let monday = try gregorianDate(2026, 11, 9)
        let tuesday = try gregorianDate(2026, 11, 10)
        store.request(date: monday)
        store.request(date: tuesday)
        try await waitUntilSettled(store, tuesday)
        try await waitUntilSettled(store, monday)
        try expect(store.snapshot(for: tuesday).day?.entries.first?.subject == "화요일", "Tuesday overwritten")
        try expect(store.snapshot(for: monday).day?.entries.first?.subject == "월요일", "Monday lost")
        store.flush()
    })

    print("\(failures == 0 ? "All checks passed" : "\(failures) check(s) failed")")
    return failures
}

private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw CheckFailure(description: message) }
    return value
}

private func timetableJSON(total: Int, rows: [(String, String)], ymd: String = "20261109") -> String {
    let body = rows.map { #"{"ALL_TI_YMD":"\#(ymd)","PERIO":"\#($0.0)","ITRT_CNTNT":"\#($0.1)"}"# }.joined(separator: ",")
    return #"{"hisTimetable":[{"head":[{"list_total_count":\#(total)},{"RESULT":{"CODE":"INFO-000","MESSAGE":"ok"}}]},{"row":[\#(body)]}]}"#
}

private func parseError(_ data: Data) -> TimetableError? {
    do {
        _ = try NEISTimetable.parse(data)
        return nil
    } catch {
        return error as? TimetableError
    }
}

private func queryItems(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

private func gregorianDate(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return try require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)), "invalid date")
}

@MainActor
private func waitUntilSettled(_ store: TimetableStore, _ date: Date) async throws {
    for _ in 0..<300 {
        try await Task.sleep(for: .milliseconds(10))
        if store.snapshot(for: date).status != .loading { return }
    }
    throw CheckFailure(description: "timetable request did not finish")
}

private func waitForFile(_ file: URL) async throws {
    for _ in 0..<300 {
        if FileManager.default.fileExists(atPath: file.path) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CheckFailure(description: "timetable cache was not written")
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private func memoDocumentIDs(_ state: WorkspaceState) -> Set<UUID> {
    Set(state.tabs.filter { $0.kind == .memo }.flatMap { $0.root.panes.map(\.documentID) })
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

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
