import CoreGraphics
import Foundation
import ImageIO

/// Pixel dimensions of a thumbnail.
public struct ScreenThumbnailSize: Equatable, Sendable {
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public let width: Int
    public let height: Int
}

/// Renders one source into a PNG that fits given bounds.
public struct ScreenThumbnailRenderer {
    public init(capture: ScreenCapturing) {
        self.capture = capture
    }

    private let capture: ScreenCapturing

    /// The PNG for `source`, or `nil` when this source alone fails to capture
    /// or encode.
    public func render(
        _ source: ScreenSource,
        into bounds: ScreenThumbnailSize
    ) async -> Data? {
        let size = Self.aspectFit(
            source: ScreenThumbnailSize(width: source.width, height: source.height),
            into: bounds
        )
        guard
            let image = try? await capture.captureImage(
                of: source,
                width: size.width,
                height: size.height
            )
        else { return nil }
        return Self.png(from: image)
    }

    /// The largest `source`-proportioned size that fits `bounds`, at least
    /// 1 × 1. A source without positive dimensions fills `bounds`.
    static func aspectFit(
        source: ScreenThumbnailSize,
        into bounds: ScreenThumbnailSize
    ) -> ScreenThumbnailSize {
        let boundsWidth = max(1, bounds.width)
        let boundsHeight = max(1, bounds.height)
        guard source.width > 0, source.height > 0 else {
            return ScreenThumbnailSize(width: boundsWidth, height: boundsHeight)
        }
        let scale = min(
            Double(boundsWidth) / Double(source.width),
            Double(boundsHeight) / Double(source.height)
        )
        return ScreenThumbnailSize(
            width: max(1, Int((Double(source.width) * scale).rounded())),
            height: max(1, Int((Double(source.height) * scale).rounded()))
        )
    }

    static func png(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, "public.png" as CFString, 1, nil
            )
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
