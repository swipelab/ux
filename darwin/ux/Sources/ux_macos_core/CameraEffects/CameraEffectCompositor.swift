import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import os

/// Why a mask was set aside and the whole frame took the effect.
public enum CameraMaskRejection: String, Equatable, Sendable {
    case empty
    case zeroDimensioned
    case sourceRectMismatch
}

/// Why a composite answered with a substitute instead of a rendered frame.
public enum CameraCompositeSubstitution: String, Equatable, Sendable {
    case malformedFrame
    case poolUnavailable
    case renderFailed
}

/// What one composite produced.
public enum CompositeOutcome {
    /// A rendered frame; a set-aside mask records why the whole frame took
    /// the effect.
    case composited(
        CameraFrame,
        background: CameraBackgroundGrid?,
        maskRejection: CameraMaskRejection?
    )

    /// A fail-closed substitute — the last-good effected frame or black,
    /// never the input.
    case substituted(CameraFrame, reason: CameraCompositeSubstitution)

    public var frame: CameraFrame {
        switch self {
        case .composited(let frame, _, _): return frame
        case .substituted(let frame, _): return frame
        }
    }

    public var background: CameraBackgroundGrid? {
        switch self {
        case .composited(_, let background, _): return background
        case .substituted: return nil
        }
    }
}

/// One Core Image graph per effect: reads the input through its crop, scales
/// to the adapted size, and never lets a raw frame out.
public final class CameraEffectCompositor {
    public static let blurRadius = 18.0
    public static let dimFactor = 0.5

    public init(
        effect: CameraEffect,
        pools: CameraEffectBufferPools = PixelBufferPools(),
        measures: Bool = false
    ) {
        self.effect = effect
        self.pools = pools
        self.measures = measures
        // Color management off: under the managed default the working space
        // is extended-linear sRGB and the declared factors are not the bytes
        // that land.
        context = CIContext(
            mtlDevice: MTLCreateSystemDefaultDevice()!,
            options: [
                .workingColorSpace: NSNull(),
                .cacheIntermediates: true,
            ]
        )
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    private let effect: CameraEffect
    private let pools: CameraEffectBufferPools

    /// Whether a composite reads back the background weight it applied. The
    /// measurement is a render of its own, outside the published frame's path.
    private let measures: Bool

    private let context: CIContext
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    private struct Geometry: Equatable {
        let width: Int
        let height: Int
    }

    private var geometry: Geometry?
    private var pool: CameraEffectBufferPool?
    private var lastGood: CVPixelBuffer?
    private var black: CVPixelBuffer?
    private var measurement: CVPixelBuffer?

    public func composite(frame: CameraFrame, mask: CameraMask?) -> CompositeOutcome {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        guard isWellFormed(frame) else {
            return substitution(for: frame, reason: .malformedFrame)
        }
        let incoming = Geometry(width: frame.adaptedWidth, height: frame.adaptedHeight)
        if geometry != incoming {
            geometry = incoming
            pool = pools.makePool(width: incoming.width, height: incoming.height)
            lastGood = nil
            black = Self.makeBlackBuffer(width: incoming.width, height: incoming.height)
            measurement =
                measures
                ? Self.makeBuffer(width: incoming.width, height: incoming.height)
                : nil
        }
        guard let pool, let output = pool.takeBuffer() else {
            return substitution(for: frame, reason: .poolUnavailable)
        }
        let assessed = assess(mask, against: frame.crop)
        let image = graph(for: frame, mask: assessed.selection)
        do {
            let destination = CIRenderDestination(pixelBuffer: output)
            destination.colorSpace = nil
            let task = try context.startTask(
                toRender: image,
                from: CGRect(
                    x: 0, y: 0,
                    width: frame.adaptedWidth, height: frame.adaptedHeight
                ),
                to: destination,
                at: .zero
            )
            try task.waitUntilCompleted()
        } catch {
            return substitution(for: frame, reason: .renderFailed)
        }
        lastGood = output
        return .composited(
            published(output, from: frame),
            background: measured(assessed.selection, for: frame),
            maskRejection: assessed.rejection
        )
    }

    private static let takenFormats: Set<OSType> = [
        kCVPixelFormatType_32BGRA,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    ]

    private func isWellFormed(_ frame: CameraFrame) -> Bool {
        guard
            Self.takenFormats.contains(
                CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
            ),
            frame.adaptedWidth > 0, frame.adaptedHeight > 0,
            frame.crop.width > 0, frame.crop.height > 0
        else { return false }
        let bounds = CGRect(
            x: 0, y: 0,
            width: CVPixelBufferGetWidth(frame.pixelBuffer),
            height: CVPixelBufferGetHeight(frame.pixelBuffer)
        )
        return bounds.contains(frame.crop)
    }

    /// The mask as the graph applies it: its own image and the turn that puts
    /// it back over the frame's buffer.
    private struct Selection {
        let image: CIImage
        let rotation: CameraFrameRotation
    }

    private func assess(
        _ mask: CameraMask?, against crop: CGRect
    ) -> (selection: Selection?, rejection: CameraMaskRejection?) {
        guard let mask else { return (nil, nil) }
        if let rejection = mask.rejection(over: crop) { return (nil, rejection) }
        return (
            Selection(
                image: CIImage(cvPixelBuffer: mask.pixelBuffer),
                rotation: mask.rotation
            ),
            nil
        )
    }

    private func graph(for frame: CameraFrame, mask: Selection?) -> CIImage {
        let input = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let cropRect = cropRect(of: frame)
        let person = input.cropped(to: cropRect)
        let background = background(of: person, in: cropRect)
        let composed: CIImage
        if let mask {
            composed = blended(
                person, over: background, mask: stretched(mask, onto: cropRect)
            ).cropped(to: cropRect)
        } else {
            composed = background
        }
        return adapted(composed, from: cropRect, to: frame)
    }

    /// The crop in Core Image's bottom-left-origin space; it arrives in the
    /// buffer's top-left-origin space.
    private func cropRect(of frame: CameraFrame) -> CGRect {
        CGRect(
            x: frame.crop.minX,
            y: CGFloat(CVPixelBufferGetHeight(frame.pixelBuffer)) - frame.crop.maxY,
            width: frame.crop.width,
            height: frame.crop.height
        )
    }

    private func stretched(_ mask: Selection, onto cropRect: CGRect) -> CIImage {
        let unturned = mask.image.transformed(by: mask.rotation.unturning)
        let extent = unturned.extent
        return
            unturned
            .transformed(
                by: CGAffineTransform(
                    translationX: -extent.minX, y: -extent.minY
                )
            )
            .transformed(
                by: CGAffineTransform(
                    scaleX: cropRect.width / extent.width,
                    y: cropRect.height / extent.height
                )
            )
            .transformed(
                by: CGAffineTransform(
                    translationX: cropRect.minX, y: cropRect.minY
                )
            )
    }

    private func adapted(
        _ image: CIImage, from cropRect: CGRect, to frame: CameraFrame
    ) -> CIImage {
        image
            .transformed(
                by: CGAffineTransform(
                    translationX: -cropRect.minX, y: -cropRect.minY
                )
            )
            .transformed(
                by: CGAffineTransform(
                    scaleX: CGFloat(frame.adaptedWidth) / cropRect.width,
                    y: CGFloat(frame.adaptedHeight) / cropRect.height
                )
            )
    }

    /// The share of each cell the effect covers, read back from the composite's
    /// own blend run over white on black, so the grid carries the alpha the
    /// published frame took. A composite no mask reached covers every cell
    /// whole.
    private func measured(
        _ mask: Selection?, for frame: CameraFrame
    ) -> CameraBackgroundGrid? {
        guard measures else { return nil }
        guard let mask else { return CameraBackgroundGrid(repeating: 1) }
        guard let measurement else { return nil }
        let cropRect = cropRect(of: frame)
        let alpha = adapted(
            blended(
                CIImage(color: .white),
                over: CIImage(color: .black),
                mask: stretched(mask, onto: cropRect)
            ).cropped(to: cropRect),
            from: cropRect,
            to: frame
        )
        do {
            let destination = CIRenderDestination(pixelBuffer: measurement)
            destination.colorSpace = nil
            let task = try context.startTask(
                toRender: alpha,
                from: CGRect(
                    x: 0, y: 0,
                    width: frame.adaptedWidth, height: frame.adaptedHeight
                ),
                to: destination,
                at: .zero
            )
            try task.waitUntilCompleted()
        } catch {
            return nil
        }
        return Self.grid(
            over: measurement, width: frame.adaptedWidth, height: frame.adaptedHeight
        )
    }

    private static func grid(
        over buffer: CVPixelBuffer, width: Int, height: Int
    ) -> CameraBackgroundGrid? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let size = CameraBackgroundGrid.size
        var fractions = [Float](repeating: 0, count: CameraBackgroundGrid.cells)
        for row in 0..<size {
            let top = CameraBackgroundGrid.edge(row, over: height)
            let bottom = CameraBackgroundGrid.edge(row + 1, over: height)
            for column in 0..<size {
                let left = CameraBackgroundGrid.edge(column, over: width)
                let right = CameraBackgroundGrid.edge(column + 1, over: width)
                var sum = 0
                var pixels = 0
                for y in top..<bottom {
                    let scan = (base + y * bytesPerRow)
                        .assumingMemoryBound(to: UInt8.self)
                    for x in left..<right {
                        sum += 255 - Int(scan[x * 4])
                        pixels += 1
                    }
                }
                if pixels > 0 {
                    fractions[row * size + column] = Float(sum) / Float(pixels * 255)
                }
            }
        }
        return CameraBackgroundGrid(fractions)
    }

    private func background(of image: CIImage, in rect: CGRect) -> CIImage {
        switch effect {
        case .none:
            return image
        case .blur:
            // CIGaussianBlur samples transparent black outside a finite
            // extent; unclamped it vignettes every frame edge.
            let blur = CIFilter(name: "CIGaussianBlur")!
            blur.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
            blur.setValue(Self.blurRadius, forKey: kCIInputRadiusKey)
            return blur.outputImage!.cropped(to: rect)
        case .dim:
            let factor = CGFloat(Self.dimFactor)
            let dim = CIFilter(name: "CIColorMatrix")!
            dim.setValue(image, forKey: kCIInputImageKey)
            dim.setValue(CIVector(x: factor, y: 0, z: 0, w: 0), forKey: "inputRVector")
            dim.setValue(CIVector(x: 0, y: factor, z: 0, w: 0), forKey: "inputGVector")
            dim.setValue(CIVector(x: 0, y: 0, z: factor, w: 0), forKey: "inputBVector")
            dim.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            dim.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
            return dim.outputImage!.cropped(to: rect)
        }
    }

    private func blended(
        _ person: CIImage, over background: CIImage, mask: CIImage
    ) -> CIImage {
        let blend = CIFilter(name: "CIBlendWithMask")!
        blend.setValue(person, forKey: kCIInputImageKey)
        blend.setValue(background, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        return blend.outputImage!
    }

    private func substitution(
        for frame: CameraFrame, reason: CameraCompositeSubstitution
    ) -> CompositeOutcome {
        if let lastGood {
            return .substituted(published(lastGood, from: frame), reason: reason)
        }
        let substitute: CVPixelBuffer
        if let black {
            substitute = black
        } else {
            let made = Self.makeBlackBuffer(
                width: max(1, frame.adaptedWidth),
                height: max(1, frame.adaptedHeight)
            )
            black = made
            substitute = made
        }
        return .substituted(published(substitute, from: frame), reason: reason)
    }

    private func published(
        _ buffer: CVPixelBuffer, from frame: CameraFrame
    ) -> CameraFrame {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        return CameraFrame(
            pixelBuffer: buffer,
            crop: CGRect(x: 0, y: 0, width: width, height: height),
            adaptedWidth: width,
            adaptedHeight: height,
            rotation: frame.rotation,
            timestampNs: frame.timestampNs,
            timestamp90kHz: frame.timestamp90kHz
        )
    }

    private static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var made: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &made
        )
        guard result == kCVReturnSuccess else { return nil }
        return made
    }

    /// Allocated outside the bounded pool, so a pool failure can always be
    /// answered.
    private static func makeBlackBuffer(width: Int, height: Int) -> CVPixelBuffer {
        guard let buffer = makeBuffer(width: width, height: height) else {
            preconditionFailure("black substitute allocation failed")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            for row in 0..<height {
                let pixels = (base + row * bytesPerRow)
                    .assumingMemoryBound(to: UInt32.self)
                // Opaque black in BGRA memory order.
                for column in 0..<width { pixels[column] = 0xFF00_0000 }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
