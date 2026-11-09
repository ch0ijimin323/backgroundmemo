import AppKit

/// Borderless window that lives just above the desktop icons and below normal app windows.
final class DesktopWindow: NSWindow {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        minSize = WindowPlacement.minimumSize
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
