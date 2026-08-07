import CoreGraphics
import CoreVideo
import XCTest

@testable import ux_macos_core

/// The raw fixture's gray level; every legitimate output level sits well
/// below it, so its presence in an output is byte-decidable.
private let rawLevel: UInt8 = 213
private let personLevel: UInt8 = 64

private final class ScriptedSignposts: CameraEffectSignposting {
    private(set) var began: [UInt64] = []
    private(set) var ended: [UInt64] = []
    private var next: UInt64 = 7

    func compositeBegan() -> UInt64 {
        next += 1
        began.append(next)
        return next
    }

    func compositeEnded(_ token: UInt64) {
        ended.append(token)
    }
}

/// Blocks inside `compositeBegan` while holding, so a retire lands between a
/// frame's submission and its composite.
private final class GatedSignposts: CameraEffectSignposting {
    private let state = NSCondition()
    private var holding = false
    private var beganCount = 0

    func hold() {
        state.lock()
        holding = true
        state.unlock()
    }

    func release() {
        state.lock()
        holding = false
        state.broadcast()
        state.unlock()
    }

    @discardableResult
    func waitForBegan(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        state.lock()
        defer { state.unlock() }
        while beganCount < count {
            if !state.wait(until: deadline) { return false }
        }
        return true
    }

    func compositeBegan() -> UInt64 {
        state.lock()
        beganCount += 1
        state.broadcast()
        while holding { state.wait() }
        state.unlock()
        return 0
    }

    func compositeEnded(_ token: UInt64) {}
}

final class XCameraFrameProcessorTests: XCTestCase {
    /// 32x32 raw fixture; with `person` the centre 16x16 carries the person
    /// level so a mask edge never touches a raw-level pixel.
    private func rawFrame(
        crop: CGRect? = nil,
        adaptedWidth: Int? = nil,
        adaptedHeight: Int? = nil,
        person: Bool = false
    ) -> CameraFrame {
        makeEffectFrame(
            width: 32, height: 32, crop: crop,
            adaptedWidth: adaptedWidth, adaptedHeight: adaptedHeight
        ) { x, y in
            person && (8..<24).contains(x) && (8..<24).contains(y)
                ? personLevel : rawLevel
        }
    }

    private func maskedSegmenter() -> ScriptedSegmenter {
        ScriptedSegmenter(
            .immediate,
            mask: {
                makeMaskBuffer(
                    width: 32, height: 32,
                    person: CGRect(x: 12, y: 12, width: 8, height: 8)
                )
            }
        )
    }

    private func maxGray(_ buffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var top = 0
        for y in 0..<height {
            let row = (base + y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                top = max(top, Int(row[x * 4]))
            }
        }
        return top
    }

    private func assertNoRawBytes(
        _ frame: CameraFrame, file: StaticString = #filePath, line: UInt = #line
    ) {
        let top = maxGray(frame.pixelBuffer)
        XCTAssertLessThan(top, 160, "raw-level byte survived", file: file, line: line)
    }

    // MARK: - No raw leak

    func testWarmUpTakesTheWholeFramePathAndLeaksNoRawBytes() {
        let processor = XCameraFrameProcessor(
            compositor: CameraEffectCompositor(effect: .dim),
            producer: PersonMaskProducer(
                segmenter: ScriptedSegmenter(.deferred), clock: TestClock()
            ),
            signposts: ScriptedSignposts()
        )
        let raw = rawFrame()

        let outcome = processor.process(raw)

        guard case .composited(_, let rejection) = outcome.outcome else {
            return XCTFail("expected a composited frame")
        }
        XCTAssertNil(rejection)
        XCTAssertFalse(outcome.frame.pixelBuffer === raw.pixelBuffer)
        assertNoRawBytes(outcome.frame)
    }

    func testARejectedMaskTakesTheWholeFramePathAndRecordsWhy() {
        let producer = PersonMaskProducer(segmenter: maskedSegmenter(), clock: TestClock())
        let processor = XCameraFrameProcessor(
            compositor: CameraEffectCompositor(effect: .dim),
            producer: producer,
            signposts: ScriptedSignposts()
        )
        _ = processor.process(rawFrame(person: true))
        producer.queue.sync {}
        XCTAssertNotNil(producer.mask)

        let cropped = rawFrame(
            crop: CGRect(x: 0, y: 0, width: 16, height: 16),
            adaptedWidth: 16, adaptedHeight: 16
        )
        let outcome = processor.process(cropped)

        guard case .composited = outcome.outcome else {
            return XCTFail("expected a composited frame")
        }
        XCTAssertEqual(processor.lastMaskRejection, .sourceRectMismatch)
        XCTAssertFalse(outcome.frame.pixelBuffer === cropped.pixelBuffer)
        assertNoRawBytes(outcome.frame)
    }

    func testAGoodMaskCompositesThePersonOverTheEffectedBackground() {
        let producer = PersonMaskProducer(segmenter: maskedSegmenter(), clock: TestClock())
        let processor = XCameraFrameProcessor(
            compositor: CameraEffectCompositor(effect: .dim),
            producer: producer,
            signposts: ScriptedSignposts()
        )
        _ = processor.process(rawFrame(person: true))
        producer.queue.sync {}

        let outcome = processor.process(rawFrame(person: true))

        guard case .composited = outcome.outcome else {
            return XCTFail("expected a composited frame")
        }
        XCTAssertNil(processor.lastMaskRejection)
        let output = outcome.frame.pixelBuffer
        XCTAssertEqual(grayValue(output, 16, 16), Int(personLevel))
        XCTAssertLessThan(abs(grayValue(output, 2, 2) - 106), 5)
        assertNoRawBytes(outcome.frame)
    }

    func testSubstitutionBeforeAnyCompositeAnswersBlack() {
        let pools = ScriptedPools()
        pools.poolCreationFails = true
        let processor = XCameraFrameProcessor(
            compositor: CameraEffectCompositor(effect: .dim, pools: pools),
            producer: PersonMaskProducer(
                segmenter: ScriptedSegmenter(.deferred), clock: TestClock()
            ),
            signposts: ScriptedSignposts()
        )
        let raw = rawFrame()

        let outcome = processor.process(raw)

        guard case .substituted(_, let reason) = outcome.outcome else {
            return XCTFail("expected a substituted frame")
        }
        XCTAssertEqual(reason, .poolUnavailable)
        XCTAssertFalse(outcome.frame.pixelBuffer === raw.pixelBuffer)
        XCTAssertEqual(maxGray(outcome.frame.pixelBuffer), 0)
    }

    func testSubstitutionAfterAGoodCompositeAnswersTheLastGoodFrame() {
        let pools = ScriptedPools()
        let processor = XCameraFrameProcessor(
            compositor: CameraEffectCompositor(effect: .dim, pools: pools),
            producer: PersonMaskProducer(
                segmenter: ScriptedSegmenter(.deferred), clock: TestClock()
            ),
            signposts: ScriptedSignposts()
        )
        let good = processor.process(rawFrame())
        guard case .composited = good.outcome else {
            return XCTFail("expected a composited frame")
        }

        pools.allocationsFail = true
        let raw = rawFrame()
        let outcome = processor.process(raw)

        guard case .substituted(_, let reason) = outcome.outcome else {
            return XCTFail("expected a substituted frame")
        }
        XCTAssertEqual(reason, .poolUnavailable)
        XCTAssertTrue(outcome.frame.pixelBuffer === good.frame.pixelBuffer)
        assertNoRawBytes(outcome.frame)
    }

    func testRetireMidFrameCompletesTheCompositeAndResetsTheProducer() {
        let producer = PersonMaskProducer(segmenter: maskedSegmenter(), clock: TestClock())
        let gate = GatedSignposts()
        let processor = XCameraFrameProcessor(
            compositor: CameraEffectCompositor(effect: .dim),
            producer: producer,
            signposts: gate
        )
        _ = processor.process(rawFrame(person: true))
        producer.queue.sync {}
        XCTAssertNotNil(producer.mask)

        gate.hold()
        let returned = expectation(description: "in-flight frame returns")
        var outcome: CameraFrameOutcome?
        DispatchQueue.global().async {
            outcome = processor.process(self.rawFrame(person: true))
            returned.fulfill()
        }
        XCTAssertTrue(gate.waitForBegan(2))

        processor.retire()
        XCTAssertNil(producer.mask)

        gate.release()
        wait(for: [returned], timeout: 5)

        guard case .composited = outcome!.outcome else {
            return XCTFail("expected a composited frame")
        }
        assertNoRawBytes(outcome!.frame)
    }

    // MARK: - Producer wiring

    func testEveryFrameFeedsTheProducerAndTheCompositePullsThePublishedMask() {
        let clock = TestClock()
        let segmenter = maskedSegmenter()
        let producer = PersonMaskProducer(segmenter: segmenter, clock: clock)
        let processor = XCameraFrameProcessor(
            compositor: CameraEffectCompositor(effect: .dim),
            producer: producer,
            signposts: ScriptedSignposts()
        )

        var last: CameraFrameOutcome?
        for _ in 0..<4 {
            clock.advance(1)
            last = processor.process(rawFrame(person: true))
            producer.queue.sync {}
        }

        XCTAssertEqual(segmenter.submits, 4)
        XCTAssertEqual(grayValue(last!.frame.pixelBuffer, 16, 16), Int(personLevel))
        assertNoRawBytes(last!.frame)
    }

    func testTheProcessorResetsItsProducerOnRetireAndNeverOtherwise() {
        let clock = TestClock()
        let producer = PersonMaskProducer(segmenter: maskedSegmenter(), clock: clock)
        let processor = XCameraFrameProcessor(
            compositor: CameraEffectCompositor(effect: .dim),
            producer: producer,
            signposts: ScriptedSignposts()
        )
        _ = processor.process(rawFrame(person: true))
        producer.queue.sync {}
        XCTAssertNotNil(producer.mask)

        for _ in 0..<3 {
            clock.advance(1)
            _ = processor.process(rawFrame(person: true))
            producer.queue.sync {}
        }
        XCTAssertNotNil(producer.mask)

        processor.retire()

        XCTAssertNil(producer.mask)
    }

    func testTheFactoryBuildsOneProducerPerProcessor() throws {
        guard #available(macOS 12, *) else { return }
        let factory = XCameraFrameProcessors()

        let first = try factory.makeProcessor(for: .blur) as! XCameraFrameProcessor
        let second = try factory.makeProcessor(for: .dim) as! XCameraFrameProcessor

        XCTAssertFalse(first.producer === second.producer)
    }

    // MARK: - Signposts

    func testSignpostsBracketEveryComposite() {
        let signposts = ScriptedSignposts()
        let processor = XCameraFrameProcessor(
            compositor: CameraEffectCompositor(effect: .dim),
            producer: PersonMaskProducer(
                segmenter: ScriptedSegmenter(.deferred), clock: TestClock()
            ),
            signposts: signposts
        )

        for _ in 0..<3 { _ = processor.process(rawFrame()) }

        XCTAssertEqual(signposts.began.count, 3)
        XCTAssertEqual(signposts.ended, signposts.began)
    }
}
