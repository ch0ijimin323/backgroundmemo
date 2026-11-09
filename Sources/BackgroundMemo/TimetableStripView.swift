import AppKit
import BackgroundMemoCore

/// Read-only summary of the day's classes, shown between the date header and the hour rows.
final class TimetableStripView: NSView {
    private static let horizontalInset: CGFloat = 8
    private static let verticalInset: CGFloat = 4
    private static let spacing: CGFloat = 2

    private let summaryLabel = TimetableStripView.makeLabel(size: 13, alpha: 0.95)
    private let noteLabel = TimetableStripView.makeLabel(size: 11, alpha: 0.65)

    init() {
        super.init(frame: .zero)
        addSubview(summaryLabel)
        addSubview(noteLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func render(_ snapshot: TimetableSnapshot) {
        summaryLabel.stringValue = Self.summary(for: snapshot)
        noteLabel.stringValue = Self.note(for: snapshot)
        noteLabel.isHidden = noteLabel.stringValue.isEmpty
    }

    private static func summary(for snapshot: TimetableSnapshot) -> String {
        guard let day = snapshot.day else {
            return snapshot.status == .failed ? "시간표를 불러오지 못했습니다" : "시간표를 불러오는 중…"
        }
        if day.entries.isEmpty { return "수업 없음" }
        return day.entries.map { "\($0.period)교시 \($0.subject)" }.joined(separator: "   ")
    }

    private static func note(for snapshot: TimetableSnapshot) -> String {
        var notes: [String] = []
        if snapshot.status == .failed, snapshot.day != nil {
            notes.append("시간표를 불러오지 못했습니다 · 저장된 시간표 표시 중")
        }
        if snapshot.day?.isPartial == true {
            notes.append("일부 교시만 표시 중 · 인증키를 입력하면 전체 표시")
        }
        return notes.joined(separator: "\n")
    }

    /// The height needed to show everything at `width`.
    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        var height = Self.verticalInset * 2 + textHeight(summaryLabel, width: width)
        if !noteLabel.isHidden { height += Self.spacing + textHeight(noteLabel, width: width) }
        return height
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let textWidth = max(0, width - Self.horizontalInset * 2)
        let summaryHeight = textHeight(summaryLabel, width: width)
        summaryLabel.frame = NSRect(x: Self.horizontalInset, y: Self.verticalInset, width: textWidth, height: summaryHeight)
        noteLabel.frame = NSRect(
            x: Self.horizontalInset,
            y: summaryLabel.frame.maxY + Self.spacing,
            width: textWidth,
            height: textHeight(noteLabel, width: width)
        )
    }

    private func textHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        let bounds = NSRect(x: 0, y: 0, width: max(0, width - Self.horizontalInset * 2), height: .greatestFiniteMagnitude)
        return ceil(label.cell?.cellSize(forBounds: bounds).height ?? 0)
    }

    private static func makeLabel(size: CGFloat, alpha: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.isSelectable = false
        label.textColor = NSColor.white.withAlphaComponent(alpha)
        label.font = .systemFont(ofSize: size)
        return label
    }
}
