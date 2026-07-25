#if os(iOS)

import AVFoundation
import UIKit

/// Bridges physical-device rotation notifications to a closure callback.
/// Observed source is `UIDevice.current.orientation` — independent of
/// any UI orientation lock, so this fires even while the app's window
/// is portrait-locked. `.faceUp` / `.faceDown` are ignored (no useful
/// direction).
///
/// `UIDevice.beginGeneratingDeviceOrientationNotifications()` must be
/// called on main, balanced with `end…()`; this class enforces both.
///
/// iOS-only. The macOS counterpart in
/// `macOS/Camera/DeviceOrientationBridge+macOS.swift` is a no-op —
/// desktops don't rotate, so `current` stays at the initial
/// `portraitUp` and the listener never fires.
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

extension DeviceOrientationFlutter {
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
}

#endif
