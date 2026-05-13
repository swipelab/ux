import AVFoundation
import Foundation

/// Thin wrapper around `AVCaptureSession` that owns the lifecycle
/// helpers and observes the runtime-error / interruption
/// notifications, surfacing them through closures so
/// [CameraInstance] doesn't repeat the boilerplate.
///
/// All `AVCaptureSession` mutations (input/output add/remove, start,
/// stop) must run on the caller's `sessionQueue`. This class doesn't
/// enforce that; the contract is that
/// [CameraInstance.sessionQueue.async { … }] wraps every call site.
final class CameraSession {
    let av: AVCaptureSession

    /// Called on `.main` when the session reports an unrecoverable
    /// runtime error. Notable case: `.mediaServicesWereReset` — the
    /// caller typically tears down and recreates the session.
    var onRuntimeError: ((NSError) -> Void)?

    /// Called on `.main` when the session is interrupted (e.g. video
    /// device taken by another foreground client, audio session
    /// interruption, or app backgrounded with `usesApplicationAudioSession`).
    /// String describes the reason — `"videoDeviceInUseByAnotherClient"`,
    /// `"audioDeviceInUseByAnotherClient"`, `"videoDeviceNotAvailableInBackground"`, etc.
    var onInterrupted: ((String) -> Void)?

    /// Called on `.main` when an earlier interruption ends.
    var onResumed: (() -> Void)?

    private var runtimeErrorObserver: NSObjectProtocol?
    private var interruptedObserver: NSObjectProtocol?
    private var resumedObserver: NSObjectProtocol?

    init() {
        av = AVCaptureSession()

        // Telegram + camera_avfoundation both set this — keeps
        // AVFoundation from yanking our audio session category out
        // from under the app.
        av.automaticallyConfiguresApplicationAudioSession = false
        av.usesApplicationAudioSession = true

        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: av,
            queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                ?? NSError(domain: "ux.camera", code: -1)
            self?.onRuntimeError?(error)
        }

        interruptedObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: av,
            queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[AVCaptureSessionInterruptionReasonKey]
                as? Int ?? 0
            self?.onInterrupted?(reasonName(for: reason))
        }

        resumedObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: av,
            queue: .main
        ) { [weak self] _ in
            self?.onResumed?()
        }
    }

    deinit {
        if let o = runtimeErrorObserver { NotificationCenter.default.removeObserver(o) }
        if let o = interruptedObserver { NotificationCenter.default.removeObserver(o) }
        if let o = resumedObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// Configure block; pairs `beginConfiguration` /
    /// `commitConfiguration` so every add/remove batch lands as one
    /// session update. Caller must be on sessionQueue.
    func configure(_ block: () -> Void) {
        av.beginConfiguration()
        block()
        av.commitConfiguration()
    }

    /// Start the session if it isn't already running.
    /// Caller must be on sessionQueue.
    func start() {
        if !av.isRunning { av.startRunning() }
    }

    /// Stop the session if it's running.
    /// Caller must be on sessionQueue.
    func stop() {
        if av.isRunning { av.stopRunning() }
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
