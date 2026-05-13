import Foundation

/// macOS counterpart of `ios/Classes/Camera/DeviceOrientationBridge.swift`.
/// Desktops don't rotate; the bridge is shaped identically to the iOS
/// one so [CameraInstance] can call it without `#if` blocks, but
/// `current` stays at `.portraitUp` and the listener never fires.
final class DeviceOrientationBridge {
    typealias Listener = (DeviceOrientationFlutter) -> Void

    private(set) var current: DeviceOrientationFlutter = .portraitUp

    func start(listener: @escaping Listener) {
        // Intentionally empty — no rotation events on macOS.
    }

    func stop() {
        // Intentionally empty — nothing to unwind.
    }
}
