import CoreGraphics
import CoreVideo
import XCTest

@testable import ux_macos_core

/// The measurement rides the frame-publishing thread, so its cost is bounded
/// by the composite it measures rather than by the frame's pixel count.
final class CameraBackgroundMeasurementTests: XCTestCase {
    private static let ceiling = 3.0

    private func median(measures: Bool) -> Double {
        let compositor = CameraEffectCompositor(effect: .blur, measures: measures)
        let frames = (0..<4).map { index in
            makeEffectFrame(
                width: 1920, height: 1080,
                format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ) { x, y in UInt8((x + y + index) % 256) }
        }
        let mask = makeEffectMask(
            width: 256, height: 192,
            sourceRect: frames[0].crop,
            person: CGRect(x: 64, y: 48, width: 128, height: 96)
        )
        var samples: [Double] = []
        for index in 0..<130 {
            let frame = frames[index % frames.count]
            let start = DispatchTime.now().uptimeNanoseconds
            _ = compositor.composite(frame: frame, mask: mask)
            let elapsed =
                Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if index >= 30 { samples.append(elapsed) }
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    func testMeasuringDoesNotDominateTheCompositeItMeasures() {
        let unmeasured = median(measures: false)
        let measured = median(measures: true)

        XCTAssertLessThan(
            measured, unmeasured * Self.ceiling,
            "measuring took \(measured) ms over a \(unmeasured) ms composite"
        )
    }
}
