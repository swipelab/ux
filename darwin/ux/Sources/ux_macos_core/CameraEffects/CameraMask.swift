import CoreGraphics
import CoreVideo

/// A single-channel person mask over one camera frame: white is the person,
/// black the background.
public struct CameraMask {
    public init(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        sourceRect: CGRect
    ) {
        self.pixelBuffer = pixelBuffer
        self.width = width
        self.height = height
        self.sourceRect = sourceRect
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
}
