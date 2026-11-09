import AppKit

/// Builds the Korean menu bar. Text actions go through the responder chain to the focused memo.
@MainActor
enum MainMenu {
    private static let fontMenuTitle = "서체"

    /// Font actions are switched off as a whole on fixed tabs, including their key equivalents.
    static func setFontMenuEnabled(_ enabled: Bool) {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == fontMenuTitle })?.submenu else { return }
        setEnabled(enabled, in: menu)
    }

    private static func setEnabled(_ enabled: Bool, in menu: NSMenu) {
        menu.autoenablesItems = enabled
        for item in menu.items {
            item.isEnabled = enabled
            if let submenu = item.submenu { setEnabled(enabled, in: submenu) }
        }
    }

    static func make(controller: WorkspaceController) -> NSMenu {
        let main = NSMenu()
        main.addSubmenu(makeAppMenu())
        main.addSubmenu(makeFileMenu(controller))
        main.addSubmenu(makeEditMenu())
        main.addSubmenu(makeFontMenu())
        main.addSubmenu(makeViewMenu(controller))
        return main
    }

    private static func makeAppMenu() -> NSMenu {
        let menu = NSMenu(title: "BackgroundMemo")
        menu.add("BackgroundMemo 종료", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)
        return menu
    }

    private static func makeFileMenu(_ controller: WorkspaceController) -> NSMenu {
        let menu = NSMenu(title: "파일")
        menu.add("새 탭", #selector(WorkspaceController.newTab(_:)), key: "t", target: controller)
        menu.add("칸 닫기", #selector(WorkspaceController.closeFocusedPane(_:)), key: "w", target: controller)
        menu.addItem(.separator())
        menu.add("NEIS 인증키 입력…", #selector(WorkspaceController.showNEISKeyEntry(_:)), target: controller)
        return menu
    }

    private static func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: "편집")
        menu.add("실행 취소", #selector(MemoTextView.undo(_:)), key: "z")
        menu.add("실행 복귀", #selector(MemoTextView.redo(_:)), key: "z", modifiers: [.command, .shift])
        menu.addItem(.separator())
        menu.add("오려두기", #selector(NSText.cut(_:)), key: "x")
        menu.add("복사하기", #selector(NSText.copy(_:)), key: "c")
        menu.add("붙여넣기", #selector(NSText.paste(_:)), key: "v")
        menu.add("전체 선택", #selector(NSText.selectAll(_:)), key: "a")
        return menu
    }

    private static func makeFontMenu() -> NSMenu {
        let fonts = NSFontManager.shared
        let menu = NSMenu(title: fontMenuTitle)
        menu.add(
            "서체 보기", #selector(NSFontManager.orderFrontFontPanel(_:)),
            key: "t", modifiers: [.command, .option], target: fonts
        )
        menu.addItem(.separator())
        menu.add("볼드체", #selector(MemoTextView.toggleBoldface(_:)), key: "b")
        menu.add("이탤릭체", #selector(MemoTextView.toggleItalics(_:)), key: "i")
        menu.add("밑줄체", #selector(NSText.underline(_:)), key: "u")
        menu.add("취소선", #selector(MemoTextView.toggleStrikethrough(_:)))
        menu.add("윤곽체", #selector(MemoTextView.toggleOutline(_:)))
        menu.addItem(.separator())

        let sizeUp = Int(NSFontAction.sizeUpFontAction.rawValue)
        let sizeDown = Int(NSFontAction.sizeDownFontAction.rawValue)
        let modify = #selector(NSFontManager.modifyFont(_:))
        menu.add("크게", modify, key: "+", target: fonts, tag: sizeUp)
        // ⌘= is the unshifted ⌘+ on most keyboards.
        let unshifted = menu.add("크게", modify, key: "=", target: fonts, tag: sizeUp)
        unshifted.isHidden = true
        unshifted.allowsKeyEquivalentWhenHidden = true
        menu.add("작게", modify, key: "-", target: fonts, tag: sizeDown)
        menu.addItem(.separator())

        menu.addSubmenu(submenu("자간", [
            ("기본값 사용", #selector(NSTextView.useStandardKerning(_:))),
            ("사용 안 함", #selector(NSTextView.turnOffKerning(_:))),
            ("좁게", #selector(NSTextView.tightenKerning(_:))),
            ("넓게", #selector(NSTextView.loosenKerning(_:))),
        ]))
        menu.addSubmenu(submenu("합자", [
            ("기본값 사용", #selector(NSTextView.useStandardLigatures(_:))),
            ("사용 안 함", #selector(NSTextView.turnOffLigatures(_:))),
            ("모두 사용", #selector(NSTextView.useAllLigatures(_:))),
        ]))
        menu.addSubmenu(submenu("기준선", [
            ("기본값 사용", #selector(NSTextView.unscript(_:))),
            ("위 첨자", #selector(NSTextView.superscript(_:))),
            ("아래 첨자", #selector(NSTextView.subscript(_:))),
            ("올리기", #selector(NSTextView.raiseBaseline(_:))),
            ("내리기", #selector(NSTextView.lowerBaseline(_:))),
        ]))
        menu.addItem(.separator())

        menu.add(
            "색상 보기", #selector(NSApplication.orderFrontColorPanel(_:)),
            key: "c", modifiers: [.command, .shift], target: NSApp
        )
        menu.addItem(.separator())
        menu.add("스타일 복사하기", #selector(NSText.copyFont(_:)), key: "c", modifiers: [.command, .option])
        menu.add("스타일 붙여넣기", #selector(NSText.pasteFont(_:)), key: "v", modifiers: [.command, .option])
        return menu
    }

    private static func makeViewMenu(_ controller: WorkspaceController) -> NSMenu {
        let menu = NSMenu(title: "보기")
        menu.add("좌우 분할", #selector(WorkspaceController.splitLeftRight(_:)), key: "d", target: controller)
        menu.add(
            "상하 분할", #selector(WorkspaceController.splitTopBottom(_:)),
            key: "d", modifiers: [.command, .shift], target: controller
        )
        menu.addItem(.separator())
        menu.add("이전 칸", #selector(WorkspaceController.focusPreviousPane(_:)), key: "[", target: controller)
        menu.add("다음 칸", #selector(WorkspaceController.focusNextPane(_:)), key: "]", target: controller)
        return menu
    }

    private static func submenu(_ title: String, _ items: [(String, Selector)]) -> NSMenu {
        let menu = NSMenu(title: title)
        for (itemTitle, action) in items {
            menu.add(itemTitle, action)
        }
        return menu
    }
}

private extension NSMenu {
    @discardableResult
    func add(
        _ title: String,
        _ action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = .command,
        target: AnyObject? = nil,
        tag: Int = 0
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        item.tag = tag
        addItem(item)
        return item
    }

    func addSubmenu(_ submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
