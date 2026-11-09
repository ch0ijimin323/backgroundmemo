import AppKit

/// What could not be written when saving everything.
struct SaveFailures {
    let documents: [UUID]
    /// File names from `PlanStore.flush`.
    let planFiles: [String]

    var isEmpty: Bool { documents.isEmpty && planFiles.isEmpty }

    var summary: String {
        let memos = documents.isEmpty ? [] : ["메모 \(documents.count)개"]
        let plans = planFiles.map { file in
            switch file {
            case "planner.json": "계획"
            case "todos.json": "할 일"
            default: file
            }
        }
        return (memos + plans).joined(separator: ", ")
    }
}

enum NEISKeyEntryResult {
    case save(String)
    case delete
    case cancel
}

/// Modal alerts for failures the user has to know about.
@MainActor
enum Alerts {
    static func showWorkspaceSaveFailed(_ error: Error) {
        show(
            message: "닫지 못했습니다",
            information: "작업 공간을 저장할 수 없어 칸이나 탭을 그대로 두었습니다.\n\(error.localizedDescription)"
        )
    }

    static func showTrashFailed(count: Int, error: Error) {
        show(
            message: "메모 \(count)개를 휴지통으로 옮기지 못했습니다",
            information: "파일은 Documents 폴더에 남아 있습니다.\n\(error.localizedDescription)"
        )
    }

    /// Returns true when the user chooses to quit despite unsaved changes.
    static func confirmQuitWithUnsavedChanges(_ failures: SaveFailures) -> Bool {
        let alert = makeAlert(
            message: "다음 항목을 저장하지 못했습니다: \(failures.summary)",
            information: "지금 종료하면 저장되지 않은 변경 내용이 사라집니다."
        )
        alert.addButton(withTitle: "취소")
        alert.addButton(withTitle: "그래도 종료")
        return alert.runModal() == .alertSecondButtonReturn
    }

    static func askForNEISKey(hasSavedKey: Bool) -> NEISKeyEntryResult {
        let alert = makeAlert(
            message: "NEIS 인증키",
            information: "인증키는 이 Mac의 키체인에만 저장됩니다. 인증키가 있으면 하루의 시간표를 모두 불러옵니다."
        )
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = hasSavedKey ? "저장된 인증키가 있습니다" : "인증키"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        if hasSavedKey { alert.addButton(withTitle: "삭제") }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? .cancel : .save(key)
        case .alertThirdButtonReturn:
            return .delete
        default:
            return .cancel
        }
    }

    static func showKeychainFailed(status: OSStatus) {
        show(message: "인증키를 변경하지 못했습니다", information: "키체인 오류 코드: \(status)")
    }

    private static func show(message: String, information: String) {
        let alert = makeAlert(message: message, information: information)
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    private static func makeAlert(message: String, information: String) -> NSAlert {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = information
        return alert
    }
}
