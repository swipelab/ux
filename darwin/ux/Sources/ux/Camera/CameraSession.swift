import AVFoundation
import Foundation

/// Thin wrapper around `AVCaptureSession` that owns the lifecycle
/// helpers and observes the runtime-error / interruption
/// notifications (iOS only — macOS has no equivalent), surfacing them
/// through closures so [CameraInstance] doesn't repeat the boilerplate.
///
/// All `AVCaptureSession` mutations (input/output add/remove, start,
/// stop) must run on the caller's `sessionQueue`. This class doesn't
/// enforce that; the contract is that
/// [CameraInstance.sessionQueue.async { … }] wraps every call site.
///
/// Platform-specific init bits — the application-audio-session flags
/// and the interruption observers — live in `setupPlatform()` whose
/// real implementation is in `ios/Classes/Camera/CameraSession+iOS.swift`.
/// The macOS counterpart (`macos/Classes/Camera/CameraSession+macOS.swift`)
/// is a no-op: macOS has no `AVAudioSession` and no
/// `AVCaptureSessionWasInterrupted` notification.
final class CameraSession {
    let av: AVCaptureSession

    /// Called on `.main` when the session reports an unrecoverable
    /// runtime error. Notable case: `.mediaServicesWereReset` — the
    /// caller typically tears down and recreates the session.
    var onRuntimeError: ((NSError) -> Void)?

    /// Called on `.main` when the session is interrupted (e.g. video
    /// device taken by another foreground client, audio session
    /// interruption, or app backgrounded with `usesApplicationAudioSession`).
    /// iOS only — never fires on macOS.
    var onInterrupted: ((String) -> Void)?

    /// Called on `.main` when an earlier interruption ends. iOS only.
    var onResumed: (() -> Void)?

    var runtimeErrorObserver: NSObjectProtocol?
    var interruptedObserver: NSObjectProtocol?
    var resumedObserver: NSObjectProtocol?

    init() {
        av = AVCaptureSession()
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: av,
            queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                ?? NSError(domain: "ux.camera", code: -1)
            self?.onRuntimeError?(error)
        }
        setupPlatform()
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
