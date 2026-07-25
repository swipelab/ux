#if os(macOS)

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
    func applyXCaptureOrientation(_ orientation: DeviceOrientationFlutter) {
        // Pin to 0° rotation (`.landscapeRight`) on macOS — desktop
        // cameras are physically landscape and any non-zero rotation
        // physically rotates the buffer. Diagnostic build confirmed
        // a 720x1280 CGImage (portrait) when this was set to 90°,
        // proving Apple's docs ("AVCapturePhotoOutput uses EXIF only,
        // no physical rotation") don't apply on macOS — and the data
        // output's connection honors the same setter, so preview +
        // video also rotate.
        //
        // The Flutter snapshot is always `portraitUp` on macOS
        // (desktops don't rotate); we ignore it and force landscape.
        if #available(macOS 14.0, *) {
            if isVideoRotationAngleSupported(0) {
                videoRotationAngle = 0
                return
            }
        }
        if isVideoOrientationSupported {
            videoOrientation = .landscapeRight
        }
    }
}

#endif
