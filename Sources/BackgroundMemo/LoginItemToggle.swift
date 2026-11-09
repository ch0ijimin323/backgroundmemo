import AppKit
import ServiceManagement

/// Menu target for the opt-in "start at login" setting. macOS holds the state.
@MainActor
final class LoginItemToggle: NSObject, NSMenuItemValidation {
    static let shared = LoginItemToggle()

    @objc func toggle(_ sender: Any?) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            log.error("Login item change failed: \(String(describing: error), privacy: .public)")
            Alerts.showLoginItemFailed()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        return true
    }
}
