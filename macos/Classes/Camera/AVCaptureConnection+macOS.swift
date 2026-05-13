import AVFoundation

/// macOS counterpart of `AVCaptureConnection+iOS.swift`.
///
/// macOS desktop cameras are physically fixed landscape. AVFoundation
/// initialises `connection.videoOrientation` to `.portrait` by
/// default though — same as iOS — which on macOS *also* rotates the
/// sensor frame 90° CW (manifested as a 90° CW selfie photo + a
/// rotated preview). So we *do* set the orientation on macOS, but
/// pin it to `.landscapeRight` regardless of the snapshot Flutter
/// passes (which is always `portraitUp` on macOS — desktops don't
/// rotate). That tells AVFoundation "leave the sensor frame alone";
/// captured JPEG ends up landscape with EXIF orientation = 1 (no
/// rotation), and preview data-output buffers flow at the sensor's
/// native aspect.
extension AVCaptureConnection {
    func applyUxCaptureOrientation(_ orientation: DeviceOrientationFlutter) {
        if isVideoOrientationSupported {
            videoOrientation = .landscapeRight
        }
    }
}
