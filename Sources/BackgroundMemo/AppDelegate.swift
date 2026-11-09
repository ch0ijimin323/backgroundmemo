import AppKit
import BackgroundMemoCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: WorkspaceController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let paths = AppPaths.standard()
        let neisKeyStore = NEISKeyStore(paths: paths)
        let controller = WorkspaceController(
            workspaceStore: WorkspaceStore(paths: paths),
            documentStore: DocumentStore(paths: paths),
            planStore: PlanStore(paths: paths),
            timetableStore: TimetableStore(paths: paths, apiKey: { neisKeyStore.key }),
            neisKeyStore: neisKeyStore
        )
        self.controller = controller
        NSApp.mainMenu = MainMenu.make(controller: controller)
        controller.showWindow()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller, !controller.confirmTermination() else { return .terminateNow }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.saveEverything()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
