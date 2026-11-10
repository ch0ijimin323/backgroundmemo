import AppKit
import BackgroundMemoCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: WorkspaceController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let paths = AppPaths.standard()
        let neisKeyStore = NEISKeyStore(paths: paths)
        // Before the workspace loads: a missing workspace.json is how a new install is recognized,
        // and loading the workspace creates it.
        let schoolSettingsStore = SchoolSettingsStore(paths: paths)
        let school = schoolSettingsStore.load()
        let controller = WorkspaceController(
            workspaceStore: WorkspaceStore(paths: paths),
            documentStore: DocumentStore(paths: paths),
            planStore: PlanStore(paths: paths),
            timetableStore: TimetableStore(paths: paths, settings: school.settings, apiKey: { neisKeyStore.key }),
            mealStore: MealStore(paths: paths, settings: school.settings, apiKey: { neisKeyStore.key }),
            neisKeyStore: neisKeyStore,
            schoolSettingsStore: schoolSettingsStore
        )
        self.controller = controller
        NSApp.mainMenu = MainMenu.make(controller: controller)
        controller.showWindow()
        if school.needsSetup {
            // After launch finishes, so the window comes up in front of the desktop-level memo window.
            Task { @MainActor in controller.showSchoolSettings(nil) }
        }
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
