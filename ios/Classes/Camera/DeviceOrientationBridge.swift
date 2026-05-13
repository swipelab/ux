import AVFoundation
import UIKit

/// Translates between Flutter's `DeviceOrientation` (4 enum values
/// shipped as strings across the channel) and AVFoundation's
/// `AVCaptureVideoOrientation`, and bridges physical-device rotation
/// notifications to a closure callback.
///
/// Observed orientation source is `UIDevice.current.orientation` —
/// independent of any UI orientation lock, so this fires even while
/// the app's window is portrait-locked. `.faceUp` / `.faceDown` are
/// ignored (no useful direction).
///
/// `UIDevice.beginGeneratingDeviceOrientationNotifications()` must be
/// called on main, balanced with `end…()`; this class enforces both.
final class DeviceOrientationBridge {
    typealias Listener = (DeviceOrientationFlutter) -> Void

    private var listener: Listener?
    private var observer: NSObjectProtocol?

    /// Most recent valid orientation observed. Initialised to
    /// `portraitUp` so callers have a starting value before the first
    /// rotation event.
    private(set) var current: DeviceOrientationFlutter = .portraitUp

    /// Starts observing. Safe to call multiple times; subsequent calls
    /// replace the listener but don't re-register.
    func start(listener: @escaping Listener) {
        self.listener = listener
        guard observer == nil else { return }

        // beginGeneratingDeviceOrientationNotifications is main-only.
        if Thread.isMainThread {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        } else {
            DispatchQueue.main.sync {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            }
        }

        // Seed `current` from the device's reported orientation if it
        // is already a valid one.
        if let seed = DeviceOrientationFlutter(uiDevice: UIDevice.current.orientation) {
            current = seed
        }

        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: UIDevice.current,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            guard let next = DeviceOrientationFlutter(uiDevice: UIDevice.current.orientation) else {
                return
            }
            guard next != self.current else { return }
            self.current = next
            self.listener?(next)
        }
    }

    func stop() {
        listener = nil
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
            DispatchQueue.main.async {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
        }
    }

    deinit { stop() }
}

/// Mirrors Flutter's `DeviceOrientation` — the four cardinal values
/// that travel over the `ux/camera` channel as wire strings. `public`
/// so the host app's XCTest target can verify the
/// `DeviceOrientationFlutter` / `AVCaptureVideoOrientation` mapping
/// without `@testable import`.
public enum DeviceOrientationFlutter: String {
    case portraitUp
    case landscapeLeft
    case portraitDown
    case landscapeRight

    /// Parse a wire string. Returns `.portraitUp` for unknown inputs
    /// (matches the Dart-side fallback in `MethodChannelUxCameraBackend`).
    public static func parse(_ raw: String?) -> DeviceOrientationFlutter {
        return DeviceOrientationFlutter(rawValue: raw ?? "") ?? .portraitUp
    }

    /// `UIDeviceOrientation` → Flutter convention is a direct 1:1 by
    /// name. Despite the AV-side flip, `UIDeviceOrientation.landscapeLeft`
    /// and Flutter's `landscapeLeft` describe the same physical pose
    /// (home button on the right). The flip lives in
    /// [avVideoOrientation], not here.
    public init?(uiDevice: UIDeviceOrientation) {
        switch uiDevice {
        case .portrait: self = .portraitUp
        case .portraitUpsideDown: self = .portraitDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        default: return nil
        }
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
