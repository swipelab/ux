#if os(iOS)

import AVFoundation

/// Per-platform shim for applying capture-time rotation to an
/// `AVCaptureConnection`. On iOS the connection's `videoOrientation`
/// genuinely rotates the sample buffers / captured photo; on macOS
/// it appears to rotate stills but not preview/data-output, AND
/// desktop cameras are physically landscape so any rotation skews
/// the result. The macOS counterpart in
/// `macOS/Camera/AVCaptureConnection+macOS.swift` is a no-op.
extension AVCaptureConnection {
    func applyXCaptureOrientation(_ orientation: DeviceOrientationFlutter) {
        if isVideoOrientationSupported {
            videoOrientation = orientation.avVideoOrientation
        }
    }
}

#endif
