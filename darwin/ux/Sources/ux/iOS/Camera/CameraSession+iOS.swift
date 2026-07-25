#if os(iOS)

import AVFoundation
import Foundation

/// iOS-only platform setup for [CameraSession]: enables the
/// "application owns the AVAudioSession" flags (so AVCaptureSession
/// doesn't yank our `.playAndRecord` category back), and subscribes
/// to `AVCaptureSessionWasInterrupted` / `…InterruptionEnded`
/// notifications (which only fire on iOS — `AVCaptureSession.InterruptionReason`
/// isn't even declared on macOS).
extension CameraSession {
    func setupPlatform() {
        // Telegram + camera_avfoundation both set these — keeps
        // AVFoundation from yanking our audio session category out
        // from under the app. iOS-only properties on AVCaptureSession.
        av.automaticallyConfiguresApplicationAudioSession = false
        av.usesApplicationAudioSession = true

        interruptedObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: av,
            queue: .main
        ) { [weak self] note in
            let code = note.userInfo?[AVCaptureSessionInterruptionReasonKey]
                as? Int ?? 0
            self?.onInterrupted?(reasonName(for: code))
        }

        resumedObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: av,
            queue: .main
        ) { [weak self] _ in
            self?.onResumed?()
        }
    }
}

/// Decode the integer reason that comes with
/// `AVCaptureSessionWasInterrupted`. Used in the event payload sent
/// to Dart.
private func reasonName(for code: Int) -> String {
    guard let reason = AVCaptureSession.InterruptionReason(rawValue: code) else {
        return "unknown"
    }
    switch reason {
    case .videoDeviceNotAvailableInBackground:
        return "videoDeviceNotAvailableInBackground"
    case .audioDeviceInUseByAnotherClient:
        return "audioDeviceInUseByAnotherClient"
    case .videoDeviceInUseByAnotherClient:
        return "videoDeviceInUseByAnotherClient"
    case .videoDeviceNotAvailableWithMultipleForegroundApps:
        return "videoDeviceNotAvailableWithMultipleForegroundApps"
    case .videoDeviceNotAvailableDueToSystemPressure:
        return "videoDeviceNotAvailableDueToSystemPressure"
    @unknown default:
        return "unknown"
    }
}

#endif
