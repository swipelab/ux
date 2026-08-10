import CoreGraphics
import CoreVideo
import XCTest

@testable import ux_macos_core

private let target = PersonMaskProducer.targetSubmissionInterval

/// The mask grid the fast quality level answers on.
private let gridWidth = 256
private let gridHeight = 192

final class PersonMaskProducerTests: XCTestCase {
    private var pools: ScriptedPools!

    override func setUp() {
        super.setUp()
        pools = ScriptedPools(threshold: PersonMaskProducer.inputBufferCount)
    }

    private func makeProducer(
        _ segmenter: ScriptedSegmenter, clock: TestClock
    ) -> PersonMaskProducer {
        PersonMaskProducer(segmenter: segmenter, pools: pools, clock: clock)
    }

    private func frame(
        format: OSType = kCVPixelFormatType_32BGRA,
        crop: CGRect? = nil,
        adaptedWidth: Int? = nil,
        adaptedHeight: Int? = nil,
        gray: @escaping (Int, Int) -> UInt8 = { _, _ in 200 }
    ) -> CameraFrame {
        makeEffectFrame(
            width: 320, height: 180, format: format, crop: crop,
            adaptedWidth: adaptedWidth, adaptedHeight: adaptedHeight, gray: gray
        )
    }

    private func assertGray(
        _ buffer: CVPixelBuffer, _ x: Int, _ y: Int, _ expected: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let value = grayValue(buffer, x, y)
        XCTAssertTrue(
            abs(value - expected) <= 4,
            "(\(x),\(y)) = \(value), expected \(expected) ± 4",
            file: file, line: line
        )
    }

    func testFrameCallbacksCompleteWhileAnInferenceNeverAnswers() {
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.blocked)
        let producer = makeProducer(segmenter, clock: clock)
        defer { segmenter.release() }

        for _ in 0..<100 {
            clock.advance(target)
            producer.consider(frame())
        }

        XCTAssertTrue(segmenter.waitForSubmits(1))
        XCTAssertNil(producer.mask)
    }

    func testOnlyOneInferenceIsInFlightAndNothingQueuesBehindIt() {
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.blocked)
        let producer = makeProducer(segmenter, clock: clock)
        defer { segmenter.release() }

        for _ in 0..<100 {
            clock.advance(target)
            producer.consider(frame())
        }
        XCTAssertTrue(segmenter.waitForSubmits(1))

        XCTAssertEqual(segmenter.submits, 1)
        XCTAssertEqual(pools.pools[0].taken, 1)
    }

    func testNoFurtherCopyIsMadeWhileAnInferenceIsInFlight() {
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.blocked)
        let producer = makeProducer(segmenter, clock: clock)
        defer { segmenter.release() }

        producer.consider(frame())
        XCTAssertTrue(segmenter.waitForSubmits(1))
        XCTAssertEqual(pools.pools[0].taken, 1)

        for _ in 0..<20 {
            clock.advance(target * 10)
            producer.consider(frame())
        }

        XCTAssertEqual(pools.pools[0].taken, 1)
        XCTAssertEqual(pools.pools[0].refused, 0)
        XCTAssertEqual(pools.pools[0].exhausted, 0)
    }

    func testTheCameraBufferIsReleasedWhileTheCopyReachesTheInference() {
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.blocked)
        let producer = makeProducer(segmenter, clock: clock)
        defer { segmenter.release() }
        weak var cameraBuffer: CVPixelBuffer?

        autoreleasepool {
            let camera = frame()
            cameraBuffer = camera.pixelBuffer
            producer.consider(camera)
        }

        XCTAssertNil(cameraBuffer)
        XCTAssertTrue(segmenter.waitForSubmits(1))
        XCTAssertEqual(segmenter.inputs[0].width, PersonMaskProducer.inputWidth)
        XCTAssertEqual(segmenter.inputs[0].height, PersonMaskProducer.inputHeight)
    }

    func testACompletionFromARetiredGenerationIsDropped() {
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.deferred)
        let producer = makeProducer(segmenter, clock: clock)

        producer.consider(frame())
        producer.queue.sync {}
        producer.reset()
        segmenter.answerHeld()

        XCTAssertNil(producer.mask)
    }

    func testACompletionOfAnInferenceResetRanThroughIsDropped() {
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.blocked)
        let producer = makeProducer(segmenter, clock: clock)

        producer.consider(frame())
        XCTAssertTrue(segmenter.waitForSubmits(1))
        producer.reset()
        segmenter.release()
        XCTAssertTrue(segmenter.waitForFinishes(1))

        XCTAssertNil(producer.mask)
    }

    func testEveryInputFormatProducesAMask() {
        let formats: [OSType] = [
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        for format in formats {
            let clock = TestClock()
            let segmenter = ScriptedSegmenter(.immediate)
            let producer = makeProducer(segmenter, clock: clock)

            producer.consider(frame(format: format))
            producer.queue.sync {}

            let mask = producer.mask
            XCTAssertNotNil(mask, "format \(format) produced no mask")
            XCTAssertEqual(mask?.width, gridWidth)
            XCTAssertEqual(mask?.height, gridHeight)
        }
    }

    func testAProducedMaskCompositesThePersonAndAStaleOneTakesTheWholeFramePath() {
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.immediate)
        let producer = makeProducer(segmenter, clock: clock)
        let compositor = CameraEffectCompositor(effect: .dim)
        let wide = frame()

        producer.consider(wide)
        producer.queue.sync {}
        guard let mask = producer.mask else { return XCTFail("expected a mask") }
        XCTAssertEqual(mask.sourceRect, wide.crop)

        guard case .composited(let output, _, let rejection) =
            compositor.composite(frame: wide, mask: mask)
        else { return XCTFail("expected a composited frame") }
        XCTAssertNil(rejection)
        assertGray(output.pixelBuffer, 160, 90, 200)
        assertGray(output.pixelBuffer, 20, 20, 100)
        assertGray(output.pixelBuffer, 300, 160, 100)

        let cropped = frame(
            crop: CGRect(x: 0, y: 0, width: 160, height: 90),
            adaptedWidth: 160, adaptedHeight: 90
        )
        guard case .composited(let whole, _, let stale) =
            compositor.composite(frame: cropped, mask: producer.mask)
        else { return XCTFail("expected a composited frame") }
        XCTAssertEqual(stale, .sourceRectMismatch)
        assertGray(whole.pixelBuffer, 80, 45, 100)

        clock.advance(target * 2)
        producer.consider(cropped)
        producer.queue.sync {}
        XCTAssertEqual(producer.mask?.sourceRect, cropped.crop)

        let processor = XCameraFrameProcessor(compositor: compositor, producer: producer)
        let published = processor.process(cropped)
        assertGray(published.frame.pixelBuffer, 80, 45, 200)
        assertGray(published.frame.pixelBuffer, 10, 10, 100)
    }

    func testAnAllZeroMaskIsPublishedAndTheCompositorTakesTheWholeFramePath() {
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(
            .immediate, mask: { makeMaskBuffer(width: gridWidth, height: gridHeight) }
        )
        let producer = makeProducer(segmenter, clock: clock)
        let compositor = CameraEffectCompositor(effect: .dim)
        let camera = frame()

        producer.consider(camera)
        producer.queue.sync {}

        guard let mask = producer.mask else { return XCTFail("expected a mask") }
        guard case .composited(let output, _, let rejection) =
            compositor.composite(frame: camera, mask: mask)
        else { return XCTFail("expected a composited frame") }
        XCTAssertEqual(rejection, .empty)
        assertGray(output.pixelBuffer, 160, 90, 100)
    }

    func testSubmissionsStayAtOrBelowTheTargetRateHoweverFastFramesArrive() {
        let fast = ScriptedSegmenter(.immediate)
        let fastClock = TestClock()
        let atSixty = makeProducer(fast, clock: fastClock)
        for _ in 0..<60 {
            fastClock.advance(1.0 / 60.0)
            atSixty.consider(frame())
            atSixty.queue.sync {}
        }

        let doubled = ScriptedSegmenter(.immediate)
        let doubledClock = TestClock()
        let atOneTwenty = makeProducer(doubled, clock: doubledClock)
        for _ in 0..<120 {
            doubledClock.advance(1.0 / 120.0)
            atOneTwenty.consider(frame())
            atOneTwenty.queue.sync {}
        }

        let cap = Int(PersonMaskProducer.targetSubmissionsPerSecond)
        XCTAssertLessThanOrEqual(fast.submits, cap)
        XCTAssertGreaterThanOrEqual(fast.submits, cap - 3)
        XCTAssertLessThanOrEqual(doubled.submits, cap)
    }

    func testASlowInferenceWidensTheIntervalAndAFastOneReturnsItToTheTarget() {
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.advancing(0.5), clock: clock)
        let producer = makeProducer(segmenter, clock: clock)

        producer.consider(frame())
        producer.queue.sync {}
        XCTAssertEqual(segmenter.submits, 1)
        XCTAssertEqual(producer.submissionInterval, target, accuracy: 1e-9)

        producer.consider(frame())
        producer.queue.sync {}
        XCTAssertEqual(segmenter.submits, 2)
        XCTAssertEqual(producer.submissionInterval, 0.5, accuracy: 1e-9)

        segmenter.behavior = .immediate
        producer.consider(frame())
        producer.queue.sync {}
        XCTAssertEqual(segmenter.submits, 3)
        XCTAssertEqual(producer.submissionInterval, target, accuracy: 1e-9)

        clock.advance(target * 2)
        producer.consider(frame())
        producer.queue.sync {}
        XCTAssertEqual(segmenter.submits, 4)
    }

    func testAnErroredInferenceLeavesTheProducerSubmittingAgain() {
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.failing)
        let producer = makeProducer(segmenter, clock: clock)

        producer.consider(frame())
        producer.queue.sync {}
        XCTAssertNil(producer.mask)

        segmenter.behavior = .immediate
        clock.advance(target * 2)
        producer.consider(frame())
        producer.queue.sync {}

        XCTAssertEqual(segmenter.submits, 2)
        XCTAssertNotNil(producer.mask)
        XCTAssertEqual(pools.pools[0].exhausted, 0)
    }

    func testARefusedBufferAndAZeroSizedCropEachSubmitOnTheVeryNextFrame() {
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.immediate)
        let producer = makeProducer(segmenter, clock: clock)

        pools.allocationsFail = true
        producer.consider(frame())
        pools.allocationsFail = false
        producer.consider(frame())
        producer.queue.sync {}
        XCTAssertEqual(segmenter.submits, 1)

        producer.reset()
        producer.consider(frame(crop: CGRect(x: 0, y: 0, width: 0, height: 0)))
        producer.consider(frame())
        producer.queue.sync {}

        XCTAssertEqual(segmenter.submits, 2)
        XCTAssertNotNil(producer.mask)
    }

    func testResetLetsAFreshFrameSubmitWhileTheAbandonedInferenceStillHoldsABuffer() {
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.blocked)
        let producer = makeProducer(segmenter, clock: clock)

        producer.consider(frame())
        XCTAssertTrue(segmenter.waitForSubmits(1))
        XCTAssertEqual(pools.pools[0].taken, 1)

        producer.reset()
        producer.consider(frame())

        XCTAssertEqual(pools.pools[0].taken, 2)
        XCTAssertEqual(pools.pools[0].refused, 0)
        XCTAssertEqual(pools.pools[0].exhausted, 0)

        segmenter.release()
        XCTAssertTrue(segmenter.waitForSubmits(2))
        XCTAssertTrue(segmenter.waitForFinishes(2))
        XCTAssertNotNil(producer.mask)
    }

    func testResetWithAnInferenceInFlightDropsItAndReturnsItsBuffer() {
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.blocked)
        let producer = makeProducer(segmenter, clock: clock)

        producer.consider(frame())
        XCTAssertTrue(segmenter.waitForSubmits(1))
        producer.reset()
        segmenter.release()
        XCTAssertTrue(segmenter.waitForFinishes(1))
        XCTAssertNil(producer.mask)

        segmenter.behavior = .immediate
        for _ in 0..<5 {
            clock.advance(target * 2)
            producer.consider(frame())
            producer.queue.sync {}
        }

        XCTAssertEqual(segmenter.submits, 6)
        XCTAssertEqual(pools.pools[0].exhausted, 0)
        XCTAssertNotNil(producer.mask)
    }

    func testTheVisionSegmenterRunsAtTheFastQualityLevel() throws {
        guard #available(macOS 12, iOS 15, *) else {
            throw XCTSkip("person segmentation needs \(CameraEffectHost.requirement)")
        }
        XCTAssertEqual(VisionPersonSegmenter().quality, .fast)
    }
}
