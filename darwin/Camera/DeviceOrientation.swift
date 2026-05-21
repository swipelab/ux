import AVFoundation

/// Mirrors Flutter's `DeviceOrientation` — the four cardinal values
/// that travel over the `ux/camera` channel as wire strings. `public`
/// so the host app's XCTest target can verify the
/// `DeviceOrientationFlutter` / `AVCaptureVideoOrientation` mapping
/// without `@testable import`.
///
/// The enum is platform-shared; the listener that turns physical
/// rotation into a stream of these values is platform-specific —
/// see `ios/Classes/Camera/DeviceOrientationBridge.swift` for the
/// iOS implementation and `macos/Classes/Camera/DeviceOrientationBridge.swift`
/// for the macOS one (no-op; desktops don't rotate).
public enum DeviceOrientationFlutter: String {
    case portraitUp
    case landscapeLeft
    case portraitDown
    case landscapeRight

    /// Parse a wire string. Returns `.portraitUp` for unknown inputs
    /// (matches the Dart-side fallback in `MethodChannelXCameraBackend`).
    public static func parse(_ raw: String?) -> DeviceOrientationFlutter {
        return DeviceOrientationFlutter(rawValue: raw ?? "") ?? .portraitUp
    }

    /// AVFoundation video orientation. Translates Flutter's portrait-
    /// relative convention to AVFoundation's hardware-relative one.
    /// Used to drive `AVCaptureConnection.videoOrientation`.
    public var avVideoOrientation: AVCaptureVideoOrientation {
        switch self {
        case .portraitUp: return .portrait
        case .portraitDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        }
    }
}
