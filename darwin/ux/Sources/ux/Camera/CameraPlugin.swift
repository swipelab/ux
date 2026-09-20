import AVFoundation
#if canImport(UIKit)
import Flutter
#else
import FlutterMacOS
#endif

/// `ux/camera` + `ux/camera/events` registrar. Routes channel calls
/// to per-handle [CameraInstance]s. Enforces device + audio claims
/// across instances so a second controller against an already-held
/// camera or audio session fails fast with the right error code.
///
/// Phase 2 scope: no video recording. `startVideoRecording` /
/// `stopVideoRecording` return `unsupported_format`.
public class CameraPlugin: NSObject, NativePlugin, FlutterStreamHandler {
    private weak var textureRegistry: FlutterTextureRegistry?

    private var instances: [Int: CameraInstance] = [:]
    private var nextHandle: Int = 1

    // Multi-instance contention bookkeeping.
    private var devicesInUse: Set<String> = []
    private var audioInUse: Bool = false

    private var eventSink: FlutterEventSink?

    public func register(with registrar: FlutterPluginRegistrar) {
        // `uxTextures` / `uxMessenger` are per-platform shims —
        // see `FlutterRegistrar+iOS.swift` / `…+macOS.swift`. iOS has
        // them as methods, macOS as properties; the extensions paper
        // over that so this call site stays platform-agnostic.
        textureRegistry = registrar.uxTextures

        let methods = FlutterMethodChannel(
            name: "ux/camera",
            binaryMessenger: registrar.uxMessenger
        )
        methods.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }

        let events = FlutterEventChannel(
            name: "ux/camera/events",
            binaryMessenger: registrar.uxMessenger
        )
        events.setStreamHandler(self)
    }

    // MARK: - FlutterStreamHandler

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: - Method dispatch

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "availableCameras":
            availableCameras(result: result)

        case "create":
            create(args: call.arguments, result: result)

        case "initialize":
            withInstance(call.arguments, result: result) { instance in
                self.requestPermissions(audio: instance.audioClaimed) { granted, kind in
                    guard granted else {
                        result(FlutterError(
                            code: "permission_denied",
                            message: kind,
                            details: nil
                        ))
                        return
                    }
                    instance.sessionQueueAsync {
                        instance.initialize()
                        DispatchQueue.main.async { result(nil) }
                    }
                }
            }

        case "dispose":
            withInstance(call.arguments, result: result) { instance in
                // Release the device + audio claim *immediately* on .main
                // so a follow-up `create` for the same camera can succeed
                // even while the slow session teardown
                // (stopRunning / removeInput / removeOutput) is still in
                // flight on the per-instance sessionQueue. Two
                // AVCaptureSessions can briefly coexist against the same
                // device — AVFoundation serializes the underlying hardware
                // access. Without this, a quick page-pop → re-push hits
                // `device_busy` because the old claim hasn't been
                // released yet.
                self.releaseClaim(for: instance)
                self.instances.removeValue(forKey: instance.handle)
                instance.sessionQueueAsync {
                    instance.dispose()
                    DispatchQueue.main.async { result(nil) }
                }
            }

        case "setDescription":
            guard let args = call.arguments as? [String: Any],
                  let cameraId = args["cameraId"] as? String else {
                result(badArgs("setDescription"))
                return
            }
            withInstance(args, result: result) { instance in
                // Contention check against other instances. The instance's
                // current cameraId is held by us in `devicesInUse`; only a
                // foreign holder should block. (A no-op flip — same id —
                // also passes.)
                let oldId = instance.currentCameraId
                if oldId != cameraId, self.devicesInUse.contains(cameraId) {
                    result(FlutterError(
                        code: "device_busy",
                        message: cameraId,
                        details: nil
                    ))
                    return
                }
                // Tentatively claim the new id before the async swap so a
                // concurrent create can't race us. Roll back on failure.
                self.devicesInUse.insert(cameraId)
                instance.sessionQueueAsync {
                    do {
                        let size = try instance.setDescription(cameraId: cameraId)
                        DispatchQueue.main.async {
                            if let oldId, oldId != cameraId {
                                self.devicesInUse.remove(oldId)
                            }
                            result([
                                "previewSize": [
                                    "width": size.width,
                                    "height": size.height,
                                ],
                                "previewRotationQuarterTurns": 0,
                            ])
                        }
                    } catch let error as NSError {
                        DispatchQueue.main.async {
                            if oldId != cameraId {
                                self.devicesInUse.remove(cameraId)
                            }
                            result(FlutterError(
                                code: "init_failed",
                                message: error.localizedDescription,
                                details: nil
                            ))
                        }
                    }
                }
            }

        case "setFlashMode":
            guard let args = call.arguments as? [String: Any],
                  let modeName = args["mode"] as? String else {
                result(badArgs("setFlashMode"))
                return
            }
            withInstance(args, result: result) { instance in
                instance.sessionQueueAsync {
                    instance.setFlashMode(flashMode(from: modeName))
                    DispatchQueue.main.async { result(nil) }
                }
            }

        case "lockCaptureOrientation":
            guard let args = call.arguments as? [String: Any],
                  let raw = args["orientation"] as? String else {
                result(badArgs("lockCaptureOrientation"))
                return
            }
            withInstance(args, result: result) { instance in
                let o = DeviceOrientationFlutter.parse(raw)
                instance.sessionQueueAsync {
                    instance.lockCaptureOrientation(o)
                    DispatchQueue.main.async { result(nil) }
                }
            }

        case "unlockCaptureOrientation":
            withInstance(call.arguments, result: result) { instance in
                instance.sessionQueueAsync {
                    instance.unlockCaptureOrientation()
                    DispatchQueue.main.async { result(nil) }
                }
            }

        case "takePicture":
            guard let args = call.arguments as? [String: Any],
                  let raw = args["snapshotOrientation"] as? String else {
                result(badArgs("takePicture"))
                return
            }
            withInstance(args, result: result) { instance in
                let snapshot = DeviceOrientationFlutter.parse(raw)
                instance.sessionQueueAsync {
                    instance.takePicture(snapshot: snapshot) { outcome in
                        switch outcome {
                        case .success(let path):
                            result(["path": path])
                        case .failure(let error):
                            result(FlutterError(
                                code: "take_picture_failed",
                                message: error.localizedDescription,
                                details: nil
                            ))
                        }
                    }
                }
            }

        case "startVideoRecording":
            guard let args = call.arguments as? [String: Any],
                  let raw = args["snapshotOrientation"] as? String else {
                result(badArgs("startVideoRecording"))
                return
            }
            withInstance(args, result: result) { instance in
                let snapshot = DeviceOrientationFlutter.parse(raw)
                instance.sessionQueueAsync {
                    do {
                        try instance.startVideoRecording(snapshot: snapshot)
                        DispatchQueue.main.async { result(nil) }
                    } catch let error as NSError {
                        DispatchQueue.main.async {
                            result(FlutterError(
                                code: "recorder_failed",
                                message: error.localizedDescription,
                                details: nil
                            ))
                        }
                    }
                }
            }

        case "stopVideoRecording":
            withInstance(call.arguments, result: result) { instance in
                instance.sessionQueueAsync {
                    instance.stopVideoRecording { outcome in
                        // `outcome` arrives on recorderQueue from
                        // VideoRecorder.deliver. Bounce to main for
                        // the FlutterResult.
                        DispatchQueue.main.async {
                            switch outcome {
                            case .success(let url):
                                result(["path": url.path])
                            case .failure(let error):
                                result(FlutterError(
                                    code: "recorder_failed",
                                    message: error.localizedDescription,
                                    details: nil
                                ))
                            }
                        }
                    }
                }
            }

        case "cameraPermissionStatus":
            result(AVCaptureDevice.authorizationStatus(for: .video) == .authorized)

        case "requestCameraPermission":
            requestPermission(for: .video, result: result)

        case "audioPermissionStatus":
            result(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)

        case "requestAudioPermission":
            requestPermission(for: .audio, result: result)

        case "openSettings":
            DispatchQueue.main.async {
                // Per-platform helper: iOS opens app-specific Settings
                // via UIApplication; macOS opens the Camera privacy
                // pane via NSWorkspace. See `CameraSettings+iOS.swift`
                // and `CameraSettings+macOS.swift`.
                CameraSettings.openAppSettings()
                result(nil)
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Method implementations

    private func availableCameras(result: @escaping FlutterResult) {
        let cameras = CaptureDevice.discover().map { $0.toWire() }
        if cameras.isEmpty {
            // Empty discovery has two common causes that look the same
            // to Dart: real permission denial vs a zombie AVCaptureSession
            // somewhere holding the device. Emit a diagnostic with the
            // current plugin claim state so the log_server jsonl shows
            // which side the leak is on if this reproduces.
            eventSink?([
                "handle": -1,
                "event": "diagnostic",
                "message": "availableCameras: empty"
                    + " devicesInUse=\(Array(devicesInUse).sorted())"
                    + " audioInUse=\(audioInUse)"
                    + " instances=\(Array(instances.keys).sorted())",
            ])
        }
        result(cameras)
    }

    private func create(args: Any?, result: @escaping FlutterResult) {
        guard let args = args as? [String: Any],
              let cameraId = args["cameraId"] as? String,
              let enableAudio = args["enableAudio"] as? Bool else {
            result(badArgs("create"))
            return
        }
        guard let registry = textureRegistry else {
            result(FlutterError(
                code: "init_failed",
                message: "Texture registry unavailable",
                details: nil
            ))
            return
        }

        if devicesInUse.contains(cameraId) {
            result(FlutterError(
                code: "device_busy",
                message: cameraId,
                details: nil
            ))
            return
        }
        if enableAudio && audioInUse {
            result(FlutterError(
                code: "audio_busy",
                message: nil,
                details: nil
            ))
            return
        }

        let handle = nextHandle
        nextHandle += 1

        let instance = CameraInstance(handle: handle)
        instance.onEvent = { [weak self] payload in
            self?.eventSink?(payload)
        }
        instances[handle] = instance
        devicesInUse.insert(cameraId)
        if enableAudio { audioInUse = true }

        instance.sessionQueueAsync {
            do {
                try instance.create(
                    cameraId: cameraId,
                    enableAudio: enableAudio,
                    registry: registry
                )
                let size = instance.previewSize
                DispatchQueue.main.async {
                    result([
                        "handle": handle,
                        "textureId": instance.textureId,
                        "previewSize": [
                            "width": size.width,
                            "height": size.height,
                        ],
                        // iOS pre-rotates frames via the data-output
                        // connection's videoOrientation, so the Flutter
                        // Texture displays upright as-is.
                        "previewRotationQuarterTurns": 0,
                    ])
                }
            } catch let error as NSError {
                DispatchQueue.main.async {
                    // Can't rely on `releaseClaim(for: instance)` here —
                    // if `configureSession` threw before `instance.device`
                    // was set, `instance.currentCameraId` is nil and the
                    // claim we inserted on line above would leak. Drop the
                    // ids we know we inserted explicitly.
                    self.devicesInUse.remove(cameraId)
                    if enableAudio { self.audioInUse = false }
                    self.instances.removeValue(forKey: handle)
                    result(FlutterError(
                        code: "init_failed",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            }
        }
    }

    // MARK: - Helpers

    private func withInstance(
        _ args: Any?,
        result: @escaping FlutterResult,
        body: @escaping (CameraInstance) -> Void
    ) {
        guard let map = args as? [String: Any],
              let handle = (map["handle"] as? NSNumber)?.intValue else {
            result(badArgs("missing handle"))
            return
        }
        guard let instance = instances[handle] else {
            result(FlutterError(
                code: "disposed",
                message: "No camera for handle \(handle)",
                details: nil
            ))
            return
        }
        body(instance)
    }

    private func releaseClaim(for instance: CameraInstance) {
        if let id = instance.currentCameraId {
            devicesInUse.remove(id)
        }
        if instance.audioClaimed {
            audioInUse = false
        }
    }

    /// Request camera (always) and microphone (when [audio]) access.
    /// Completion fires on `.main` with `(true, "")` on camera grant.
    /// A denied microphone is **not** a fatal failure — the recording
    /// pipeline tolerates a missing audio output cleanly (no audio
    /// track in the file), and the user is more annoyed by "camera
    /// won't even open" than by "video has no sound." Camera denial
    /// is the only hard failure path here.
    private func requestPermissions(
        audio: Bool,
        _ completion: @escaping (Bool, String) -> Void
    ) {
        requestAccess(for: .video) { videoGranted in
            guard videoGranted else {
                completion(false, "camera")
                return
            }
            guard audio else {
                completion(true, "")
                return
            }
            // Prompt for mic if we haven't asked yet; result doesn't
            // gate initialize either way. CameraInstance.configureSession
            // already tolerates a missing mic (the audio device input
            // throws on `AVCaptureDeviceInput(device:)`, the catch
            // swallows, and audioDeviceInput stays nil — which
            // [CameraInstance.startVideoRecording] reads as "skip
            // adding an audio input to the writer").
            self.requestAccess(for: .audio) { _ in
                completion(true, "")
            }
        }
    }

    private func requestPermission(for mediaType: AVMediaType, result: @escaping FlutterResult) {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            result(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                DispatchQueue.main.async { result(granted) }
            }
        default:
            DispatchQueue.main.async {
                CameraSettings.openAppSettings()
                result(AVCaptureDevice.authorizationStatus(for: mediaType) == .authorized)
            }
        }
    }

    private func requestAccess(
        for mediaType: AVMediaType,
        _ completion: @escaping (Bool) -> Void
    ) {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            DispatchQueue.main.async { completion(true) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            DispatchQueue.main.async { completion(false) }
        }
    }
}

// MARK: - Free functions

private func badArgs(_ where_: String) -> FlutterError {
    return FlutterError(
        code: "bad_args",
        message: "Bad arguments for \(where_)",
        details: nil
    )
}

private func flashMode(from raw: String) -> AVCaptureDevice.FlashMode {
    switch raw {
    case "always": return .on
    case "off": return .off
    default: return .off
    }
}
