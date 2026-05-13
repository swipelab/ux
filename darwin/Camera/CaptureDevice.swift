import AVFoundation

/// Static helpers for camera-device discovery and per-device init.
///
/// Mirrors what telegram-ios's `CameraDevice` does for the
/// session-priority + format-negotiation cases we actually care
/// about — front / back wide-angle only. Telegram's preference for
/// `TripleCamera` / `DualCamera` is for multi-cam zoom UX we don't
/// build today; if we ever need it, this is where it goes.
enum CaptureDevice {
    /// Enumerate the cameras the system exposes. On iOS that's the
    /// front + back wide-angle cameras (in that order, back first).
    /// On macOS it's the built-in FaceTime HD plus any external /
    /// Continuity cameras the OS reports.
    static func discover() -> [DiscoveredCamera] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        // Sort so back devices come first; the chat composer opens
        // the back camera by default elsewhere, so this matches the
        // common "first available" pick. On macOS positions are all
        // `.unspecified`, so the sort is a no-op there.
        return session.devices
            .sorted { positionRank($0.position) < positionRank($1.position) }
            .map { device in
                DiscoveredCamera(
                    device: device,
                    lens: lensName(for: device.position),
                    // iOS doesn't expose sensor orientation directly;
                    // 90° matches what `camera_avfoundation` reports
                    // and what banlu's `normalizeCameraCapture` math
                    // assumes for iOS sensors. macOS desktop cameras
                    // are already landscape — 0 is the right answer
                    // there but the value is unused on macOS (no
                    // recording rotation, no preview rotation).
                    sensorOrientation: 90
                )
            }
    }

    /// Per-platform set of device types the discovery session asks
    /// for. iOS only has the built-in cameras; macOS additionally
    /// surfaces externals + Continuity Camera (iPhone-as-webcam).
    /// `.external` / `.externalUnknown` / `.continuityCamera` are
    /// macOS-only enum cases — referencing them on iOS would not
    /// compile, hence the `#if os(macOS)` block.
    private static var deviceTypes: [AVCaptureDevice.DeviceType] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        #if os(macOS)
        if #available(macOS 14.0, *) {
            types.append(.external)
            types.append(.continuityCamera)
        } else {
            types.append(.externalUnknown)
        }
        #endif
        return types
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
