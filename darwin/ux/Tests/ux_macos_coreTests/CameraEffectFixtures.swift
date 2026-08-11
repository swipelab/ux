import CoreGraphics
import CoreVideo
import Foundation

@testable import ux_macos_core

/// The blue channel at (x, y) of a BGRA buffer; the fixtures write gray, so
/// one channel is the pixel.
func grayValue(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> Int {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(buffer)!
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    return Int((base + y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self).pointee)
}

func alphaValue(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> Int {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(buffer)!
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    return Int(
        (base + y * bytesPerRow + x * 4 + 3).assumingMemoryBound(to: UInt8.self).pointee
    )
}

/// A pool seam the tests can force to fail; allocation flows through a real
/// bounded pool, whose accounting the tests read.
final class ScriptedPools: CameraEffectBufferPools {
    init(threshold: Int = PixelBufferPool.allocationThreshold) {
        self.threshold = threshold
    }

    private let threshold: Int

    var poolCreationFails = false
    var allocationsFail = false

    private(set) var pools: [ScriptedPool] = []

    func makePool(width: Int, height: Int) -> CameraEffectBufferPool? {
        guard !poolCreationFails else { return nil }
        let pool = ScriptedPool(
            owner: self,
            real: PixelBufferPool(width: width, height: height, threshold: threshold)!
        )
        pools.append(pool)
        return pool
    }
}

final class ScriptedPool: CameraEffectBufferPool {
    init(owner: ScriptedPools, real: PixelBufferPool) {
        self.owner = owner
        self.real = real
    }

    private unowned let owner: ScriptedPools
    private let real: PixelBufferPool

    private(set) var taken = 0
    private(set) var refused = 0
    private(set) var exhausted = 0

    func takeBuffer() -> CVPixelBuffer? {
        if owner.allocationsFail {
            refused += 1
            return nil
        }
        guard let buffer = real.takeBuffer() else {
            exhausted += 1
            return nil
        }
        taken += 1
        return buffer
    }
}
