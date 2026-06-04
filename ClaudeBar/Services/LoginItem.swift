import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` so the app can register/unregister itself as a
/// login item (macOS 13+). Mirrors the `StatuslineInstaller` shape: an
/// observable singleton the UI binds to directly.
@MainActor
@Observable
final class LoginItem {
    static let shared = LoginItem()

    /// True when the app is registered to launch at login.
    private(set) var isEnabled: Bool = false
    /// True when macOS needs the user to approve the item in
    /// System Settings › General › Login Items before it will run.
    private(set) var requiresApproval: Bool = false

    private init() { refresh() }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            requiresApproval = false
        case .requiresApproval:
            isEnabled = true
            requiresApproval = true
        default:
            isEnabled = false
            requiresApproval = false
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            // Registration can fail when the app isn't in a stable location
            // (e.g. launched from a quarantined or translocated copy). Fall
            // through to refresh() so the toggle reflects the real OS state
            // rather than the attempted change.
        }
        refresh()
    }

    /// Opens System Settings › General › Login Items so the user can approve
    /// or remove the item manually.
    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
