import AppKit

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

    /// Returns true when the user chooses to quit despite unsaved memos.
    static func confirmQuitWithUnsavedDocuments(count: Int) -> Bool {
        let alert = makeAlert(
            message: "메모 \(count)개를 저장하지 못했습니다",
            information: "지금 종료하면 저장되지 않은 변경 내용이 사라집니다."
        )
        alert.addButton(withTitle: "취소")
        alert.addButton(withTitle: "그래도 종료")
        return alert.runModal() == .alertSecondButtonReturn
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
