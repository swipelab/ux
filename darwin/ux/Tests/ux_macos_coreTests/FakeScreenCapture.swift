import CoreGraphics
import Foundation
import ImageIO

@testable import ux_macos_core

enum FakeCaptureError: Error {
    case enumeration
    case notFound
}

actor FakeScreenCapture: ScreenCapturing {
    init(
        sources: [ScreenSource] = [],
        enumerationError: Error? = nil,
        concurrencyGate: Int? = nil
    ) {
        self.sources = sources
        self.enumerationError = enumerationError
        self.concurrencyGate = concurrencyGate
    }

    private let sources: [ScreenSource]
    private let enumerationError: Error?
    private let concurrencyGate: Int?

    /// Keys — `"<kind>:<id>"` — whose capture throws ``FakeCaptureError/notFound``.
    var vanished: Set<String> = []

    private(set) var enumerations = 0
    private(set) var requestedSizes: [String: ScreenThumbnailSize] = [:]
    private(set) var peakConcurrency = 0
    private(set) var gateFilled = false
    private var inFlight = 0
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var gateWatchdog: Task<Void, Never>?
    private var gateOpen = false

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
        await passGate()

        if vanished.contains(Self.key(source)) { throw FakeCaptureError.notFound }
        return Self.image(width: width, height: height)
    }

    /// Holds every capture until `concurrencyGate` of them are in flight, so a
    /// peak-concurrency assertion needs no timing assumption. The watchdog
    /// releases a gate that cannot fill: a serializing loader fails the
    /// assertion instead of hanging the suite.
    private func passGate() async {
        guard let concurrencyGate, !gateOpen else { return }
        if inFlight >= concurrencyGate {
            gateFilled = true
            return openGate()
        }
        if gateWatchdog == nil {
            gateWatchdog = Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self.openGate()
            }
        }
        await withCheckedContinuation { gateWaiters.append($0) }
    }

    private func openGate() {
        gateOpen = true
        gateWatchdog?.cancel()
        gateWatchdog = nil
        for waiter in gateWaiters { waiter.resume() }
        gateWaiters = []
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
