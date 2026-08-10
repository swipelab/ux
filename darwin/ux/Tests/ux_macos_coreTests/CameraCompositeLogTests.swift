import CoreGraphics
import CoreVideo
import XCTest

@testable import ux_macos_core

/// Builds the production processor over a scripted segmenter, so a served
/// frame carries the mask and use the composite path reports.
private final class ScriptedFrameProcessors: CameraEffectProcessorFactory {
    init(segmenter: ScriptedSegmenter, clock: TestClock) {
        self.segmenter = segmenter
        self.clock = clock
    }

    private let segmenter: ScriptedSegmenter
    private let clock: TestClock

    private(set) var made: [XCameraFrameProcessor] = []

    func makeProcessor(for effect: CameraEffect) throws -> CameraEffectProcessor {
        let processor = XCameraFrameProcessor(
            compositor: CameraEffectCompositor(effect: effect, measures: true),
            producer: PersonMaskProducer(segmenter: segmenter, clock: clock)
        )
        made.append(processor)
        return processor
    }
}

final class CameraCompositeLogTests: XCTestCase {
    private func frameAt(_ timestampNs: Int64) -> CameraFrame {
        makeEffectFrame(width: 32, height: 32, timestampNs: timestampNs) { x, y in
            (8..<24).contains(x) && (8..<24).contains(y) ? 64 : 213
        }
    }

    private func serve(
        _ log: CameraCompositeLog,
        processors: CameraEffectProcessorFactory,
        generation: Int = 7
    ) -> CameraEffectsHarness {
        let harness = CameraEffectsHarness(processors: processors, composites: log)
        harness.send(.setEffect(trackId: "t1", effect: .dim, generation: generation))
        return harness
    }

    private func deliver(_ harness: CameraEffectsHarness, _ frame: CameraFrame) {
        harness.bridge.live.last?.deliverFrame(frame)
    }

    private func maskingSegmenter(person: CGRect? = nil) -> ScriptedSegmenter {
        ScriptedSegmenter(
            .immediate,
            mask: { makeMaskBuffer(width: 32, height: 32, person: person) }
        )
    }

    func testARecordCarriesItsGenerationMaskSourceAndUse() {
        let log = CameraCompositeLog(exposes: true)
        let processors = ScriptedFrameProcessors(
            segmenter: maskingSegmenter(person: CGRect(x: 12, y: 12, width: 8, height: 8)),
            clock: TestClock()
        )
        let harness = serve(log, processors: processors)

        deliver(harness, frameAt(10))
        processors.made[0].producer.queue.sync {}
        deliver(harness, frameAt(20))

        XCTAssertEqual(log.records().map(\.generation), [7, 7])
        XCTAssertEqual(log.records().map(\.frameTimestampNs), [10, 20])
        XCTAssertEqual(log.records().map(\.maskFrameTimestampNs), [nil, 10])
        XCTAssertEqual(log.records().map(\.use), [.maskless, .used])
        XCTAssertNotNil(log.records().last?.background)
    }

    func testAStructurallyInapplicableMaskIsRecordedRejectedWithItsReason() {
        let log = CameraCompositeLog(exposes: true)
        let processors = ScriptedFrameProcessors(
            segmenter: maskingSegmenter(), clock: TestClock()
        )
        let harness = serve(log, processors: processors)

        deliver(harness, frameAt(10))
        processors.made[0].producer.queue.sync {}
        deliver(harness, frameAt(20))

        XCTAssertEqual(log.records().map(\.use), [.maskless, .rejected(.empty)])
        XCTAssertEqual(log.records().map(\.maskFrameTimestampNs), [nil, 10])
    }

    func testASubstitutedFrameIsRecordedWithItsReasonAndNoGrid() {
        let log = CameraCompositeLog(exposes: true)
        let processors = FakeEffectProcessors()
        let processor = FakeEffectProcessor()
        processor.answer = .substitute
        processors.prepared = [processor]
        let harness = serve(log, processors: processors)

        deliver(harness, makeCameraFrame(timestampNs: 10))

        XCTAssertEqual(log.records().map(\.use), [.substituted(.renderFailed)])
        XCTAssertNil(log.records().last?.background)
    }

    func testSustainedFramesLeaveTheLogAtItsCapacityHoldingTheNewest() {
        let log = CameraCompositeLog(exposes: true, capacity: 8)
        let harness = serve(log, processors: FakeEffectProcessors())

        harness.deliverFrame(count: 40)

        XCTAssertEqual(
            log.records().map(\.frameTimestampNs),
            (32..<40).map { Int64($0) * CameraEffectsHarness.frameIntervalNs }
        )
    }

    func testALogThatDoesNotExposeHoldsNothingUnderSustainedFrames() {
        let log = CameraCompositeLog(exposes: false)
        let harness = serve(log, processors: FakeEffectProcessors())

        harness.deliverFrame(count: 40)

        XCTAssertTrue(log.records().isEmpty)
    }

    func testTheRigReadsTheLogTheProcessRecordsInto() {
        let record = CameraCompositeRecord(
            generation: 11,
            frameTimestampNs: 99,
            maskFrameTimestampNs: 98,
            use: .used,
            background: CameraBackgroundGrid(repeating: 1)
        )

        CameraEffectHost.composites.record(record)

        XCTAssertEqual(CameraEffectsRig.composites().last, record)
    }
}
