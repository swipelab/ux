import AVFoundation

/// macOS counterpart of `AVCaptureConnection+iOS.swift`.
///
/// macOS desktop cameras are physically fixed landscape, but
/// `AVCapturePhotoOutput`'s connection defaults to a setting that
/// rotates the captured JPEG 90° CW. We pin the connection to
/// landscape (or 0° rotation, depending on the available API) so
/// the JPEG matches what the preview shows.
///
/// `videoOrientation` was deprecated in macOS 14 / iOS 17 in favour
/// of `videoRotationAngle` (a `CGFloat` in degrees). On macOS 14+
/// `videoOrientation` may be silently ignored — that's exactly the
/// symptom we hit ("photo still rotated 90° CW even after setting
/// videoOrientation = .landscapeRight"). Prefer the new API where
/// available, fall back to the deprecated one for older macOS.
extension AVCaptureConnection {
    func applyUxCaptureOrientation(_ orientation: DeviceOrientationFlutter) {
        // macOS `AVCapturePhotoOutput`'s photo connection captures in
        // landscape natively when its rotation hint is `.portrait`
        // (90°). Counter-intuitive vs iOS where `.portrait` rotates
        // the landscape sensor to portrait, but verified empirically
        // — setting `.landscapeRight` / `videoRotationAngle = 0` left
        // the JPEG rotated 90° CW. The data output's connection on
        // macOS doesn't honor `videoOrientation` / `videoRotationAngle`
        // (or returns supported = false), so this setter is a no-op
        // there and preview + video stay correct.
        if #available(macOS 14.0, *) {
            if isVideoRotationAngleSupported(90) {
                videoRotationAngle = 90
                return
            }
        }
        if isVideoOrientationSupported {
            videoOrientation = .portrait
        }
    }
}
