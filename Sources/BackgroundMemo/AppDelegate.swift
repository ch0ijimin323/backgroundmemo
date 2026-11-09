import AppKit
import BackgroundMemoCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let loginItemKey = "didRegisterLoginItem"
    private var controller: WorkspaceController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let paths = AppPaths.standard()
        let controller = WorkspaceController(
            workspaceStore: WorkspaceStore(paths: paths),
            documentStore: DocumentStore(paths: paths)
        )
        self.controller = controller
        NSApp.mainMenu = MainMenu.make(controller: controller)
        controller.showWindow()
        registerLoginItemOnFirstLaunch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller, !controller.confirmTermination() else { return .terminateNow }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.saveEverything()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func registerLoginItemOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.loginItemKey) else { return }
        do {
            try SMAppService.mainApp.register()
            defaults.set(true, forKey: Self.loginItemKey)
        } catch {
            log.error("Login item registration failed: \(String(describing: error), privacy: .public)")
        }
    }
}
