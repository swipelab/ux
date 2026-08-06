import XCTest

@testable import ux_macos_core

final class CameraEffectsServiceTests: XCTestCase {
    // MARK: - Attach

    func testSetEffectAttachesOneCallbackAndWithholdsItsReply() {
        let harness = CameraEffectsHarness()

        let reply = harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))

        XCTAssertNil(reply.value)
        XCTAssertEqual(harness.bridge.attachCount, 1)
        XCTAssertEqual(harness.bridge.attachedTracks, ["a"])

        harness.deliverFrame()

        XCTAssertEqual(reply.value, .done)
    }

    func testASameTrackSwitchDoesNotReattachAndResolvesImmediately() {
        let harness = CameraEffectsHarness()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        harness.deliverFrame()

        let reply = harness.send(.setEffect(trackId: "a", effect: .dim, generation: 2))

        XCTAssertEqual(reply.value, .done)
        XCTAssertEqual(harness.bridge.attachCount, 1)
        XCTAssertEqual(harness.bridge.detachCount, 0)
        XCTAssertEqual(harness.fakeProcessors?.requested, [.blur, .dim])
    }

    func testASecondTrackDetachesTheFirstByIdentityAndAttachesTheSecond() {
        let harness = CameraEffectsHarness()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        harness.deliverFrame()
        let first = harness.bridge.live[0]
        XCTAssertTrue(harness.scheduler.armed.isEmpty)

        let reply = harness.send(.setEffect(trackId: "b", effect: .dim, generation: 2))

        XCTAssertNil(reply.value)
        XCTAssertEqual(harness.bridge.detachedIdentities, [ObjectIdentifier(first)])
        XCTAssertEqual(harness.bridge.attachedTracks, ["a", "b"])
        XCTAssertEqual(harness.bridge.live.map(\.trackId), ["b"])
        XCTAssertEqual(harness.scheduler.armed.count, 1)
    }

    // MARK: - Clear

    func testClearDetachesAndIsIdempotent() {
        let harness = CameraEffectsHarness()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        harness.deliverFrame()

        XCTAssertEqual(harness.send(.clear(generation: 2)).value, .done)
        XCTAssertEqual(harness.bridge.detachCount, 1)
        XCTAssertTrue(harness.bridge.live.isEmpty)

        XCTAssertEqual(harness.send(.clear(generation: 3)).value, .done)
        XCTAssertEqual(harness.bridge.detachCount, 1)
    }

    func testClearWithNothingAttachedSucceedsWithoutTouchingTheBridge() {
        let harness = CameraEffectsHarness()

        XCTAssertEqual(harness.send(.clear(generation: 1)).value, .done)
        XCTAssertEqual(harness.bridge.attachCount, 0)
        XCTAssertEqual(harness.bridge.detachCount, 0)
    }

    // MARK: - The attach deadline

    func testTheDeadlineFailsTheCommandUndoesTheAttachAndRetractsToIdle() {
        let harness = CameraEffectsHarness()
        harness.listen()

        let reply = harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))

        XCTAssertEqual(harness.scheduler.armed.first?.delay, 0.75)
        XCTAssertEqual(
            harness.events,
            [.idle(generation: 0), .applying(.blur, generation: 1)]
        )

        harness.scheduler.advance()

        XCTAssertEqual(reply.value, .failure(.trackNotProcessable))
        XCTAssertEqual(harness.bridge.detachCount, 1)
        XCTAssertTrue(harness.bridge.live.isEmpty)
        XCTAssertEqual(
            harness.events,
            [
                .idle(generation: 0),
                .applying(.blur, generation: 1),
                .idle(generation: 1),
            ]
        )
        XCTAssertEqual(harness.service.currentStatus, .idle(generation: 1))
    }

    func testACallbackBeforeTheDeadlineActivatesOnceAndCancelsIt() {
        let harness = CameraEffectsHarness()
        harness.listen()

        let reply = harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        harness.deliverFrame(count: 5)

        XCTAssertEqual(reply.value, .done)
        XCTAssertTrue(harness.scheduler.armed.isEmpty)
        XCTAssertEqual(
            harness.events,
            [
                .idle(generation: 0),
                .applying(.blur, generation: 1),
                .active(.blur, generation: 1),
            ]
        )
    }

    // MARK: - Generations and seeding

    func testEveryEventCarriesTheLastCommandsGeneration() {
        let harness = CameraEffectsHarness()
        harness.listen()

        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 9))
        harness.deliverFrame()

        XCTAssertEqual(
            harness.events,
            [
                .idle(generation: 0),
                .applying(.blur, generation: 9),
                .active(.blur, generation: 9),
            ]
        )
    }

    func testASwitchRestampsWithTheNewGenerationAndReachesActiveAgain() {
        let harness = CameraEffectsHarness()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        harness.deliverFrame()
        harness.listen()

        harness.send(.setEffect(trackId: "a", effect: .dim, generation: 2))
        harness.deliverFrame()

        XCTAssertEqual(
            harness.events,
            [
                .active(.blur, generation: 1),
                .applying(.dim, generation: 2),
                .active(.dim, generation: 2),
            ]
        )
    }

    func testARetiredCallbackIsDropped() {
        let harness = CameraEffectsHarness()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        harness.deliverFrame()
        let retired = harness.bridge.live[0].processing!
        let reply = harness.send(.setEffect(trackId: "b", effect: .dim, generation: 2))
        harness.listen()

        _ = retired(makeCameraFrame())

        XCTAssertNil(reply.value)
        XCTAssertEqual(harness.events, [.applying(.dim, generation: 2)])
    }

    func testListeningSeedsTheCurrentStatusAsTheFirstEvent() {
        let harness = CameraEffectsHarness()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        harness.deliverFrame()

        harness.listen()

        XCTAssertEqual(harness.events, [.active(.blur, generation: 1)])
    }

    func testCancellingThenListeningAgainReseedsWithoutDisturbingTheEffect() {
        let harness = CameraEffectsHarness()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        harness.deliverFrame()
        harness.listen()

        harness.cancelListen()
        harness.deliverFrame(count: 3)
        harness.listen()

        XCTAssertEqual(harness.bridge.live.count, 1)
        XCTAssertEqual(harness.bridge.detachCount, 0)
        XCTAssertEqual(
            harness.events,
            [.active(.blur, generation: 1), .active(.blur, generation: 1)]
        )
    }

    func testTheSeedAfterASuccessfulClearReportsIdle() {
        let harness = CameraEffectsHarness()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        harness.deliverFrame()
        harness.send(.clear(generation: 2))

        harness.listen()

        XCTAssertEqual(harness.events, [.idle(generation: 2)])
    }

    func testASuccessfulClearEmitsNothing() {
        let harness = CameraEffectsHarness()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        harness.deliverFrame()
        harness.listen()

        harness.send(.clear(generation: 2))

        XCTAssertEqual(harness.events, [.active(.blur, generation: 1)])
    }

    // MARK: - Codes

    func testTheCodeTable() {
        let absent = CameraEffectsHarness(installed: false)
        XCTAssertEqual(
            absent.send(.setEffect(trackId: "a", effect: .blur, generation: 1)).value,
            .failure(.integrationUnavailable)
        )
        XCTAssertEqual(absent.send(.available).value, .flag(false))

        let unknown = CameraEffectsHarness()
        unknown.bridge.attachError = CameraTrackAttachFailure.unknownTrack
        XCTAssertEqual(
            unknown.send(.setEffect(trackId: "a", effect: .blur, generation: 1)).value,
            .failure(.trackNotFound)
        )

        let refused = CameraEffectsHarness()
        refused.bridge.attachError = CameraTrackAttachFailure.failed
        XCTAssertEqual(
            refused.send(.setEffect(trackId: "a", effect: .blur, generation: 1)).value,
            .failure(.initializationFailed)
        )

        let processors = FakeEffectProcessors()
        processors.error = FakeProcessorError.standUp
        let unstartable = CameraEffectsHarness(processors: processors)
        XCTAssertEqual(
            unstartable.send(.setEffect(trackId: "a", effect: .blur, generation: 1)).value,
            .failure(.initializationFailed)
        )
        XCTAssertEqual(unstartable.bridge.attachCount, 0)

        let expired = CameraEffectsHarness()
        let expiredReply = expired.send(
            .setEffect(trackId: "a", effect: .blur, generation: 1)
        )
        expired.scheduler.advance()
        XCTAssertEqual(expiredReply.value, .failure(.trackNotProcessable))

        let old = CameraEffectsHarness(processors: nil)
        XCTAssertEqual(
            old.send(.setEffect(trackId: "a", effect: .blur, generation: 1)).value,
            .failure(.unsupported)
        )
        XCTAssertEqual(old.send(.available).value, .flag(false))
        XCTAssertEqual(old.send(.clear(generation: 2)).value, .done)
    }

    func testAvailableAnswersTrueOnlyWithACapableHostAndAnInstalledBridge() {
        XCTAssertEqual(CameraEffectsHarness().send(.available).value, .flag(true))
    }

    // MARK: - Lifecycle edges

    func testUninstallingUnderALiveAttachmentFailsOnceAndLeavesTheNextCommandClean() {
        let harness = CameraEffectsHarness()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        harness.deliverFrame()
        harness.listen()

        harness.service.uninstall()
        harness.service.uninstall()

        XCTAssertEqual(
            harness.events,
            [
                .active(.blur, generation: 1),
                .failed(.blur, generation: 1, code: "integration_unavailable"),
            ]
        )
        XCTAssertEqual(harness.bridge.detachCount, 0)

        XCTAssertEqual(
            harness.send(.setEffect(trackId: "a", effect: .blur, generation: 2)).value,
            .failure(.integrationUnavailable)
        )

        let replacement = FakeCameraTrackBridge()
        harness.service.install(replacement)
        let reply = harness.send(.setEffect(trackId: "a", effect: .blur, generation: 3))
        replacement.live.last?.deliverFrame()

        XCTAssertEqual(reply.value, .done)
        XCTAssertEqual(replacement.attachCount, 1)
    }

    func testUninstallingUnderAWithheldReplyResolvesItImmediatelyAndRetractsToIdle() {
        let harness = CameraEffectsHarness()
        harness.listen()
        let reply = harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))

        harness.service.uninstall()

        XCTAssertEqual(reply.value, .failure(.integrationUnavailable))
        XCTAssertTrue(harness.scheduler.armed.isEmpty)
        XCTAssertEqual(harness.bridge.detachCount, 0)
        XCTAssertEqual(
            harness.events,
            [
                .idle(generation: 0),
                .applying(.blur, generation: 1),
                .idle(generation: 1),
            ]
        )
    }

    func testASwitchWhoseNewAttachThrowsRetractsToIdleAfterTheOldTrackIsDetached() {
        let harness = CameraEffectsHarness()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        harness.deliverFrame()
        let first = harness.bridge.live[0]
        harness.listen()
        harness.bridge.attachError = CameraTrackAttachFailure.failed

        let reply = harness.send(.setEffect(trackId: "b", effect: .dim, generation: 2))

        XCTAssertEqual(reply.value, .failure(.initializationFailed))
        XCTAssertEqual(harness.bridge.detachedIdentities, [ObjectIdentifier(first)])
        XCTAssertTrue(harness.bridge.live.isEmpty)
        XCTAssertTrue(harness.scheduler.armed.isEmpty)
        XCTAssertEqual(
            harness.events,
            [
                .active(.blur, generation: 1),
                .applying(.dim, generation: 2),
                .idle(generation: 2),
            ]
        )
    }

    func testADetachThatFindsTheTrackGoneStillSucceeds() {
        let harness = CameraEffectsHarness()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        harness.deliverFrame()
        harness.listen()
        harness.bridge.lose(harness.bridge.live[0])

        XCTAssertEqual(harness.send(.clear(generation: 2)).value, .done)
        XCTAssertEqual(harness.bridge.detachCount, 1)
        XCTAssertEqual(harness.events, [.active(.blur, generation: 1)])
    }

    func testTeardownDetachesAndReleasesTheObserver() {
        let harness = CameraEffectsHarness()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        harness.deliverFrame()
        harness.listen()

        harness.service.teardown()

        XCTAssertEqual(harness.bridge.detachCount, 1)
        XCTAssertTrue(harness.bridge.live.isEmpty)
        XCTAssertEqual(harness.events, [.active(.blur, generation: 1)])
    }

    func testCommandsSerializeBehindAWithheldReply() {
        let harness = CameraEffectsHarness()

        let first = harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        let second = harness.send(.clear(generation: 2))

        XCTAssertNil(first.value)
        XCTAssertNil(second.value)
        XCTAssertEqual(harness.bridge.attachCount, 1)

        harness.deliverFrame()

        XCTAssertEqual(first.value, .done)
        XCTAssertEqual(second.value, .done)
        XCTAssertEqual(harness.bridge.detachCount, 1)
    }

    func testEveryFlutterFacingContinuationArrivesOnTheMainQueue() {
        let bridge = FakeCameraTrackBridge()
        let service = CameraEffectsService(
            processors: PassthroughEffectProcessors(),
            scheduler: FakeCameraEffectsScheduler(),
            delivery: MainQueueDelivery()
        )
        service.install(bridge)

        let observed = expectation(description: "status events")
        observed.expectedFulfillmentCount = 2
        var eventThreads: [Bool] = []
        service.setStatusObserver { _ in
            eventThreads.append(Thread.isMainThread)
            observed.fulfill()
        }

        let completed = expectation(description: "command reply")
        var replyOnMainQueue = false
        service.reply(to: .setEffect(trackId: "a", effect: .blur, generation: 1)) { _ in
            replyOnMainQueue = Thread.isMainThread
            completed.fulfill()
        }

        let attachment = bridge.live[0]
        DispatchQueue.global().async { attachment.deliverFrame() }

        wait(for: [observed, completed], timeout: 5)
        XCTAssertEqual(eventThreads, [true, true])
        XCTAssertTrue(replyOnMainQueue)
    }
}
