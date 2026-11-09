import AppKit
import BackgroundMemoCore

/// Decides where the window goes: restored bounds when usable, otherwise a visible spot.
@MainActor
enum WindowPlacement {
    static let defaultSize = NSSize(width: 720, height: 460)
    static let minimumSize = NSSize(width: 320, height: 200)

    /// How much of the top strip must be on a screen for the tab bar to stay draggable.
    private static let reachableStrip = NSSize(width: 100, height: 30)

    static func initialFrame(saved: WindowFrame?) -> NSRect {
        guard let saved, saved.width > 0, saved.height > 0 else { return centeredDefault() }
        let frame = NSRect(
            x: saved.x,
            y: saved.y,
            width: max(saved.width, minimumSize.width),
            height: max(saved.height, minimumSize.height)
        )
        return repaired(frame) ?? frame
    }

    /// A visible replacement for `frame`, or nil when it is already reachable or no screen exists.
    static func repaired(_ frame: NSRect) -> NSRect? {
        guard !isReachable(frame), let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let area = screen.visibleFrame
        let width = min(frame.width, area.width)
        let height = min(frame.height, area.height)
        return NSRect(
            x: min(max(frame.minX, area.minX), area.maxX - width),
            y: min(max(frame.minY, area.minY), area.maxY - height),
            width: width,
            height: height
        )
    }

    private static func isReachable(_ frame: NSRect) -> Bool {
        let strip = NSRect(
            x: frame.minX,
            y: frame.maxY - reachableStrip.height,
            width: frame.width,
            height: reachableStrip.height
        )
        return NSScreen.screens.contains { screen in
            let visible = strip.intersection(screen.visibleFrame)
            return visible.width >= reachableStrip.width && visible.height >= reachableStrip.height
        }
    }

    private static func centeredDefault() -> NSRect {
        guard let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            return NSRect(origin: NSPoint(x: 240, y: 240), size: defaultSize)
        }
        return NSRect(
            x: area.midX - defaultSize.width / 2,
            y: area.midY - defaultSize.height / 2,
            width: defaultSize.width,
            height: defaultSize.height
        )
    }
}
