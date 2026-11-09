import AppKit

/// Frosted backdrop that looks the same whether or not the window is focused.
/// NSGlassEffectView restyles itself on focus changes, and offers no way to pin one state.
final class GlassBackdrop: NSView {
    static let cornerRadius: CGFloat = 22
    /// Share of frost over the sharp wallpaper: the midpoint between clear and fully frosted.
    private static let frostAmount: CGFloat = 0.55

    override init(frame: NSRect) {
        super.init(frame: frame)

        let frost = NSVisualEffectView(frame: bounds)
        frost.autoresizingMask = [.width, .height]
        frost.blendingMode = .behindWindow
        frost.material = .hudWindow
        frost.state = .active
        frost.appearance = NSAppearance(named: .darkAqua)
        frost.alphaValue = Self.frostAmount
        frost.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        addSubview(frost)

        let rim = PassthroughView(frame: bounds)
        rim.autoresizingMask = [.width, .height]
        rim.wantsLayer = true
        rim.layer?.cornerRadius = Self.cornerRadius
        rim.layer?.borderWidth = 1
        rim.layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        addSubview(rim)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
