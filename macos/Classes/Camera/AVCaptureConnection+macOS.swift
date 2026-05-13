import AVFoundation

/// macOS counterpart of `AVCaptureConnection+iOS.swift`.
///
/// macOS desktop cameras are physically fixed landscape — applying any
/// `AVCaptureVideoOrientation` would skew the captured photo (and on
/// some macOS versions the preview's data-output buffers) by 90°.
/// The orientation snapshot from Flutter (always `portraitUp` on
/// macOS — desktops don't rotate) is therefore ignored at the
/// connection layer; the recorded video's track transform is still
/// `.identity` from VideoRecorder's existing mapping, so video stays
/// landscape too.
extension AVCaptureConnection {
    func applyUxCaptureOrientation(_ orientation: DeviceOrientationFlutter) {
        // Intentionally empty.
    }
}
