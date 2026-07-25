#if os(macOS)

import Foundation

/// macOS counterpart of `CameraInstance+iOS.swift`.
///
/// macOS doesn't have iOS's hard "the app is backgrounded, you must
/// release the camera" lifecycle. A backgrounded Mac app keeps
/// running, and there's no equivalent UIApplication notification —
/// the closest analogues are `NSApplication.didResignActive` /
/// `…didBecomeActive`, but the chat composer's macOS surface (a
/// Card dialog) typically stays in the foreground long enough that
/// teardown on resign-active would cost more than it saves.
///
/// Left as a no-op so the shared `CameraInstance.observeLifecycle()`
/// call compiles. If a need surfaces later, wire NSApplication
/// observers here calling `pauseForBackground` / `resumeForForeground`.
extension CameraInstance {
    func observeLifecycle() {
        // Intentionally empty.
    }
}

#endif
