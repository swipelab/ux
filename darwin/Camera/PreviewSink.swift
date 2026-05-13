import AVFoundation
import CoreVideo
#if canImport(UIKit)
import Flutter
#else
import FlutterMacOS
#endif

/// Single-slot latest-pixel-buffer sink that feeds a `FlutterTexture`.
///
/// AVCaptureVideoDataOutput's sample-buffer delegate fires on
/// `videoBufferQueue`; we extract the `CVPixelBuffer`, store it as
/// `latestPixelBuffer`, and notify the texture registry on `main` so
/// Flutter pulls the new frame via `copyPixelBuffer()` on the engine
/// thread.
///
/// We retain *only the most recent* buffer — the previous one is
/// released the moment a new sample arrives. This matches the
/// `camera_avfoundation` lifetime invariant and bounds memory at one
/// frame regardless of how fast we produce vs. consume.
final class PreviewSink: NSObject, FlutterTexture {
    private weak var registry: FlutterTextureRegistry?
    private var textureId: Int64 = -1

    /// Serial queue for the `latestPixelBuffer` swap. Sample-buffer
    /// delegate writes; `copyPixelBuffer()` reads. Without this the
    /// pointer could be freed mid-read on a different thread.
    private let bufferQueue = DispatchQueue(
        label: "ux.camera.preview.buffer",
        qos: .userInitiated
    )
    private var latestPixelBuffer: CVPixelBuffer?

    /// Fires once after the first sample buffer arrives, carrying the
    /// buffer's actual `CVPixelBuffer` dimensions. The active-format
    /// dims reported by `device.activeFormat` aren't always what the
    /// data output actually delivers (notably on macOS where the
    /// session preset gets remapped). [CameraInstance] forwards this
    /// to Dart as a `previewSizeChanged` event so the camera_thumb's
    /// SizedBox aspect matches the texture's real aspect.
    var onFirstFrameSize: ((CGSize) -> Void)?
    private var emittedFirstSize = false

    func register(with registry: FlutterTextureRegistry) -> Int64 {
        self.registry = registry
        textureId = registry.register(self)
        return textureId
    }

    func unregister() {
        registry?.unregisterTexture(textureId)
        bufferQueue.sync { latestPixelBuffer = nil }
    }

    // MARK: - FlutterTexture

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        var pb: CVPixelBuffer?
        bufferQueue.sync {
            pb = latestPixelBuffer
            latestPixelBuffer = nil
        }
        if let pb = pb { return Unmanaged.passRetained(pb) }
        return nil
    }

    /// Receives a new frame. Called from the
    /// `AVCaptureVideoDataOutputSampleBufferDelegate` on
    /// `videoBufferQueue`. Cheap — just swaps the pointer + notifies
    /// the registry.
    func receive(sampleBuffer: CMSampleBuffer) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        bufferQueue.sync { latestPixelBuffer = pb }
        if !emittedFirstSize {
            emittedFirstSize = true
            let size = CGSize(
                width: CGFloat(CVPixelBufferGetWidth(pb)),
                height: CGFloat(CVPixelBufferGetHeight(pb))
            )
            onFirstFrameSize?(size)
        }
        if let registry = registry {
            registry.textureFrameAvailable(textureId)
        }
    }
}
