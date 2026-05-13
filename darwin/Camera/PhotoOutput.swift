import AVFoundation
import Foundation

/// Wraps `AVCapturePhotoOutput`. One instance per
/// [CameraInstance]; gets added to the session at create time and
/// stays for the session's lifetime (no swap on camera flip — the
/// output is generic, only the connection's video device changes).
///
/// `take(orientation:flashMode:completion:)` is the only public entry.
/// It sets the photo connection's `videoOrientation` to the
/// snapshotted orientation just before firing, hands off to a
/// per-capture delegate, and resets the connection back to portrait
/// afterward (so a takePicture without an explicit snapshot — should
/// the path ever exist — falls back cleanly).
final class PhotoOutput {
    let avOutput = AVCapturePhotoOutput()

    private var inFlight: PhotoCaptureDelegate?

    /// Capture a single still. [orientation] applies to the photo
    /// connection. [flashMode] is applied to the per-shot
    /// `AVCapturePhotoSettings`. [completion] is invoked on `.main`
    /// with either the saved file path or an `NSError`.
    func take(
        orientation: DeviceOrientationFlutter,
        flashMode: AVCaptureDevice.FlashMode,
        completion: @escaping (Result<String, NSError>) -> Void
    ) {
        guard let connection = avOutput.connection(with: .video) else {
            completion(.failure(NSError(
                domain: "ux.camera",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Photo connection unavailable"]
            )))
            return
        }
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation.avVideoOrientation
        }
        // The recorded photo carries no mirror; mirroring is a
        // preview-only concern.
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }

        let settings = AVCapturePhotoSettings()
        // `supportedFlashModes` arrived in macOS 11; `flashMode` setter
        // in macOS 13. iOS has both since iOS 10. Gated via Swift
        // availability so we don't have to bump the macOS deployment
        // target just to use a flash that almost no Mac has anyway.
        if #available(macOS 11.0, *),
           avOutput.supportedFlashModes.contains(flashMode) {
            if #available(macOS 13.0, *) {
                settings.flashMode = flashMode
            }
        }

        let delegate = PhotoCaptureDelegate { [weak self] result in
            // Reset orientation on the photo connection so a future
            // capture without a snapshot defaults to portrait.
            if let conn = self?.avOutput.connection(with: .video),
               conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
            self?.inFlight = nil
            DispatchQueue.main.async { completion(result) }
        }
        // Retain the delegate for the duration of the capture —
        // AVCapturePhotoOutput holds it weakly.
        inFlight = delegate
        avOutput.capturePhoto(with: settings, delegate: delegate)
    }
}

/// Per-shot delegate. Receives the photo, writes
/// `fileDataRepresentation()` to a unique path under
/// `NSTemporaryDirectory()`, invokes the completion. The plugin
/// retains it via [PhotoOutput.inFlight] across the async hop.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<String, NSError>) -> Void

    init(completion: @escaping (Result<String, NSError>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error = error as NSError? {
            completion(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(NSError(
                domain: "ux.camera",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "No photo data"]
            )))
            return
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ux_camera_\(UUID().uuidString).jpg")
        do {
            try data.write(to: url, options: .atomic)
            completion(.success(url.path))
        } catch let error as NSError {
            completion(.failure(error))
        }
    }
}
