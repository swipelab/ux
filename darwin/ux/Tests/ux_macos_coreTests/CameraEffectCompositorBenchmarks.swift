import CoreGraphics
import CoreVideo
import XCTest

@testable import ux_macos_core

/// Reports composite latency and asserts nothing about time, so the suite
/// stays green on any machine.
final class CameraEffectCompositorBenchmarks: XCTestCase {
    private func measureComposites(
        effect: CameraEffect, masked: Bool, label: String
    ) {
        let compositor = CameraEffectCompositor(effect: effect)
        let frames = (0..<4).map { index in
            makeEffectFrame(
                width: 1920, height: 1080,
                format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ) { x, y in UInt8((x + y + index) % 256) }
        }
        let mask =
            masked
            ? makeEffectMask(
                width: 256, height: 192,
                sourceRect: frames[0].crop,
                person: CGRect(x: 64, y: 48, width: 128, height: 96)
            )
            : nil
        var samples: [Double] = []
        samples.reserveCapacity(300)
        for index in 0..<330 {
            let frame = frames[index % frames.count]
            let start = DispatchTime.now().uptimeNanoseconds
            let outcome = compositor.composite(frame: frame, mask: mask)
            let elapsed =
                Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            guard case .composited = outcome else {
                return XCTFail("\(label) failed to composite")
            }
            if index >= 30 { samples.append(elapsed) }
        }
        samples.sort()
        let median = samples[samples.count / 2]
        let p95 = samples[Int(Double(samples.count) * 0.95)]
        print(
            String(
                format: "compositor benchmark %@: median %.3f ms, p95 %.3f ms"
                    + " over %d composites at 1920x1080",
                label, median, p95, samples.count
            )
        )
    }

    func testBlurWithAMaskLatency() {
        measureComposites(effect: .blur, masked: true, label: "blur masked")
    }

    func testBlurWithoutAMaskLatency() {
        measureComposites(effect: .blur, masked: false, label: "blur unmasked")
    }

    func testDimWithAMaskLatency() {
        measureComposites(effect: .dim, masked: true, label: "dim masked")
    }

    func testDimWithoutAMaskLatency() {
        measureComposites(effect: .dim, masked: false, label: "dim unmasked")
    }
}
