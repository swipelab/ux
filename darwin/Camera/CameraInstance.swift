import AVFoundation
#if canImport(UIKit)
import Flutter
#else
import FlutterMacOS
#endif
import Foundation

/// One per `UxCameraController` on the Dart side. Owns its
/// `AVCaptureSession`, the texture-backed preview pipeline, photo
/// output, audio + video data outputs, and the
/// [VideoRecorder] when a recording is in flight. Multiple instances
/// coexist; the `[CameraPlugin]` keys them by `handle`.
///
/// **Threading**:
/// - Session config (add/remove inputs/outputs, start, stop) runs on
///   `sessionQueue` (serial).
/// - Video sample-buffer delegate fires on `videoBufferQueue` (serial).
/// - Audio sample-buffer delegate fires on `audioBufferQueue` (serial).
/// - [VideoRecorder] mutates its writer state on `recorderQueue` (serial).
/// - All public completions land on `.main`.
final class CameraInstance {
    let handle: Int

    /// Called whenever the instance has an event to forward to Dart.
    /// The payload is the `{event, handle, …}` map the EventChannel
    /// emits. Set by the plugin at construction.
    var onEvent: (([String: Any]) -> Void)?

    private let session = CameraSession()
    private let sink = PreviewSink()
    private let photoOutput = PhotoOutput()
    private let orientation = DeviceOrientationBridge()

    private let sessionQueue: DispatchQueue
    private let videoBufferQueue: DispatchQueue
    private let audioBufferQueue: DispatchQueue
    private let recorderQueue: DispatchQueue

    private var device: AVCaptureDevice?
    private var deviceInput: AVCaptureDeviceInput?
    private var videoDataOutput: AVCaptureVideoDataOutput?

    private var audioDevice: AVCaptureDevice?
    private var audioDeviceInput: AVCaptureDeviceInput?
    private var audioDataOutput: AVCaptureAudioDataOutput?

    private let fanout: SampleFanout

    private var flashMode: AVCaptureDevice.FlashMode = .off
    private var lockedOrientation: DeviceOrientationFlutter?
    private var enableAudio: Bool = false
    private var disposed = false

    /// Set during [startVideoRecording], cleared after the stop
    /// completion fires. Lives on `sessionQueue` (set/cleared); the
    /// [SampleFanout] holds a parallel reference (under its own lock)
    /// for the videoBufferQueue / audioBufferQueue to access without
    /// crossing queue boundaries per frame.
    private var videoRecorder: VideoRecorder?

    /// `uniqueID` of the AVCaptureDevice this instance is currently
    /// bound to, or `nil` after [dispose]. Used by [CameraPlugin] to
    /// release its device claim. Read on `.main`.
    var currentCameraId: String? { device?.uniqueID }

    /// Whether this instance was constructed with `enableAudio: true`
    /// and therefore owns the app-global audio claim. Read on `.main`.
    var audioClaimed: Bool { enableAudio }

    /// Hop to this instance's serial session queue. Public entry
    /// point so the plugin can dispatch session work without
    /// exposing the queue directly.
    func sessionQueueAsync(_ block: @escaping () -> Void) {
        sessionQueue.async(execute: block)
    }

    /// Active-format dimensions in the camera sensor's natural
    /// orientation (typically landscape — `1920×1080` etc.). Set
    /// after `create` / `setDescription` configures the session.
    private(set) var previewSize: CGSize = .zero

    /// Texture id handed back to Dart. Stable for the lifetime of
    /// the instance.
    private(set) var textureId: Int64 = -1

    init(handle: Int) {
        self.handle = handle
        sessionQueue = DispatchQueue(label: "ux.camera.session.\(handle)")
        videoBufferQueue = DispatchQueue(label: "ux.camera.video.\(handle)")
        audioBufferQueue = DispatchQueue(label: "ux.camera.audio.\(handle)")
        recorderQueue = DispatchQueue(label: "ux.camera.recorder.\(handle)")
        fanout = SampleFanout(sink: sink)

        session.onRuntimeError = { [weak self] error in
            self?.emit([
                "event": "sessionError",
                "code": "session_runtime_error",
                "description": error.localizedDescription,
            ])
        }
        session.onInterrupted = { [weak self] reason in
            self?.emit(["event": "sessionInterrupted", "reason": reason])
        }
        session.onResumed = { [weak self] in
            self?.emit(["event": "sessionResumed"])
        }
    }

    // MARK: - Lifecycle

    /// Synchronously configure the session for [cameraId]. Registers
    /// the texture, attaches audio if requested, upgrades the audio
    /// session, and starts the orientation bridge. Must run on
    /// sessionQueue.
    func create(
        cameraId: String,
        enableAudio: Bool,
        registry: FlutterTextureRegistry
    ) throws {
        precondition(!disposed)
        self.enableAudio = enableAudio

        textureId = sink.register(with: registry)

        if enableAudio {
            // Widen the shared audio session category before we
            // attach the mic input — matches `camera_avfoundation`'s
            // defensive pattern. No-op if already widened.
            AudioSession.upgradeForRecording()
        }

        try configureSession(forDeviceUniqueID: cameraId, replacing: false)

        orientation.start { [weak self] next in
            guard let self = self else { return }
            self.sessionQueue.async { self.applyOrientationFollowDevice(next) }
            self.emit([
                "event": "deviceOrientationChanged",
                "orientation": next.rawValue,
            ])
        }
    }

    /// Start the session. Must run on sessionQueue.
    func initialize() {
        precondition(!disposed)
        session.start()
    }

    /// Tear everything down. Idempotent. Hard-cancels any in-flight
    /// recording (drops queued audio, `cancelWriting`, deletes the
    /// partial file — telegram-ios's `cancelRecording` path). Must run
    /// on sessionQueue.
    func dispose() {
        if disposed { return }
        disposed = true

        if let recorder = videoRecorder {
            recorder.cancel()
            videoRecorder = nil
            fanout.recorder = nil
        }

        session.stop()
        if let input = deviceInput { session.av.removeInput(input) }
        if let input = audioDeviceInput { session.av.removeInput(input) }
        if let output = videoDataOutput { session.av.removeOutput(output) }
        if let output = audioDataOutput { session.av.removeOutput(output) }
        session.av.removeOutput(photoOutput.avOutput)

        videoDataOutput = nil
        deviceInput = nil
        device = nil
        audioDeviceInput = nil
        audioDataOutput = nil
        audioDevice = nil

        orientation.stop()
        sink.unregister()
        onEvent = nil
    }

    // MARK: - Camera flip

    /// Replace the video input device (audio stays attached). Returns
    /// the new previewSize. Must run on sessionQueue.
    func setDescription(cameraId: String) throws -> CGSize {
        precondition(!disposed)
        try configureSession(forDeviceUniqueID: cameraId, replacing: true)
        return previewSize
    }

    // MARK: - Flash + orientation

    func setFlashMode(_ mode: AVCaptureDevice.FlashMode) {
        flashMode = mode
    }

    func lockCaptureOrientation(_ next: DeviceOrientationFlutter) {
        lockedOrientation = next
        applyVideoOrientationOnPreview(next)
    }

    func unlockCaptureOrientation() {
        lockedOrientation = nil
        applyOrientationFollowDevice(orientation.current)
    }

    // MARK: - Photo

    func takePicture(
        snapshot: DeviceOrientationFlutter,
        completion: @escaping (Result<String, NSError>) -> Void
    ) {
        photoOutput.take(orientation: snapshot, flashMode: flashMode, completion: completion)
    }

    // MARK: - Video recording

    /// Begin a recording. Must run on sessionQueue. Throws on writer
    /// setup failure (typically a path / file-system issue).
    /// [snapshot] is the orientation embedded as the file's track
    /// transform — when the user is holding the device landscape,
    /// pass landscape here and the file plays back landscape.
    func startVideoRecording(
        snapshot: DeviceOrientationFlutter
    ) throws {
        precondition(!disposed)
        guard videoRecorder == nil else {
            throw NSError(
                domain: "ux.camera",
                code: -20,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Recording already in flight"
                ]
            )
        }
        guard let videoOutput = videoDataOutput else {
            throw NSError(
                domain: "ux.camera",
                code: -21,
                userInfo: [NSLocalizedDescriptionKey: "Video output unavailable"]
            )
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ux_camera_\(UUID().uuidString).mp4")

        // Audio is viable only when both the device input attached AND
        // the audio output can recommend writer settings. Empty
        // recommended settings means the audio path can't be muxed —
        // telegram-ios fails the whole recording in that case
        // (CameraOutput.swift:397-401); we silent-fall back to
        // video-only so an audio-permission glitch doesn't break the
        // page.
        var audioViable = enableAudio
            && audioDeviceInput != nil
            && audioDataOutput != nil

        let baseVideoSettings = videoOutput.recommendedVideoSettingsForAssetWriter(
            writingTo: .mp4
        ) as? [String: Any]

        var baseAudioSettings: [String: Any] = [:]
        if audioViable, let ao = audioDataOutput {
            baseAudioSettings = (ao.recommendedAudioSettingsForAssetWriter(
                writingTo: .mp4
            ) as? [String: Any]) ?? [:]
            if baseAudioSettings.isEmpty {
                audioViable = false
            }
        }

        let recorder = VideoRecorder(
            url: url,
            orientation: snapshot,
            hasAudio: audioViable,
            baseVideoSettings: baseVideoSettings,
            baseAudioSettings: baseAudioSettings,
            recorderQueue: recorderQueue
        )
        recorder.onDiagnostic = { [weak self] msg in
            self?.emit(["event": "diagnostic", "message": msg])
        }
        try recorder.start()

        videoRecorder = recorder
        // Publish the recorder under the fanout's lock so the buffer
        // queues see it on their next sample.
        fanout.recorder = recorder
    }

    /// Stop the in-flight recording. Completion fires on
    /// `recorderQueue` (which is `.async`'d here back to `.main` by
    /// the plugin). Returns the file path or an error.
    ///
    /// The fanout reference stays attached until `finishWriting`
    /// completes — the recorder relies on *post-stop* sample buffers
    /// crossing `recordingStopSampleTime` to trigger `maybeFinish`.
    /// Detaching the feed at the wrong moment (before stop) is what
    /// caused the 3-second watchdog to be the only thing finishing
    /// the writer.
    func stopVideoRecording(
        completion: @escaping (Result<URL, NSError>) -> Void
    ) {
        guard let recorder = videoRecorder else {
            completion(.failure(NSError(
                domain: "ux.camera",
                code: -22,
                userInfo: [NSLocalizedDescriptionKey: "No recording in flight"]
            )))
            return
        }

        recorder.stop { [weak self] outcome in
            guard let self = self else {
                completion(outcome)
                return
            }
            self.sessionQueue.async {
                self.fanout.recorder = nil
                self.videoRecorder = nil
            }
            completion(outcome)
        }
    }

    // MARK: - Private

    private func configureSession(
        forDeviceUniqueID cameraId: String,
        replacing: Bool
    ) throws {
        guard let device = AVCaptureDevice(uniqueID: cameraId) else {
            throw NSError(
                domain: "ux.camera",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Camera \(cameraId) not found"]
            )
        }

        var caughtError: NSError?

        session.configure {
            if replacing, let oldInput = deviceInput {
                session.av.removeInput(oldInput)
            }

            do {
                let newInput = try AVCaptureDeviceInput(device: device)
                guard session.av.canAddInput(newInput) else {
                    throw NSError(
                        domain: "ux.camera",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot add input"]
                    )
                }
                session.av.addInput(newInput)
                deviceInput = newInput
            } catch let error as NSError {
                caughtError = error
                return
            }

            if !replacing {
                if session.av.canSetSessionPreset(.high) {
                    session.av.sessionPreset = .high
                }

                let videoOutput = AVCaptureVideoDataOutput()
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        kCVPixelFormatType_32BGRA,
                ]
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.setSampleBufferDelegate(
                    fanout,
                    queue: videoBufferQueue
                )
                if session.av.canAddOutput(videoOutput) {
                    session.av.addOutput(videoOutput)
                }
                videoDataOutput = videoOutput

                if session.av.canAddOutput(photoOutput.avOutput) {
                    session.av.addOutput(photoOutput.avOutput)
                }

                if enableAudio,
                   let mic = AVCaptureDevice.default(for: .audio) {
                    do {
                        let audioInput = try AVCaptureDeviceInput(device: mic)
                        if session.av.canAddInput(audioInput) {
                            session.av.addInput(audioInput)
                            audioDevice = mic
                            audioDeviceInput = audioInput
                        }
                    } catch {
                        // Don't fail the whole setup over audio — fall
                        // through; the recording will simply have no
                        // audio track.
                    }

                    let audioOutput = AVCaptureAudioDataOutput()
                    audioOutput.setSampleBufferDelegate(
                        fanout,
                        queue: audioBufferQueue
                    )
                    if session.av.canAddOutput(audioOutput) {
                        session.av.addOutput(audioOutput)
                        audioDataOutput = audioOutput
                    }
                }
            }

            // Apply preview-output orientation. Mirroring is deliberately
            // NOT set here — the data output feeds both the preview
            // texture and the recorder, so mirroring at the connection
            // would land in the recorded MP4 too. Telegram avoids this
            // by mirroring at the preview-LAYER level (CALayer transform
            // in `CameraPreviewView.mirroring`). Our FlutterTexture
            // equivalent is a `Transform.flip` in [CameraThumb] for the
            // front camera — raw sensor feed at capture, mirror as a
            // playback decision.
            if let videoConn = videoDataOutput?.connection(with: .video) {
                if videoConn.isVideoOrientationSupported {
                    videoConn.videoOrientation = lockedOrientation?.avVideoOrientation
                        ?? orientation.current.avVideoOrientation
                }
                if videoConn.isVideoMirroringSupported {
                    videoConn.automaticallyAdjustsVideoMirroring = false
                    videoConn.isVideoMirrored = false
                }
            }

            self.device = device
            CaptureDevice.applyDefaults(device)

            let dims = CMVideoFormatDescriptionGetDimensions(
                device.activeFormat.formatDescription
            )
            previewSize = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
        }

        if let error = caughtError {
            throw error
        }
    }

    private func applyOrientationFollowDevice(_ next: DeviceOrientationFlutter) {
        // When a lock is in effect the preview ignores physical
        // rotation — the lock wins.
        guard lockedOrientation == nil else { return }
        applyVideoOrientationOnPreview(next)
    }

    private func applyVideoOrientationOnPreview(_ next: DeviceOrientationFlutter) {
        guard let conn = videoDataOutput?.connection(with: .video),
              conn.isVideoOrientationSupported else {
            return
        }
        conn.videoOrientation = next.avVideoOrientation
    }

    private func emit(_ extras: [String: Any]) {
        var payload: [String: Any] = ["handle": handle]
        payload.merge(extras, uniquingKeysWith: { _, new in new })
        DispatchQueue.main.async { [weak self] in self?.onEvent?(payload) }
    }
}

/// Single sample-buffer delegate for both video + audio outputs.
/// Forwards video frames to [PreviewSink] and (when a recording is
/// active) both video and audio sample buffers to [VideoRecorder].
///
/// The `recorder` reference is cross-queue: written from
/// `sessionQueue` (set on startVideoRecording, cleared on
/// stopVideoRecording), read from `videoBufferQueue` and
/// `audioBufferQueue` (once per sample). An `NSLock` guards each
/// access — cheap, ~tens of nanoseconds per frame.
private final class SampleFanout: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate
{
    private let sink: PreviewSink
    private let recorderLock = NSLock()
    private var _recorder: VideoRecorder?

    var recorder: VideoRecorder? {
        get {
            recorderLock.lock(); defer { recorderLock.unlock() }
            return _recorder
        }
        set {
            recorderLock.lock(); defer { recorderLock.unlock() }
            _recorder = newValue
        }
    }

    init(sink: PreviewSink) {
        self.sink = sink
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output is AVCaptureVideoDataOutput {
            sink.receive(sampleBuffer: sampleBuffer)
            recorder?.appendVideo(sampleBuffer)
        } else if output is AVCaptureAudioDataOutput {
            recorder?.appendAudio(sampleBuffer)
        }
    }
}
