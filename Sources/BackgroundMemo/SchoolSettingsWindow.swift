import AppKit
import BackgroundMemoCore

/// A normal titled window, so it floats above the desktop-level memo window, for choosing the
/// school, grade, class, and bell times. Saving hands the settings back; closing discards them.
@MainActor
final class SchoolSettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate {
    var onSave: ((SchoolSettings) -> Void)?
    var onClose: (() -> Void)?

    private struct ChosenSchool {
        var name: String
        var kind: SchoolKind
        var officeCode: String
        var schoolCode: String
        var detail: String
    }

    private let apiKey: @MainActor () -> String?
    private let transport: TimetableTransport

    private let searchField = NSTextField()
    private let searchButton = NSButton(title: "검색", target: nil, action: nil)
    private let searchStatus = NSTextField(wrappingLabelWithString: "")
    private let resultsTable = NSTableView()
    private let resultsScroll = NSScrollView()
    private let chosenLabel = NSTextField(labelWithString: "")
    private let gradePopup = NSPopUpButton()
    private let classField = NSTextField()
    private let periodStack = NSStackView()
    private let periodScroll = NSScrollView()
    private let lengthField = NSTextField()
    private let validationLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "저장", target: nil, action: nil)

    private var results: [SchoolSearchResult] = []
    private var chosen: ChosenSchool?
    private var periodTexts: [String] = []
    private var periodFields: [NSTextField] = []
    private var searchTask: Task<Void, Never>?
    private var searchingQuery: String?
    private var isSearchScheduled = false
    /// Set while the table is reloaded, so clearing its selection does not count as a choice.
    private var isReloadingResults = false

    init(current: SchoolSettings?, apiKey: @escaping @MainActor () -> String?, transport: @escaping TimetableTransport = TimetableNetwork.live) {
        self.apiKey = apiKey
        self.transport = transport
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "학교 설정"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self
        buildContent()
        fill(from: current)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(searchField)
    }

    func windowWillClose(_ notification: Notification) {
        searchTask?.cancel()
        searchTask = nil
        searchingQuery = nil
        onClose?()
    }

    // MARK: Layout

    private func buildContent() {
        guard let window else { return }
        let contentWidth: CGFloat = 460

        searchField.placeholderString = "학교 이름"
        searchField.delegate = self
        searchField.lineBreakMode = .byTruncatingTail
        searchField.cell?.usesSingleLineMode = true
        searchButton.target = self
        searchButton.action = #selector(searchClicked)
        searchButton.bezelStyle = .rounded
        let searchRow = row([searchField, searchButton])

        searchStatus.font = .systemFont(ofSize: 11)
        searchStatus.textColor = .secondaryLabelColor
        searchStatus.preferredMaxLayoutWidth = contentWidth

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("school"))
        column.width = contentWidth - 4
        resultsTable.addTableColumn(column)
        resultsTable.headerView = nil
        resultsTable.rowHeight = 22
        resultsTable.usesAlternatingRowBackgroundColors = true
        resultsTable.allowsEmptySelection = true
        resultsTable.dataSource = self
        resultsTable.delegate = self
        resultsScroll.documentView = resultsTable
        resultsScroll.hasVerticalScroller = true
        resultsScroll.borderType = .bezelBorder
        resultsScroll.heightAnchor.constraint(equalToConstant: 118).isActive = true

        chosenLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        chosenLabel.lineBreakMode = .byTruncatingTail

        gradePopup.target = self
        gradePopup.action = #selector(fieldsDidChange)
        classField.placeholderString = "반 (예: 1)"
        classField.delegate = self
        classField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let classRow = row([label("학년"), gradePopup, label("반"), classField])

        periodStack.orientation = .vertical
        periodStack.alignment = .leading
        periodStack.spacing = 4
        periodStack.translatesAutoresizingMaskIntoConstraints = false
        let periodDocument = FlippedView()
        periodDocument.translatesAutoresizingMaskIntoConstraints = false
        periodDocument.addSubview(periodStack)
        periodScroll.documentView = periodDocument
        periodScroll.hasVerticalScroller = true
        periodScroll.borderType = .bezelBorder
        periodScroll.drawsBackground = false
        let clip = periodScroll.contentView
        NSLayoutConstraint.activate([
            periodScroll.heightAnchor.constraint(equalToConstant: 150),
            periodDocument.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            periodDocument.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            periodDocument.topAnchor.constraint(equalTo: clip.topAnchor),
            periodStack.leadingAnchor.constraint(equalTo: periodDocument.leadingAnchor, constant: 8),
            periodStack.trailingAnchor.constraint(lessThanOrEqualTo: periodDocument.trailingAnchor, constant: -8),
            periodStack.topAnchor.constraint(equalTo: periodDocument.topAnchor, constant: 6),
            periodStack.bottomAnchor.constraint(equalTo: periodDocument.bottomAnchor, constant: -6),
        ])

        let addButton = NSButton(title: "교시 추가", target: self, action: #selector(addPeriod))
        addButton.bezelStyle = .rounded
        lengthField.delegate = self
        lengthField.alignment = .right
        lengthField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        let bellRow = row([addButton, NSView(), label("수업 길이"), lengthField, label("분")])

        let keyInfo = NSTextField(wrappingLabelWithString:
            "시간표와 급식은 나이스 교육정보 개방 포털(open.neis.go.kr)에서 불러옵니다. 인증키가 없으면 학교 검색은 5개까지, " +
            "하루 시간표는 5교시까지만 받습니다. 인증키는 포털에서 무료로 발급받아 파일 메뉴의 ‘NEIS 인증키 입력…’에 넣으세요.")
        keyInfo.font = .systemFont(ofSize: 11)
        keyInfo.textColor = .secondaryLabelColor
        keyInfo.preferredMaxLayoutWidth = contentWidth

        validationLabel.font = .systemFont(ofSize: 11)
        validationLabel.textColor = .secondaryLabelColor
        validationLabel.lineBreakMode = .byTruncatingTail
        let cancelButton = NSButton(title: "취소", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded
        // No Return equivalent: Return in the search field searches.
        let buttonRow = row([validationLabel, NSView(), cancelButton, saveButton])

        let stack = NSStackView(views: [
            heading("학교"), searchRow, searchStatus, resultsScroll, chosenLabel,
            heading("학년·반"), classRow,
            heading("교시 시작 시각"), periodScroll, bellRow,
            keyInfo, buttonRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.setCustomSpacing(16, after: chosenLabel)
        stack.setCustomSpacing(16, after: classRow)
        stack.setCustomSpacing(14, after: bellRow)
        stack.setCustomSpacing(14, after: keyInfo)
        for view in [searchRow, searchStatus, resultsScroll, chosenLabel, periodScroll, bellRow, keyInfo, buttonRow] {
            view.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        }
        window.contentView = stack
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: .semibold)
        field.textColor = .secondaryLabelColor
        return field
    }

    // MARK: Values

    private func fill(from settings: SchoolSettings?) {
        if let settings {
            chosen = ChosenSchool(name: settings.schoolName, kind: settings.kind, officeCode: settings.officeCode,
                                  schoolCode: settings.schoolCode, detail: settings.kind.title)
            classField.stringValue = settings.className
            setBell(settings.periodStartMinutes, length: settings.classLength)
        } else {
            let bell = SchoolSettings.defaultBell(officeCode: "", schoolCode: "")
            setBell(bell.periodStartMinutes, length: bell.classLength)
        }
        reloadGrades(selecting: settings?.grade ?? 1)
        searchStatus.stringValue = "학교 이름을 입력하고 검색하세요."
        updateChosenLabel()
        validate()
    }

    private func reloadGrades(selecting grade: Int) {
        let grades = (chosen?.kind ?? .high).grades
        gradePopup.removeAllItems()
        for value in grades {
            gradePopup.addItem(withTitle: "\(value)학년")
            gradePopup.lastItem?.tag = value
        }
        gradePopup.selectItem(withTag: grades.contains(grade) ? grade : grades.lowerBound)
    }

    private func setBell(_ starts: [Int], length: Int) {
        periodTexts = starts.map(SchoolSettings.clockText)
        lengthField.stringValue = String(length)
        rebuildPeriodRows()
    }

    private func rebuildPeriodRows() {
        periodStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        periodFields = []
        for (index, text) in periodTexts.enumerated() {
            let title = label("\(index + 1)교시")
            title.alignment = .right
            title.widthAnchor.constraint(equalToConstant: 44).isActive = true
            let field = NSTextField(string: text)
            field.placeholderString = "HH:mm"
            field.delegate = self
            field.tag = index
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true
            let remove = NSButton(title: "삭제", target: self, action: #selector(removePeriod(_:)))
            remove.bezelStyle = .rounded
            remove.controlSize = .small
            remove.tag = index
            remove.isEnabled = periodTexts.count > 1
            periodStack.addArrangedSubview(row([title, field, remove]))
            periodFields.append(field)
        }
        validate()
    }

    @objc private func addPeriod() {
        guard periodTexts.count < SchoolSettings.maximumPeriods else { return }
        let length = Int(lengthField.stringValue.trimmingCharacters(in: .whitespaces)) ?? SchoolSettings.defaultClassLength
        let last = periodTexts.last.flatMap(SchoolSettings.minutes(fromClock:)) ?? 9 * 60 - length - 10
        periodTexts.append(SchoolSettings.clockText(min(23 * 60 + 50, last + length + 10)))
        rebuildPeriodRows()
        periodFields.last?.window?.makeFirstResponder(periodFields.last)
    }

    @objc private func removePeriod(_ sender: NSButton) {
        guard periodTexts.indices.contains(sender.tag), periodTexts.count > 1 else { return }
        periodTexts.remove(at: sender.tag)
        rebuildPeriodRows()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if let index = periodFields.firstIndex(where: { $0 === field }) {
            periodTexts[index] = field.stringValue
        }
        validate()
    }

    @objc private func fieldsDidChange() { validate() }

    /// The settings the window describes, or the reason they cannot be saved yet.
    private func currentSettings() -> Result<SchoolSettings, ValidationMessage> {
        guard let chosen else { return .failure("학교를 검색해 목록에서 고르세요") }
        let className = classField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !className.isEmpty else { return .failure("반을 입력하세요") }
        var starts: [Int] = []
        for (index, text) in periodTexts.enumerated() {
            guard let minute = SchoolSettings.minutes(fromClock: text) else {
                return .failure("\(index + 1)교시 시각을 HH:mm 형식으로 입력하세요")
            }
            starts.append(minute)
        }
        let range = SchoolSettings.classLengthRange
        guard let length = Int(lengthField.stringValue.trimmingCharacters(in: .whitespaces)), range.contains(length) else {
            return .failure("수업 길이는 \(range.lowerBound)~\(range.upperBound)분입니다")
        }
        let settings = SchoolSettings(
            officeCode: chosen.officeCode, schoolCode: chosen.schoolCode, schoolName: chosen.name, kind: chosen.kind,
            grade: gradePopup.selectedTag(), className: className, periodStartMinutes: starts, classLength: length
        )
        return settings.isValid ? .success(settings) : .failure("설정을 확인하세요")
    }

    private struct ValidationMessage: Error, ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
        let text: String
        init(stringLiteral value: String) { text = value }
    }

    private func validate() {
        switch currentSettings() {
        case .success:
            saveButton.isEnabled = true
            validationLabel.stringValue = ""
        case .failure(let message):
            saveButton.isEnabled = false
            validationLabel.stringValue = message.text
        }
    }

    private func updateChosenLabel() {
        if let chosen {
            chosenLabel.stringValue = "\(chosen.name) · \(chosen.detail)"
            chosenLabel.textColor = .labelColor
        } else {
            chosenLabel.stringValue = "선택한 학교 없음"
            chosenLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func save() {
        guard case .success(let settings) = currentSettings() else { return }
        onSave?(settings)
        close()
    }

    @objc private func cancel() { close() }

    // MARK: Search

    /// Return goes through here. The Korean IME can commit its last syllable around this command,
    /// so the search reads the field after the key event has finished, once, in either order.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchField, selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if !isSearchScheduled {
            isSearchScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSearchScheduled = false
                // Still composing: this Return only committed the syllable.
                if (self.searchField.currentEditor() as? NSTextView)?.hasMarkedText() == true { return }
                self.startSearch()
            }
        }
        return true
    }

    @objc private func searchClicked() {
        if let editor = searchField.currentEditor() as? NSTextView, editor.hasMarkedText() {
            editor.unmarkText()
        }
        startSearch()
    }

    private func startSearch() {
        let query = ((searchField.currentEditor() as? NSTextView)?.string ?? searchField.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchStatus.stringValue = "학교 이름을 입력하세요."
            return
        }
        // The same name is already being searched.
        guard query != searchingQuery else { return }
        searchTask?.cancel()
        searchingQuery = query
        searchStatus.stringValue = "검색 중…"
        let key = apiKey()
        let transport = transport
        searchTask = Task { @MainActor [weak self] in
            let result = await NEISSchoolSearch.search(query: query, apiKey: key, transport: transport)
            guard let self, !Task.isCancelled, self.searchingQuery == query else { return }
            self.searchingQuery = nil
            self.show(result)
        }
    }

    private func show(_ result: Result<SchoolSearchPage, TimetableError>) {
        switch result {
        case .success(let page):
            setResults(page.results)
            if page.results.isEmpty {
                searchStatus.stringValue = "검색 결과가 없습니다. 학교 이름을 확인하세요."
            } else if page.hasMore {
                searchStatus.stringValue = "결과가 더 있습니다. 학교 이름을 더 정확히 입력하세요."
            } else {
                searchStatus.stringValue = "\(page.results.count)개 학교를 찾았습니다. 목록에서 고르세요."
            }
        case .failure(let error):
            setResults([])
            searchStatus.stringValue = Self.message(for: error)
        }
    }

    private static func message(for error: TimetableError) -> String {
        switch error {
        case .network: "학교를 검색하지 못했습니다. 인터넷 연결을 확인하세요."
        case .http(let code): "학교를 검색하지 못했습니다. (HTTP \(code))"
        case .malformedResponse: "학교를 검색하지 못했습니다. 응답을 읽을 수 없습니다."
        case .api(let code): "학교를 검색하지 못했습니다. (\(code))"
        }
    }

    private func setResults(_ newResults: [SchoolSearchResult]) {
        isReloadingResults = true
        results = newResults
        resultsTable.reloadData()
        resultsTable.deselectAll(nil)
        isReloadingResults = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("schoolCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        let result = results[row]
        cell.textField?.stringValue = Self.description(of: result)
        return cell
    }

    private static func description(of result: SchoolSearchResult) -> String {
        [result.name, result.kindName, result.region].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Choosing a school fills in its default bell times.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloadingResults, results.indices.contains(resultsTable.selectedRow) else { return }
        let result = results[resultsTable.selectedRow]
        let previousGrade = gradePopup.selectedTag()
        chosen = ChosenSchool(
            name: result.name, kind: result.kind, officeCode: result.officeCode, schoolCode: result.schoolCode,
            detail: [result.kindName, result.region].filter { !$0.isEmpty }.joined(separator: " · ")
        )
        let bell = SchoolSettings.defaultBell(officeCode: result.officeCode, schoolCode: result.schoolCode)
        setBell(bell.periodStartMinutes, length: bell.classLength)
        reloadGrades(selecting: previousGrade)
        updateChosenLabel()
        validate()
    }
}
