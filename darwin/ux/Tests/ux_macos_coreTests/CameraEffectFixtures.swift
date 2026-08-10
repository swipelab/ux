import CoreGraphics
import CoreVideo
import Foundation

@testable import ux_macos_core

/// A frame whose buffer honours the geometry it is given, filled with a
/// per-pixel gray level so composites are byte-decidable.
func makeEffectFrame(
    width: Int,
    height: Int,
    format: OSType = kCVPixelFormatType_32BGRA,
    crop: CGRect? = nil,
    adaptedWidth: Int? = nil,
    adaptedHeight: Int? = nil,
    rotation: CameraFrameRotation = .degrees0,
    timestampNs: Int64 = 0,
    timestamp90kHz: Int32 = 0,
    gray: (Int, Int) -> UInt8 = { _, _ in 128 }
) -> CameraFrame {
    var made: CVPixelBuffer?
    CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, format,
        [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary,
        &made
    )
    let buffer = made!
    CVPixelBufferLockBaseAddress(buffer, [])
    switch format {
    case kCVPixelFormatType_32BGRA:
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = (base + y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let value = gray(x, y)
                row[x * 4] = value
                row[x * 4 + 1] = value
                row[x * 4 + 2] = value
                row[x * 4 + 3] = 255
            }
        }
    default:
        let videoRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        let lumaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<height {
            let row = (lumaBase + y * lumaBytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let value = gray(x, y)
                row[x] =
                    videoRange
                    ? UInt8(16 + Int((Double(value) * 219.0 / 255.0).rounded()))
                    : value
            }
        }
        let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        let chromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<(height / 2) {
            memset(chromaBase + y * chromaBytesPerRow, 128, width)
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let cropRect = crop ?? CGRect(x: 0, y: 0, width: width, height: height)
    return CameraFrame(
        pixelBuffer: buffer,
        crop: cropRect,
        adaptedWidth: adaptedWidth ?? Int(cropRect.width),
        adaptedHeight: adaptedHeight ?? Int(cropRect.height),
        rotation: rotation,
        timestampNs: timestampNs,
        timestamp90kHz: timestamp90kHz
    )
}

/// A single-channel buffer: zero everywhere except `person`, given in the
/// mask's own top-left-origin grid.
func makeMaskBuffer(width: Int, height: Int, person: CGRect? = nil) -> CVPixelBuffer {
    var made: CVPixelBuffer?
    CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_OneComponent8,
        nil, &made
    )
    let buffer = made!
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        memset(base + y * bytesPerRow, 0, width)
    }
    if let person {
        for y in Int(person.minY)..<Int(person.maxY) {
            memset(base + y * bytesPerRow + Int(person.minX), 255, Int(person.width))
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

func makeEffectMask(
    width: Int,
    height: Int,
    sourceRect: CGRect,
    person: CGRect? = nil,
    declaredWidth: Int? = nil,
    declaredHeight: Int? = nil,
    rotation: CameraFrameRotation = .degrees0,
    sourceTimestampNs: Int64 = 0
) -> CameraMask {
    CameraMask(
        pixelBuffer: makeMaskBuffer(width: width, height: height, person: person),
        width: declaredWidth ?? width,
        height: declaredHeight ?? height,
        sourceRect: sourceRect,
        rotation: rotation,
        sourceTimestampNs: sourceTimestampNs
    )
}

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
