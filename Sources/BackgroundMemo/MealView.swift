import AppKit
import BackgroundMemoCore

/// One calendar day of school meals: a date header like the planner's above breakfast, lunch, and dinner.
/// Read-only. Unlike the planner, the day changes at midnight.
final class MealView: NSView {
    private static let headerHeight: CGFloat = 36
    private static let statusLineHeight: CGFloat = 18
    private static let sectionSpacing: CGFloat = 8
    private static let contentInset: CGFloat = 8

    private let mealStore: MealStore
    private let calendar = Calendar.current
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "M월 d일 (E)"
        return formatter
    }()

    private let previousButton = TabBarView.makeSymbolButton(symbol: "chevron.left", fallback: "‹", label: "이전 날")
    private let nextButton = TabBarView.makeSymbolButton(symbol: "chevron.right", fallback: "›", label: "다음 날")
    private let todayButton = NSButton(title: "", target: nil, action: nil)
    private let dateLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let document = FlippedView()
    private let scrollView: NSScrollView
    private let sections: [MealSectionView] = MealKind.allCases.map { MealSectionView(kind: $0) }

    private var displayedDate = Date()
    private var isShowingToday = true

    init(mealStore: MealStore) {
        self.mealStore = mealStore
        scrollView = .glassScrollView(document: document)
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        buildHeader()
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)
        addSubview(scrollView)
        sections.forEach(document.addSubview)
        // Always renders the page's own date, so a late response for another day cannot appear.
        mealStore.onUpdate = { [weak self] in self?.refreshMeals() }
        show(date: Date())

        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.calendarDayDidChange() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.calendarDayDidChange() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let buttonSize: CGFloat = 26
        let middle = (Self.headerHeight - buttonSize) / 2
        previousButton.frame = NSRect(x: 4, y: middle, width: buttonSize, height: buttonSize)
        let labelWidth = ceil(dateLabel.intrinsicContentSize.width)
        let labelHeight = ceil(dateLabel.intrinsicContentSize.height)
        dateLabel.frame = NSRect(
            x: previousButton.frame.maxX + 6,
            y: (Self.headerHeight - labelHeight) / 2,
            width: labelWidth,
            height: labelHeight
        )
        nextButton.frame = NSRect(x: dateLabel.frame.maxX + 6, y: middle, width: buttonSize, height: buttonSize)
        todayButton.frame = NSRect(x: bounds.width - 54, y: middle, width: 50, height: buttonSize)

        let statusHeight = statusLabel.isHidden ? 0 : Self.statusLineHeight
        statusLabel.frame = NSRect(x: 8, y: Self.headerHeight, width: max(0, bounds.width - 16), height: statusHeight)
        let top = Self.headerHeight + statusHeight
        scrollView.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))

        let width = scrollView.contentSize.width
        let sectionWidth = max(0, width - Self.contentInset * 2)
        var y = Self.contentInset
        for section in sections {
            let height = section.height(forWidth: sectionWidth)
            section.frame = NSRect(x: Self.contentInset, y: y, width: sectionWidth, height: height)
            y += height + Self.sectionSpacing
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: y - Self.sectionSpacing + Self.contentInset)
    }

    /// Switching back to this tab retries a day that has no result yet, once its cooldown is over.
    override func viewDidUnhide() {
        super.viewDidUnhide()
        mealStore.request(date: displayedDate)
        refreshMeals()
    }

    private func buildHeader() {
        previousButton.target = self
        previousButton.action = #selector(showPreviousDay)
        nextButton.target = self
        nextButton.action = #selector(showNextDay)
        todayButton.isBordered = false
        todayButton.attributedTitle = NSAttributedString(string: "오늘", attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        ])
        todayButton.target = self
        todayButton.action = #selector(showToday)
        dateLabel.textColor = .white
        dateLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        [previousButton, dateLabel, nextButton, todayButton].forEach(addSubview)
    }

    // MARK: Date navigation

    @objc private func showPreviousDay() { shiftDay(by: -1) }
    @objc private func showNextDay() { shiftDay(by: 1) }
    @objc private func showToday() { show(date: Date()) }

    private func shiftDay(by delta: Int) {
        if let date = calendar.date(byAdding: .day, value: delta, to: displayedDate) {
            show(date: date)
        }
    }

    private func show(date: Date) {
        displayedDate = calendar.startOfDay(for: date)
        isShowingToday = PlannerState.dayKey(for: displayedDate) == PlannerState.dayKey(for: Date())
        dateLabel.stringValue = dateFormatter.string(from: displayedDate)
        mealStore.request(date: displayedDate)
        refreshMeals()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Follows the calendar date, so the page turns at midnight while today is showing.
    private func calendarDayDidChange() {
        guard isShowingToday else {
            // The page being viewed may have just become today.
            isShowingToday = PlannerState.dayKey(for: displayedDate) == PlannerState.dayKey(for: Date())
            return
        }
        if PlannerState.dayKey(for: displayedDate) != PlannerState.dayKey(for: Date()) {
            show(date: Date())
        }
    }

    private func refreshMeals() {
        let snapshot = mealStore.snapshot(for: displayedDate)
        for section in sections {
            section.update(meal: snapshot.day?.meal(section.kind), hasResult: snapshot.day != nil)
        }
        let status = Self.statusText(for: snapshot)
        statusLabel.stringValue = status
        statusLabel.isHidden = status.isEmpty
        needsLayout = true
    }

    private static func statusText(for snapshot: MealSnapshot) -> String {
        switch (snapshot.status, snapshot.day) {
        case (.failed, nil): "급식을 불러오지 못했습니다"
        case (.failed, _): "급식을 불러오지 못했습니다 · 저장된 급식 표시 중"
        case (.loading, nil): "급식을 불러오는 중…"
        default: ""
        }
    }
}

/// One meal on a faint rounded band: its name and calories, then one dish per line.
private final class MealSectionView: NSView {
    private static let padding: CGFloat = 10
    private static let titleSpacing: CGFloat = 4

    let kind: MealKind
    private let titleLabel = NSTextField(labelWithString: "")
    private let caloriesLabel = NSTextField(labelWithString: "")
    private let dishesLabel = NSTextField(wrappingLabelWithString: "")

    init(kind: MealKind) {
        self.kind = kind
        super.init(frame: .zero)
        titleLabel.stringValue = kind.title
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        caloriesLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        caloriesLabel.font = .systemFont(ofSize: 11)
        caloriesLabel.lineBreakMode = .byTruncatingTail
        dishesLabel.font = .systemFont(ofSize: 13)
        dishesLabel.isSelectable = false
        [titleLabel, caloriesLabel, dishesLabel].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// `hasResult` is false while nothing is known about the day, so "급식 없음" is not claimed yet.
    func update(meal: Meal?, hasResult: Bool) {
        caloriesLabel.stringValue = meal?.calories ?? ""
        caloriesLabel.isHidden = caloriesLabel.stringValue.isEmpty
        if let meal, !meal.dishes.isEmpty {
            dishesLabel.stringValue = meal.dishes.joined(separator: "\n")
            dishesLabel.textColor = NSColor.white.withAlphaComponent(0.95)
        } else {
            dishesLabel.stringValue = hasResult ? "급식 없음" : "—"
            dishesLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        }
        needsLayout = true
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        Self.padding + titleHeight + Self.titleSpacing + dishesHeight(forWidth: width) + Self.padding
    }

    private var titleHeight: CGFloat { ceil(titleLabel.intrinsicContentSize.height) }

    private func dishesHeight(forWidth width: CGFloat) -> CGFloat {
        let textWidth = max(0, width - Self.padding * 2)
        dishesLabel.preferredMaxLayoutWidth = textWidth
        let size = dishesLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude))
        return ceil(size?.height ?? dishesLabel.intrinsicContentSize.height)
    }

    override func layout() {
        super.layout()
        let titleWidth = ceil(titleLabel.intrinsicContentSize.width)
        titleLabel.frame = NSRect(x: Self.padding, y: Self.padding, width: titleWidth, height: titleHeight)
        let caloriesHeight = ceil(caloriesLabel.intrinsicContentSize.height)
        let caloriesX = titleLabel.frame.maxX + 8
        // Bottom-aligned with the title so the smaller text sits on the same baseline area.
        caloriesLabel.frame = NSRect(
            x: caloriesX,
            y: titleLabel.frame.maxY - caloriesHeight - 1,
            width: max(0, bounds.width - caloriesX - Self.padding),
            height: caloriesHeight
        )
        let textWidth = max(0, bounds.width - Self.padding * 2)
        dishesLabel.frame = NSRect(
            x: Self.padding,
            y: titleLabel.frame.maxY + Self.titleSpacing,
            width: textWidth,
            height: dishesHeight(forWidth: bounds.width)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
}
