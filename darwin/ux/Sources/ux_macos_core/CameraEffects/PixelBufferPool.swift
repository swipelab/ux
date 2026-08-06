import CoreVideo
import Foundation

/// Vends the compositor's output buffers: fixed-geometry BGRA under a fixed
/// allocation bound.
public protocol CameraEffectBufferPool: AnyObject {
    /// `nil` once the bound is reached or allocation fails.
    func takeBuffer() -> CVPixelBuffer?
}

public protocol CameraEffectBufferPools: AnyObject {
    func makePool(width: Int, height: Int) -> CameraEffectBufferPool?
}

public final class PixelBufferPool: CameraEffectBufferPool {
    /// One last-good slot plus the frames in flight downstream.
    public static let allocationThreshold = 8

    init?(width: Int, height: Int, threshold: Int) {
        // IOSurface backing and Metal compatibility let Core Image bind the
        // buffer as a Metal texture; without them every render round-trips
        // through CPU memory.
        let bufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var made: CVPixelBufferPool?
        let result = CVPixelBufferPoolCreate(
            kCFAllocatorDefault, nil, bufferAttributes as CFDictionary, &made
        )
        guard result == kCVReturnSuccess, let made else { return nil }
        pool = made
        // The threshold binds only through the per-allocation aux argument;
        // as a creation attribute it does nothing.
        auxAttributes =
            [kCVPixelBufferPoolAllocationThresholdKey: threshold] as CFDictionary
    }

    private let pool: CVPixelBufferPool
    private let auxAttributes: CFDictionary

    public func takeBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, auxAttributes, &buffer
        )
        guard result == kCVReturnSuccess else { return nil }
        return buffer
    }
}

public final class PixelBufferPools: CameraEffectBufferPools {
    public init(threshold: Int = PixelBufferPool.allocationThreshold) {
        self.threshold = threshold
    }

    private let threshold: Int

    public func makePool(width: Int, height: Int) -> CameraEffectBufferPool? {
        PixelBufferPool(width: width, height: height, threshold: threshold)
    }
}
