import CoreGraphics
import XCTest

@testable import ux_macos_core

private let target = PersonMaskProducer.targetSubmissionInterval

final class CameraMaskLogTests: XCTestCase {
    private var pools: ScriptedPools!

    override func setUp() {
        super.setUp()
        pools = ScriptedPools(threshold: PersonMaskProducer.inputBufferCount)
    }

    private func makeProducer(
        _ segmenter: ScriptedSegmenter, clock: TestClock, log: CameraMaskLog
    ) -> PersonMaskProducer {
        PersonMaskProducer(segmenter: segmenter, pools: pools, clock: clock, log: log)
    }

    private func frame(timestampNs: Int64 = 0) -> CameraFrame {
        makeEffectFrame(width: 320, height: 180, timestampNs: timestampNs)
    }

    // MARK: - What one submission records

    func testASubmissionCarriesItsFrameTimestampCadenceAndPublication() throws {
        let log = CameraMaskLog(exposes: true)
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.immediate)
        let producer = makeProducer(segmenter, clock: clock, log: log)

        clock.advance(4)
        producer.consider(frame(timestampNs: 1_234))
        XCTAssertTrue(segmenter.waitForFinishes(1))

        let submission = try XCTUnwrap(log.telemetry(at: 4).submissions.first)
        XCTAssertEqual(submission.sequence, 0)
        XCTAssertEqual(submission.frameTimestampNs, 1_234)
        XCTAssertEqual(submission.interval, target)
        XCTAssertEqual(submission.claimedAt, 4)
        XCTAssertEqual(submission.submittedAt, 4)
        XCTAssertEqual(submission.enteredAt, 4)
        XCTAssertEqual(submission.closedAt, 4)
        XCTAssertEqual(submission.publishedAt, 4)
        XCTAssertNil(submission.failure)
    }

    func testAnInferenceHoldingItsAnswerClosesLongAfterItsEntry() throws {
        let log = CameraMaskLog(exposes: true)
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.deferred)
        let producer = makeProducer(segmenter, clock: clock, log: log)

        producer.consider(frame())
        XCTAssertTrue(segmenter.waitForSubmits(1))
        clock.advance(9)
        segmenter.answerHeld()

        let submission = try XCTUnwrap(log.telemetry(at: 9).submissions.first)
        XCTAssertEqual(submission.claimedAt, 0)
        XCTAssertEqual(submission.enteredAt, 0)
        XCTAssertEqual(submission.closedAt, 9)
        XCTAssertEqual(submission.publishedAt, 9)
    }

    func testASubmissionWaitingOnTheQueueEntersTheSegmenterAfterItsClaim() throws {
        let log = CameraMaskLog(exposes: true)
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.blocked)
        let producer = makeProducer(segmenter, clock: clock, log: log)

        producer.consider(frame())
        XCTAssertTrue(segmenter.waitForSubmits(1))
        producer.reset()
        clock.advance(5)
        producer.consider(frame())
        clock.advance(4)
        segmenter.release()
        XCTAssertTrue(segmenter.waitForFinishes(2))

        let waiting = try XCTUnwrap(log.telemetry(at: 9).submissions.last)
        XCTAssertEqual(waiting.claimedAt, 5)
        XCTAssertEqual(waiting.submittedAt, 5)
        XCTAssertEqual(waiting.enteredAt, 9)
    }

    // MARK: - Why a frame opened no submission

    func testEveryConsideredFrameCountsAndTheLastCarriesItsInstant() {
        let log = CameraMaskLog(exposes: true)
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.immediate)
        let producer = makeProducer(segmenter, clock: clock, log: log)

        for _ in 0..<5 {
            clock.advance(target)
            producer.consider(frame())
        }

        XCTAssertEqual(log.telemetry(at: 0).considered, 5)
        XCTAssertEqual(log.telemetry(at: 0).lastConsideredAt, target * 5)
    }

    func testAnInferenceInFlightRefusesEveryFrameAsInFlight() {
        let log = CameraMaskLog(exposes: true)
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.blocked)
        let producer = makeProducer(segmenter, clock: clock, log: log)
        defer { segmenter.release() }

        producer.consider(frame())
        XCTAssertTrue(segmenter.waitForSubmits(1))
        for _ in 0..<20 {
            clock.advance(target * 10)
            producer.consider(frame())
        }

        let telemetry = log.telemetry(at: 0)
        XCTAssertEqual(telemetry.refusedInFlight, 20)
        XCTAssertEqual(telemetry.refusedCadence, 0)
        XCTAssertEqual(telemetry.submissions.count, 1)
    }

    func testAClosedCadenceGateRefusesTheFramesInsideIt() {
        let log = CameraMaskLog(exposes: true)
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.immediate)
        let producer = makeProducer(segmenter, clock: clock, log: log)

        producer.consider(frame())
        XCTAssertTrue(segmenter.waitForFinishes(1))
        for _ in 0..<4 {
            clock.advance(target / 4)
            producer.consider(frame())
        }
        XCTAssertTrue(segmenter.waitForFinishes(2))

        let telemetry = log.telemetry(at: 0)
        XCTAssertEqual(telemetry.refusedCadence, 3)
        XCTAssertEqual(telemetry.refusedInFlight, 0)
        XCTAssertEqual(telemetry.submissions.count, 2)
    }

    func testAWidenedCadenceIsWhatTheNextClaimRecords() {
        let log = CameraMaskLog(exposes: true)
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.immediate, clock: clock)
        let producer = makeProducer(segmenter, clock: clock, log: log)

        producer.consider(frame())
        XCTAssertTrue(segmenter.waitForFinishes(1))
        segmenter.behavior = .advancing(3)
        clock.advance(target)
        producer.consider(frame())
        XCTAssertTrue(segmenter.waitForFinishes(2))
        clock.advance(3)
        producer.consider(frame())
        XCTAssertTrue(segmenter.waitForFinishes(3))

        XCTAssertEqual(
            log.telemetry(at: 0).submissions.map(\.interval), [target, target, 3]
        )
    }

    // MARK: - What closed a submission short of a publication

    func testAFailedInferenceClosesItsSubmissionWithTheError() throws {
        let log = CameraMaskLog(exposes: true)
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.failing)
        let producer = makeProducer(segmenter, clock: clock, log: log)

        producer.consider(frame())
        XCTAssertTrue(segmenter.waitForFinishes(1))

        let telemetry = log.telemetry(at: 0)
        let submission = try XCTUnwrap(telemetry.submissions.first)
        XCTAssertEqual(
            submission.failure, .inference(String(describing: ScriptedSegmenterFailure()))
        )
        XCTAssertNil(submission.publishedAt)
        XCTAssertEqual(submission.closedAt, 0)
        XCTAssertEqual(telemetry.inferenceFailures, 1)
        XCTAssertEqual(telemetry.publications, 0)
    }

    func testAnInputThatCannotBeTakenClosesItsSubmission() throws {
        let log = CameraMaskLog(exposes: true)
        let clock = TestClock()
        let producer = makeProducer(ScriptedSegmenter(.immediate), clock: clock, log: log)
        pools.allocationsFail = true

        producer.consider(frame())

        let telemetry = log.telemetry(at: 0)
        let submission = try XCTUnwrap(telemetry.submissions.first)
        XCTAssertEqual(submission.failure, .input)
        XCTAssertNil(submission.submittedAt)
        XCTAssertNil(submission.enteredAt)
        XCTAssertEqual(telemetry.inputFailures, 1)
    }

    func testAnInferenceOutlivingItsEffectClosesAsRetired() throws {
        let log = CameraMaskLog(exposes: true)
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.deferred)
        let producer = makeProducer(segmenter, clock: clock, log: log)

        producer.consider(frame())
        XCTAssertTrue(segmenter.waitForSubmits(1))
        producer.reset()
        clock.advance(2)
        segmenter.answerHeld()

        let telemetry = log.telemetry(at: 2)
        let submission = try XCTUnwrap(telemetry.submissions.first)
        XCTAssertEqual(submission.failure, .retired)
        XCTAssertEqual(submission.closedAt, 2)
        XCTAssertEqual(telemetry.publications, 0)
    }

    // MARK: - The log outlives the producers it counts

    func testTotalsSurviveTheProducerTheyWereCountedOn() {
        let log = CameraMaskLog(exposes: true)
        let clock = TestClock()
        let first = ScriptedSegmenter(.immediate)
        let retiring = makeProducer(first, clock: clock, log: log)
        retiring.consider(frame())
        XCTAssertTrue(first.waitForFinishes(1))
        retiring.reset()

        clock.advance(target)
        let second = ScriptedSegmenter(.immediate)
        let successor = makeProducer(second, clock: clock, log: log)
        successor.consider(frame())
        XCTAssertTrue(second.waitForFinishes(1))

        let telemetry = log.telemetry(at: 0)
        XCTAssertEqual(telemetry.considered, 2)
        XCTAssertEqual(telemetry.publications, 2)
        XCTAssertEqual(telemetry.submissions.map(\.sequence), [0, 1])
    }

    func testTheOldestSubmissionsLeaveOnceTheCapacityIsPassed() {
        let log = CameraMaskLog(exposes: true, capacity: 4)
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.immediate)
        let producer = makeProducer(segmenter, clock: clock, log: log)

        for finished in 1...10 {
            clock.advance(target * 2)
            producer.consider(frame())
            XCTAssertTrue(segmenter.waitForFinishes(finished))
        }

        let telemetry = log.telemetry(at: 0)
        XCTAssertEqual(telemetry.submissions.map(\.sequence), [6, 7, 8, 9])
        XCTAssertEqual(telemetry.publications, 10)
    }

    func testACompletionForASubmissionThatLeftMovesNoRecordStillHeld() {
        let log = CameraMaskLog(exposes: true, capacity: 2)
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.deferred)
        let producer = makeProducer(segmenter, clock: clock, log: log)

        producer.consider(frame())
        XCTAssertTrue(segmenter.waitForSubmits(1))
        producer.reset()
        segmenter.behavior = .immediate
        var published: [TimeInterval] = []
        for finished in 2...3 {
            clock.advance(target * 2)
            published.append(clock.now)
            producer.consider(frame())
            XCTAssertTrue(segmenter.waitForFinishes(finished))
        }
        clock.advance(5)
        segmenter.answerHeld()

        let telemetry = log.telemetry(at: clock.now)
        XCTAssertEqual(telemetry.submissions.map(\.sequence), [1, 2])
        XCTAssertEqual(telemetry.submissions.compactMap(\.publishedAt), published)
        XCTAssertEqual(telemetry.submissions.compactMap(\.failure), [])
    }

    func testTheReadInstantIsWhatTheSnapshotCarries() {
        XCTAssertEqual(CameraMaskLog(exposes: true).telemetry(at: 41.5).readAt, 41.5)
    }

    // MARK: - A log that keeps nothing

    func testALogThatExposesNothingKeepsNoSubmissionAndNoTotal() {
        let log = CameraMaskLog(exposes: false)
        let clock = TestClock()
        let segmenter = ScriptedSegmenter(.immediate)
        let producer = makeProducer(segmenter, clock: clock, log: log)

        producer.consider(frame())
        XCTAssertTrue(segmenter.waitForFinishes(1))
        clock.advance(target)
        producer.consider(frame())
        XCTAssertTrue(segmenter.waitForFinishes(2))

        let telemetry = log.telemetry(at: 0)
        XCTAssertEqual(telemetry.submissions, [])
        XCTAssertEqual(telemetry.considered, 0)
        XCTAssertEqual(telemetry.refusedCadence, 0)
        XCTAssertEqual(telemetry.publications, 0)
        XCTAssertNil(telemetry.lastConsideredAt)
    }
}
