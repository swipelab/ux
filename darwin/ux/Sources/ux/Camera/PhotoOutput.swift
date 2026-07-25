import AVFoundation
import Foundation
import ImageIO

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

    /// Forward post-capture diagnostics (encoded JPEG dimensions +
    /// EXIF Orientation) through `CameraInstance.emit` so they land
    /// in `banlu.jsonl`. macOS-only debug aid for "photo is rotated
    /// 90° CW" cases — Apple's docs say
    /// `AVCapturePhotoOutput`'s connection rotation only affects EXIF
    /// tags, not pixel data, but observation contradicts that. Logging
    /// the actual file metadata helps tell which side is rotated.
    var onCapturedDiagnostic: ((String) -> Void)?

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
        // Rotation handled per-platform: iOS applies the snapshot
        // orientation to the connection (which rotates the captured
        // JPEG); macOS is a no-op (desktop cams are physically
        // landscape, any rotation skews the photo). See
        // `AVCaptureConnection+iOS.swift` / `…+macOS.swift`.
        connection.applyXCaptureOrientation(orientation)
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

        let delegate = PhotoCaptureDelegate(
            diag: { [weak self] message in
                self?.onCapturedDiagnostic?(message)
            }
        ) { [weak self] result in
            // Reset orientation back to portraitUp on the photo
            // connection so a follow-up shot without an explicit
            // snapshot defaults cleanly. No-op on macOS (the
            // extension method is empty there).
            self?.avOutput.connection(with: .video)?
                .applyXCaptureOrientation(.portraitUp)
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
    private let diag: (String) -> Void
    private let completion: (Result<String, NSError>) -> Void

    init(
        diag: @escaping (String) -> Void,
        completion: @escaping (Result<String, NSError>) -> Void
    ) {
        self.diag = diag
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error = error as NSError? {
            diag("photo capture failed: domain=\(error.domain)"
                 + " code=\(error.code) desc=\(error.localizedDescription)")
            completion(.failure(error))
            return
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ux_camera_\(UUID().uuidString).jpg")

        #if os(macOS)
        // Bypass `fileDataRepresentation()` on macOS — it writes EXIF
        // orientation tags whose semantics differ from iOS and that
        // we can't reliably override (none of the
        // `fileDataRepresentationWith…` variants are available on
        // macOS). Instead grab the raw CGImage — per Apple's docs,
        // "the physical rotation of the CGImageRef matches that of
        // the main image. Exif orientation has not been applied." —
        // and re-encode via ImageIO with no orientation tag at all.
        // The resulting JPEG carries sensor-native pixel data and
        // viewers ignore (absent) EXIF, displaying landscape.
        guard let cgImage = photo.cgImageRepresentation() else {
            completion(.failure(NSError(
                domain: "ux.camera",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "No CGImage data"]
            )))
            return
        }
        diag("photo: \(cgImage.width)x\(cgImage.height) " +
             "(cgImageRepresentation, no EXIF)")
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.jpeg" as CFString,
            1,
            nil
        )
        guard let dest = destination else {
            completion(.failure(NSError(
                domain: "ux.camera",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey:
                    "Failed to create JPEG destination"]
            )))
            return
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ]
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        if CGImageDestinationFinalize(dest) {
            completion(.success(url.path))
        } else {
            completion(.failure(NSError(
                domain: "ux.camera",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey:
                    "Failed to finalize JPEG"]
            )))
        }
        #else
        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(NSError(
                domain: "ux.camera",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "No photo data"]
            )))
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            completion(.success(url.path))
        } catch let error as NSError {
            completion(.failure(error))
        }
        #endif
    }
}
