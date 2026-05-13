import UIKit

/// Deep-link the user into this app's Settings entry. iOS exposes a
/// dedicated `openSettingsURLString` that lands directly on the
/// per-app permission pane. Called from the shared
/// `CameraPlugin.handle("openSettings")`.
enum CameraSettings {
    @MainActor
    static func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
