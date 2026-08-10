import CoreGraphics
import CoreVideo

/// A single-channel person mask over one camera frame: white is the person,
/// black the background.
public struct CameraMask {
    public init(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        sourceRect: CGRect,
        sourceTimestampNs: Int64
    ) {
        self.pixelBuffer = pixelBuffer
        self.width = width
        self.height = height
        self.sourceRect = sourceRect
        self.sourceTimestampNs = sourceTimestampNs
    }

    public let pixelBuffer: CVPixelBuffer

    /// The mask's own grid, whose aspect does not track the frame's: the
    /// whole buffer stretches onto `sourceRect` with independent x and y
    /// scales.
    public let width: Int
    public let height: Int

    /// The region of the frame's pixel buffer the mask was produced against,
    /// in pixels, top-left origin, pre-rotation. It equals the frame's crop.
    public let sourceRect: CGRect

    /// The timestamp of the frame the mask was inferred from.
    public let sourceTimestampNs: Int64
}

extension CameraMask {
    /// Why the mask cannot apply to a frame cropped to `crop`, or nil when it
    /// applies.
    func rejection(over crop: CGRect) -> CameraMaskRejection? {
        guard width > 0, height > 0 else { return .zeroDimensioned }
        guard sourceRect == crop else { return .sourceRectMismatch }
        guard !isAllZero(pixelBuffer) else { return .empty }
        return nil
    }
}

private func isAllZero(_ buffer: CVPixelBuffer) -> Bool {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return true }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    for row in 0..<height {
        let bytes = (base + row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for column in 0..<width where bytes[column] != 0 { return false }
    }
    return true
}
