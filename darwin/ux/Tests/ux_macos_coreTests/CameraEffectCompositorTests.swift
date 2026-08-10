import CoreGraphics
import CoreVideo
import XCTest

@testable import ux_macos_core

/// Pixel assertions are regional, not byte-exact: blur bleeds at region
/// edges and the render is float compute.
private let tolerance = 4

final class CameraEffectCompositorTests: XCTestCase {
    private func assertGray(
        _ buffer: CVPixelBuffer, _ x: Int, _ y: Int, _ expected: Int,
        within: Int = tolerance,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let value = grayValue(buffer, x, y)
        XCTAssertTrue(
            abs(value - expected) <= within,
            "(\(x),\(y)) = \(value), expected \(expected) ± \(within)",
            file: file, line: line
        )
    }

    /// Background 220 everywhere, person 40 in a region off both centres.
    private func personFrame() -> CameraFrame {
        makeEffectFrame(width: 320, height: 180) { x, y in
            (60..<160).contains(x) && (40..<120).contains(y) ? 40 : 220
        }
    }

    private func personMask(for frame: CameraFrame) -> CameraMask {
        makeEffectMask(
            width: 320, height: 180,
            sourceRect: frame.crop,
            person: CGRect(x: 60, y: 40, width: 100, height: 80)
        )
    }

    func testABlurCompositeKeepsThePersonAndChangesTheBackground() {
        let compositor = CameraEffectCompositor(effect: .blur)
        let frame = personFrame()

        let outcome = compositor.composite(frame: frame, mask: personMask(for: frame))

        guard case .composited(let output, _, let rejection) = outcome else {
            return XCTFail("expected a composited frame")
        }
        XCTAssertNil(rejection)
        assertGray(output.pixelBuffer, 110, 50, 40)
        assertGray(output.pixelBuffer, 300, 20, 220)
        let nearEdge = grayValue(output.pixelBuffer, 170, 80)
        XCTAssertTrue(
            nearEdge > 70 && nearEdge < 200,
            "background beside the person should mix, got \(nearEdge)"
        )
    }

    func testADimCompositeDarkensTheBackgroundByTheDeclaredFactor() {
        let compositor = CameraEffectCompositor(effect: .dim)
        let frame = personFrame()

        let outcome = compositor.composite(frame: frame, mask: personMask(for: frame))

        guard case .composited(let output, _, let rejection) = outcome else {
            return XCTFail("expected a composited frame")
        }
        XCTAssertNil(rejection)
        assertGray(output.pixelBuffer, 110, 50, 40)
        assertGray(output.pixelBuffer, 300, 20, 110)
        assertGray(output.pixelBuffer, 170, 80, 110)
    }

    func testWithoutAMaskBlurCoversTheWholeFrame() {
        let compositor = CameraEffectCompositor(effect: .blur)
        let frame = makeEffectFrame(width: 320, height: 180) { x, _ in
            x < 160 ? 60 : 200
        }

        let outcome = compositor.composite(frame: frame, mask: nil)

        guard case .composited(let output, _, let rejection) = outcome else {
            return XCTFail("expected a composited frame")
        }
        XCTAssertNil(rejection)
        assertGray(output.pixelBuffer, 20, 90, 60)
        assertGray(output.pixelBuffer, 300, 90, 200)
        let boundary = grayValue(output.pixelBuffer, 160, 90)
        XCTAssertTrue(
            boundary > 90 && boundary < 170,
            "the step should smear across its boundary, got \(boundary)"
        )
    }

    func testWithoutAMaskDimCoversTheWholeFrame() {
        let compositor = CameraEffectCompositor(effect: .dim)
        let frame = makeEffectFrame(width: 320, height: 180) { _, _ in 200 }

        let outcome = compositor.composite(frame: frame, mask: nil)

        guard case .composited(let output, _, _) = outcome else {
            return XCTFail("expected a composited frame")
        }
        assertGray(output.pixelBuffer, 160, 90, 100)
        assertGray(output.pixelBuffer, 2, 2, 100)
        assertGray(output.pixelBuffer, 317, 177, 100)
    }

    func testAUniformFrameBlursToItsOwnValueOutToTheCorners() {
        let compositor = CameraEffectCompositor(effect: .blur)
        let frame = makeEffectFrame(width: 320, height: 180) { _, _ in 255 }

        let outcome = compositor.composite(frame: frame, mask: nil)

        guard case .composited(let output, _, _) = outcome else {
            return XCTFail("expected a composited frame")
        }
        assertGray(output.pixelBuffer, 160, 90, 255)
        assertGray(output.pixelBuffer, 0, 0, 255)
        assertGray(output.pixelBuffer, 319, 0, 255)
        assertGray(output.pixelBuffer, 0, 179, 255)
        assertGray(output.pixelBuffer, 319, 179, 255)
    }

    func testAVisionGridMaskStretchesOntoTheCropWithoutFitOrFlip() {
        let compositor = CameraEffectCompositor(effect: .dim)
        let frame = makeEffectFrame(width: 1920, height: 1080) { x, y in
            (1155..<1537).contains(x) && (596..<866).contains(y) ? 200 : 100
        }
        let mask = makeEffectMask(
            width: 256, height: 192,
            sourceRect: frame.crop,
            person: CGRect(x: 154, y: 106, width: 51, height: 48)
        )

        let outcome = compositor.composite(frame: frame, mask: mask)

        guard case .composited(let output, _, let rejection) = outcome else {
            return XCTFail("expected a composited frame")
        }
        XCTAssertNil(rejection)
        assertGray(output.pixelBuffer, 1346, 731, 200)
        assertGray(output.pixelBuffer, 1500, 731, 200)
        assertGray(output.pixelBuffer, 1346, 920, 50)
        assertGray(output.pixelBuffer, 1346, 349, 50)
        assertGray(output.pixelBuffer, 100, 100, 50)
    }

    func testAnAllZeroMaskRecordsItsRejectionAndTheWholeFrameTakesTheEffect() {
        let compositor = CameraEffectCompositor(effect: .dim)
        let frame = makeEffectFrame(width: 64, height: 36) { _, _ in 200 }
        let mask = makeEffectMask(width: 32, height: 24, sourceRect: frame.crop)

        let outcome = compositor.composite(frame: frame, mask: mask)

        guard case .composited(let output, _, let rejection) = outcome else {
            return XCTFail("expected a composited frame")
        }
        XCTAssertEqual(rejection, .empty)
        assertGray(output.pixelBuffer, 32, 18, 100)
    }

    func testAZeroDimensionedMaskRecordsItsRejectionAndTheWholeFrameTakesTheEffect() {
        let compositor = CameraEffectCompositor(effect: .dim)
        let frame = makeEffectFrame(width: 64, height: 36) { _, _ in 200 }
        let mask = makeEffectMask(
            width: 32, height: 24,
            sourceRect: frame.crop,
            person: CGRect(x: 8, y: 6, width: 16, height: 12),
            declaredWidth: 0,
            declaredHeight: 0
        )

        let outcome = compositor.composite(frame: frame, mask: mask)

        guard case .composited(let output, _, let rejection) = outcome else {
            return XCTFail("expected a composited frame")
        }
        XCTAssertEqual(rejection, .zeroDimensioned)
        assertGray(output.pixelBuffer, 32, 18, 100)
    }

    func testAMaskOffTheCropRecordsItsRejectionAndTheWholeFrameTakesTheEffect() {
        let compositor = CameraEffectCompositor(effect: .dim)
        let frame = makeEffectFrame(width: 64, height: 36) { _, _ in 200 }
        let mask = makeEffectMask(
            width: 32, height: 24,
            sourceRect: frame.crop.offsetBy(dx: 10, dy: 0),
            person: CGRect(x: 8, y: 6, width: 16, height: 12)
        )

        let outcome = compositor.composite(frame: frame, mask: mask)

        guard case .composited(let output, _, let rejection) = outcome else {
            return XCTFail("expected a composited frame")
        }
        XCTAssertEqual(rejection, .sourceRectMismatch)
        assertGray(output.pixelBuffer, 32, 18, 100)
        assertGray(output.pixelBuffer, 20, 12, 100)
    }

    func testACroppedRotatedInputPublishesAtTheAdaptedSizeWithItsMetadataIntact() {
        let compositor = CameraEffectCompositor(effect: .dim)
        let frame = makeEffectFrame(
            width: 640, height: 480,
            crop: CGRect(x: 100, y: 60, width: 320, height: 240),
            adaptedWidth: 640,
            adaptedHeight: 480,
            rotation: .degrees90,
            timestampNs: 123_456_789,
            timestamp90kHz: 4242
        ) { x, y in
            (100..<180).contains(x) && (60..<120).contains(y) ? 240 : 80
        }

        let outcome = compositor.composite(frame: frame, mask: nil)

        guard case .composited(let output, _, _) = outcome else {
            return XCTFail("expected a composited frame")
        }
        XCTAssertEqual(output.crop, CGRect(x: 0, y: 0, width: 640, height: 480))
        XCTAssertEqual(output.adaptedWidth, 640)
        XCTAssertEqual(output.adaptedHeight, 480)
        XCTAssertEqual(output.rotation, .degrees90)
        XCTAssertEqual(output.timestampNs, 123_456_789)
        XCTAssertEqual(output.timestamp90kHz, 4242)
        assertGray(output.pixelBuffer, 80, 60, 120)
        assertGray(output.pixelBuffer, 400, 60, 40)
        assertGray(output.pixelBuffer, 80, 400, 40)
    }

    func testEveryInputFormatComposites() {
        let formats: [OSType] = [
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        for format in formats {
            let compositor = CameraEffectCompositor(effect: .dim)
            let frame = makeEffectFrame(width: 64, height: 36, format: format) {
                _, _ in 255
            }

            let outcome = compositor.composite(frame: frame, mask: nil)

            guard case .composited(let output, _, _) = outcome else {
                return XCTFail("expected a composited frame for format \(format)")
            }
            let value = grayValue(output.pixelBuffer, 32, 18)
            XCTAssertTrue(
                abs(value - 127) <= 3,
                "format \(format) dimmed white to \(value)"
            )
        }
    }

    func testAPoolFailureAnswersWithTheLastGoodFrameRetagged() {
        let pools = ScriptedPools()
        let compositor = CameraEffectCompositor(effect: .dim, pools: pools)
        let good = makeEffectFrame(width: 64, height: 36, timestampNs: 1) { _, _ in 200 }
        guard case .composited(let effected, _, _) =
            compositor.composite(frame: good, mask: nil)
        else {
            return XCTFail("expected a composited frame")
        }

        pools.allocationsFail = true
        let next = makeEffectFrame(
            width: 64, height: 36,
            rotation: .degrees180,
            timestampNs: 999,
            timestamp90kHz: 77
        ) { _, _ in 60 }
        let outcome = compositor.composite(frame: next, mask: nil)

        guard case .substituted(let substitute, let reason) = outcome else {
            return XCTFail("expected a substituted frame")
        }
        XCTAssertEqual(reason, .poolUnavailable)
        XCTAssertTrue(substitute.pixelBuffer === effected.pixelBuffer)
        XCTAssertEqual(substitute.rotation, .degrees180)
        XCTAssertEqual(substitute.timestampNs, 999)
        XCTAssertEqual(substitute.timestamp90kHz, 77)
        XCTAssertEqual(substitute.crop, CGRect(x: 0, y: 0, width: 64, height: 36))
        assertGray(substitute.pixelBuffer, 32, 18, 100)
    }

    func testAGeometryChangeDiscardsTheLastGoodAndAnswersBlack() {
        let pools = ScriptedPools()
        let compositor = CameraEffectCompositor(effect: .dim, pools: pools)
        let good = makeEffectFrame(width: 64, height: 36) { _, _ in 200 }
        guard case .composited = compositor.composite(frame: good, mask: nil) else {
            return XCTFail("expected a composited frame")
        }

        pools.allocationsFail = true
        let resized = makeEffectFrame(
            width: 48, height: 24, timestampNs: 1234, timestamp90kHz: 88
        ) { _, _ in 250 }
        let outcome = compositor.composite(frame: resized, mask: nil)

        guard case .substituted(let substitute, let reason) = outcome else {
            return XCTFail("expected a substituted frame")
        }
        XCTAssertEqual(reason, .poolUnavailable)
        XCTAssertEqual(substitute.adaptedWidth, 48)
        XCTAssertEqual(substitute.adaptedHeight, 24)
        XCTAssertEqual(substitute.crop, CGRect(x: 0, y: 0, width: 48, height: 24))
        XCTAssertEqual(substitute.timestampNs, 1234)
        assertGray(substitute.pixelBuffer, 5, 5, 0, within: 0)
        assertGray(substitute.pixelBuffer, 40, 20, 0, within: 0)
        XCTAssertEqual(alphaValue(substitute.pixelBuffer, 5, 5), 255)
        XCTAssertEqual(pools.pools.count, 2)
    }

    func testAMalformedFrameSubstitutesWithoutRendering() {
        let pools = ScriptedPools()
        let compositor = CameraEffectCompositor(effect: .dim, pools: pools)
        let good = makeEffectFrame(width: 64, height: 36, timestampNs: 5) { _, _ in 200 }
        guard case .composited(let effected, _, _) =
            compositor.composite(frame: good, mask: nil)
        else {
            return XCTFail("expected a composited frame")
        }

        let malformed = makeEffectFrame(
            width: 64, height: 36, adaptedWidth: 0, adaptedHeight: 0, timestampNs: 6
        ) { _, _ in 30 }
        let outcome = compositor.composite(frame: malformed, mask: nil)

        guard case .substituted(let substitute, let reason) = outcome else {
            return XCTFail("expected a substituted frame")
        }
        XCTAssertEqual(reason, .malformedFrame)
        XCTAssertTrue(substitute.pixelBuffer === effected.pixelBuffer)
        XCTAssertEqual(substitute.timestampNs, 6)
        XCTAssertEqual(pools.pools[0].taken, 1)
    }

    func testSustainedCompositingStaysInsideThePoolBound() {
        let pools = ScriptedPools()
        let compositor = CameraEffectCompositor(effect: .dim, pools: pools)
        let frame = makeEffectFrame(width: 64, height: 36) { _, _ in 200 }

        var composited = 0
        for _ in 0..<500 {
            if case .composited = compositor.composite(frame: frame, mask: nil) {
                composited += 1
            }
        }

        XCTAssertEqual(composited, 500)
        XCTAssertEqual(pools.pools.count, 1)
        XCTAssertEqual(pools.pools[0].taken, 500)
        XCTAssertEqual(pools.pools[0].exhausted, 0)
    }

    func testConcurrentCompositesAcrossAGeometryChangeStayCoherent() {
        let compositor = CameraEffectCompositor(effect: .dim)
        let wide = makeEffectFrame(width: 64, height: 36) { _, _ in 200 }
        let narrow = makeEffectFrame(width: 48, height: 24) { _, _ in 200 }
        let recording = NSLock()
        var violations = 0

        DispatchQueue.concurrentPerform(iterations: 240) { index in
            let frame = index % 3 == 0 ? narrow : wide
            let output = compositor.composite(frame: frame, mask: nil).frame
            let width = CVPixelBufferGetWidth(output.pixelBuffer)
            let height = CVPixelBufferGetHeight(output.pixelBuffer)
            let coherent =
                output.adaptedWidth == width && output.adaptedHeight == height
                && output.crop == CGRect(x: 0, y: 0, width: width, height: height)
                && (width == 64 || width == 48)
            if !coherent {
                recording.lock()
                violations += 1
                recording.unlock()
            }
        }

        XCTAssertEqual(violations, 0)
    }

    func testTheProcessingSeamPublishesTheOutcomesFrameAndNeverRaw() {
        let pools = ScriptedPools()
        pools.allocationsFail = true
        let compositor = CameraEffectCompositor(effect: .dim, pools: pools)
        let processor = XCameraFrameProcessor(
            compositor: compositor,
            producer: PersonMaskProducer(segmenter: ScriptedSegmenter(.deferred))
        )
        let frame = makeEffectFrame(width: 64, height: 36) { _, _ in 200 }

        let published = processor.process(frame)

        XCTAssertFalse(published.frame.pixelBuffer === frame.pixelBuffer)
        assertGray(published.frame.pixelBuffer, 32, 18, 0, within: 0)

        pools.allocationsFail = false
        let recovered = processor.process(frame)
        assertGray(recovered.frame.pixelBuffer, 32, 18, 100)
    }
}
