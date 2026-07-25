import CoreVideo
import Foundation
#if canImport(UIKit)
import Flutter
#else
import FlutterMacOS
#endif

/// Single-slot latest-pixel-buffer sink that feeds a `FlutterTexture`.
/// Mirrors `PreviewSink` in `darwin/Camera/` — receiver writes, the
/// engine reads via `copyPixelBuffer()`. We retain only the most
/// recent buffer; older ones get released the moment a new frame
/// arrives, bounding memory at one frame.
final class UxVideoPixelBufferSink: NSObject, FlutterTexture {
    private weak var registry: FlutterTextureRegistry?
    private var textureId: Int64 = -1

    private let bufferQueue = DispatchQueue(
        label: "ux.video.buffer",
        qos: .userInitiated
    )
    private var latestPixelBuffer: CVPixelBuffer?

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

    /// Receives a new frame from the AVPlayerItemVideoOutput pump.
    /// Cheap — just swaps the pointer + notifies the registry.
    func deliver(pixelBuffer: CVPixelBuffer) {
        bufferQueue.sync { latestPixelBuffer = pixelBuffer }
        if let registry = registry {
            registry.textureFrameAvailable(textureId)
        }
    }
}
