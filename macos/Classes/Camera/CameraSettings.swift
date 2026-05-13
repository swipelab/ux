import AppKit

/// macOS counterpart of the iOS `CameraSettings.openAppSettings`.
/// There's no per-app deep link on macOS; we go straight to the
/// Camera privacy pane in System Settings. The URL scheme has been
/// stable since macOS 10.14.
enum CameraSettings {
    @MainActor
    static func openAppSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        ) {
            NSWorkspace.shared.open(url)
        }
    }
}
