import CoreGraphics
import Foundation
import ImageIO

@testable import ux_macos_core

enum FakeCaptureError: Error {
    case enumeration
    case notFound
}

actor FakeScreenCapture: ScreenCapturing {
    init(sources: [ScreenSource] = [], enumerationError: Error? = nil) {
        self.sources = sources
        self.enumerationError = enumerationError
    }

    private let sources: [ScreenSource]
    private let enumerationError: Error?

    /// Keys — `"<kind>:<id>"` — whose capture throws ``FakeCaptureError/notFound``.
    var vanished: Set<String> = []

    private(set) var enumerations = 0
    private(set) var requestedSizes: [String: ScreenThumbnailSize] = [:]
    private(set) var peakConcurrency = 0
    private var inFlight = 0

    static func key(_ source: ScreenSource) -> String {
        "\(source.kind.rawValue):\(source.id)"
    }

    func vanish(_ keys: String...) {
        vanished.formUnion(keys)
    }

    func shareableSources() async throws -> [ScreenSource] {
        enumerations += 1
        if let enumerationError { throw enumerationError }
        return sources
    }

    func captureImage(
        of source: ScreenSource,
        width: Int,
        height: Int
    ) async throws -> CGImage {
        inFlight += 1
        peakConcurrency = max(peakConcurrency, inFlight)
        defer { inFlight -= 1 }

        requestedSizes[Self.key(source)] = ScreenThumbnailSize(
            width: width, height: height
        )
        try? await Task.sleep(nanoseconds: 20_000_000)

        if vanished.contains(Self.key(source)) { throw FakeCaptureError.notFound }
        return Self.image(width: width, height: height)
    }

    private static func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}

func pngSize(_ data: Data) -> ScreenThumbnailSize? {
    guard
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    return ScreenThumbnailSize(width: image.width, height: image.height)
}
