import AppKit

func protoLog(_ message: String) {
    guard let path = ProcessInfo.processInfo.environment["BM_PROTO_LOG"] else { return }
    let line = "\(Date().timeIntervalSince1970) \(message)\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
}

final class ProbeTextView: NSTextView {
    override func mouseDown(with event: NSEvent) {
        protoLog("textview mouseDown isKey=\(window?.isKeyWindow ?? false)")
        super.mouseDown(with: event)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        protoLog("ime marked=\(string)")
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func didChangeText() {
        super.didChangeText()
        protoLog("text=\(string)")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: DesktopWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()

        let window = DesktopWindow(contentRect: NSRect(x: 240, y: 240, width: 720, height: 460))
        let size = window.contentRect(forFrameRect: window.frame).size

        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.cornerRadius = 22
        glass.style = .clear
        glass.autoresizingMask = [.width, .height]

        let content = NSView(frame: glass.bounds)
        content.autoresizingMask = [.width, .height]

        let stripHeight: CGFloat = 40
        let strip = WindowDragStrip(frame: NSRect(x: 0, y: size.height - stripHeight, width: size.width, height: stripHeight))
        strip.autoresizingMask = [.width, .minYMargin]

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 16, width: size.width - 32, height: size.height - stripHeight - 16))
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true

        let text = ProbeTextView(frame: scroll.bounds)
        text.autoresizingMask = [.width]
        text.drawsBackground = false
        text.isRichText = true
        text.importsGraphics = true
        text.usesFontPanel = true
        text.allowsUndo = true
        text.font = .systemFont(ofSize: 16)
        text.textColor = .white
        text.insertionPointColor = .white
        text.typingAttributes = [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.white]
        scroll.documentView = text

        content.addSubview(strip)
        content.addSubview(scroll)
        glass.contentView = content
        window.contentView = glass

        window.orderFront(nil)
        window.makeKey()
        window.makeFirstResponder(text)
        self.window = window
        protoLog("launched level=\(window.level.rawValue) glass=\(type(of: glass))")
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit BackgroundMemo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let formatItem = NSMenuItem()
        let formatMenu = NSMenu(title: "Format")
        let fontItem = NSMenuItem()
        fontItem.submenu = NSFontManager.shared.fontMenu(true)
        fontItem.title = "Font"
        formatMenu.addItem(fontItem)
        formatItem.submenu = formatMenu
        main.addItem(formatItem)

        return main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
