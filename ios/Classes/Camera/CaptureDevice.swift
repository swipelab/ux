import AVFoundation

/// Static helpers for camera-device discovery and per-device init.
///
/// Mirrors what telegram-ios's `CameraDevice` does for the
/// session-priority + format-negotiation cases we actually care
/// about — front / back wide-angle only. Telegram's preference for
/// `TripleCamera` / `DualCamera` is for multi-cam zoom UX we don't
/// build today; if we ever need it, this is where it goes.
enum CaptureDevice {
    /// Enumerate the front + back wide-angle cameras the system
    /// exposes. Order: back first, front second. Stable for the
    /// lifetime of the process — iOS doesn't hot-swap cameras.
    static func discover() -> [DiscoveredCamera] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        // Sort so back devices come first; the chat composer opens
        // the back camera by default elsewhere, so this matches the
        // common "first available" pick.
        return session.devices
            .sorted { positionRank($0.position) < positionRank($1.position) }
            .map { device in
                DiscoveredCamera(
                    device: device,
                    lens: lensName(for: device.position),
                    // iOS doesn't expose sensor orientation directly;
                    // 90° matches what `camera_avfoundation` reports
                    // and what banlu's `normalizeCameraCapture` math
                    // assumes for iOS sensors.
                    sensorOrientation: 90
                )
            }
    }

    /// Apply our default per-device config: continuous autofocus,
    /// continuous auto-exposure, torch off. Idempotent; safe to call
    /// repeatedly. The block is wrapped in
    /// `lockForConfiguration` / `unlockForConfiguration`.
    static func applyDefaults(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.hasTorch && device.isTorchModeSupported(.off) {
                device.torchMode = .off
            }
        } catch {
            // Best-effort — a device that refuses lockForConfiguration
            // will still capture frames; we just can't tweak focus.
        }
    }

    // MARK: - private

    private static func positionRank(_ position: AVCaptureDevice.Position) -> Int {
        switch position {
        case .back: return 0
        case .front: return 1
        default: return 2
        }
    }

    private static func lensName(for position: AVCaptureDevice.Position) -> String {
        switch position {
        case .front: return "front"
        case .back: return "back"
        default: return "back"
        }
    }
}

/// One row of the discovery result. `lens` and `sensorOrientation`
/// match the wire shape expected by Dart's
/// `MethodChannelUxCameraBackend.availableCameras()`.
struct DiscoveredCamera {
    let device: AVCaptureDevice
    let lens: String
    let sensorOrientation: Int

    var uniqueID: String { device.uniqueID }

    func toWire() -> [String: Any] {
        return [
            "id": uniqueID,
            "lens": lens,
            "sensorOrientation": sensorOrientation,
        ]
    }
}
