import AppKit

/// Borderless window that lives just above the desktop icons and below normal app windows.
/// With "bring to front" on, it rises to the normal window level while the app is active
/// and sinks back to the desktop when another app takes over.
final class DesktopWindow: NSWindow {
    static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        level = Self.desktopLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        minSize = WindowPlacement.minimumSize

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(updateLevel), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(updateLevel), name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(updateLevel), name: BringToFrontToggle.didChange, object: nil)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    @objc private func updateLevel() {
        let raised = BringToFrontToggle.isOn && NSApp.isActive
        let target: NSWindow.Level = raised ? .normal : Self.desktopLevel
        guard level != target else { return }
        level = target
        guard raised else { return }
        // Keep another of our windows (such as school settings) above the memo if it has focus.
        if let key = NSApp.keyWindow, key !== self, key.isVisible {
            order(.below, relativeTo: key.windowNumber)
        } else {
            orderFront(nil)
        }
    }
}

/// Menu target for "bring the memo to the front when the app is clicked". On by default.
@MainActor
final class BringToFrontToggle: NSObject, NSMenuItemValidation {
    static let shared = BringToFrontToggle()
    static let didChange = Notification.Name("BringToFrontToggle.didChange")
    private static let defaultsKey = "bringToFrontWhenActive"

    static var isOn: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    @objc func toggle(_ sender: Any?) {
        UserDefaults.standard.set(!Self.isOn, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.state = Self.isOn ? .on : .off
        return true
    }
}
