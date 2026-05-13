import AVFoundation
import Foundation

/// macOS counterpart of `CameraSession+iOS.swift`. Intentionally a
/// no-op:
///
/// - `automaticallyConfiguresApplicationAudioSession` /
///   `usesApplicationAudioSession` are iOS-only properties on
///   `AVCaptureSession`. macOS doesn't have an app-wide
///   `AVAudioSession`, so there's nothing to "configure".
/// - `AVCaptureSessionWasInterrupted` and `InterruptionReason` are
///   iOS/tvOS/watchOS only — desktop AVCaptureSessions never get
///   "interrupted by a phone call" or "displaced by another app's
///   exclusive camera hold" in the way iOS does.
///
/// `onInterrupted` and `onResumed` on [CameraSession] are present
/// for surface parity but stay silent on macOS.
extension CameraSession {
    func setupPlatform() {
        // Intentionally empty.
    }
}
