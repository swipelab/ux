import CoreGraphics
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

    func testAMissingBridgeBuildsNoProcessor() {
        let harness = CameraEffectsHarness(installed: false)

        let reply = harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))

        XCTAssertEqual(reply.value, .failure(.integrationUnavailable))
        XCTAssertEqual(harness.fakeProcessors?.requested, [])
    }

    func testAProcessorBuiltWhileTheBridgeDisappearsIsRetired() {
        let processors = DisappearingBridgeProcessors()
        let harness = CameraEffectsHarness(processors: processors)
        processors.service = harness.service

        let reply = harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))

        XCTAssertEqual(reply.value, .failure(.integrationUnavailable))
        XCTAssertEqual(processors.processor.retireCount, 1)
    }

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
        XCTAssertEqual(harness.bridge.detachCount, 1)
        XCTAssertEqual(harness.bridge.teardownCount, 1)
        XCTAssertTrue(harness.bridge.live.isEmpty)

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

    func testABridgeSwapLeavesOneRegistrationOnTheTrackThroughout() {
        let world = FakeTrackWorld()
        let harness = CameraEffectsHarness(world: world)
        harness.send(.setEffect(trackId: "t", effect: .blur, generation: 1))
        harness.deliverFrame()

        XCTAssertEqual(world.registrations(on: "t"), 1)

        harness.service.uninstall()

        XCTAssertEqual(world.registrations(on: "t"), 0)
        XCTAssertEqual(harness.bridge.detachCount, 1)
        XCTAssertEqual(harness.bridge.outcomes, [.removed])

        let replacement = FakeCameraTrackBridge(world: world)
        harness.service.install(replacement)
        let reply = harness.send(.setEffect(trackId: "t", effect: .blur, generation: 2))
        replacement.live.last?.deliverFrame()

        XCTAssertEqual(reply.value, .done)
        XCTAssertEqual(replacement.attachCount, 1)
        XCTAssertEqual(world.registrations(on: "t"), 1)
    }

    func testInstallingUnderALiveAttachmentDetachesThroughTheOutgoingBridge() {
        let world = FakeTrackWorld()
        let harness = CameraEffectsHarness(world: world)
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        harness.deliverFrame()
        let outgoing = harness.bridge.live[0]

        let replacement = FakeCameraTrackBridge(world: world)
        harness.service.install(replacement)

        XCTAssertEqual(harness.bridge.detachedIdentities, [ObjectIdentifier(outgoing)])
        XCTAssertEqual(harness.bridge.teardownCount, 0)
        XCTAssertEqual(replacement.detachCount, 0)
        XCTAssertEqual(world.registrations(on: "a"), 0)
    }

    func testUninstallTearsDownAfterTheDetachAndNotAtAllWithNothingAttached() {
        let harness = CameraEffectsHarness()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        harness.deliverFrame()

        harness.service.uninstall()

        XCTAssertEqual(harness.bridge.calls, [.attach("a"), .detach("a"), .teardown])

        let idle = CameraEffectsHarness()

        idle.service.uninstall()

        XCTAssertEqual(idle.bridge.calls, [])
    }

    func testTheAttachmentCarriesItsTrackIdAndDetachResolvesTheTrackFromIt() {
        let harness = CameraEffectsHarness()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        harness.deliverFrame()

        XCTAssertEqual(harness.bridge.live[0].trackId, "a")
        XCTAssertEqual(harness.world.registrations(on: "a"), 1)

        harness.send(.clear(generation: 2))

        XCTAssertEqual(harness.bridge.calls, [.attach("a"), .detach("a")])
        XCTAssertEqual(harness.bridge.outcomes, [.removed])
        XCTAssertEqual(harness.world.registrations(on: "a"), 0)
    }

    func testADetachWhoseTrackWasReplacedSucceedsAsAnAlreadyGoneOneDoes() {
        let harness = CameraEffectsHarness()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        harness.deliverFrame()
        harness.listen()
        harness.world.replaceTrack("a")

        XCTAssertEqual(harness.send(.clear(generation: 2)).value, .done)
        XCTAssertEqual(harness.bridge.outcomes, [.trackReplaced])
        XCTAssertEqual(harness.events, [.active(.blur, generation: 1)])
        XCTAssertEqual(harness.service.currentStatus, .idle(generation: 2))

        let reply = harness.send(.setEffect(trackId: "a", effect: .dim, generation: 3))
        harness.deliverFrame()

        XCTAssertEqual(reply.value, .done)
        XCTAssertEqual(harness.world.registrations(on: "a"), 1)
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

    // MARK: - Frames

    func testAFrameRoundTripsThroughProcessingWithEveryFieldIntact() {
        let harness = CameraEffectsHarness(processors: RebuildingEffectProcessors())
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        let sent = makeCameraFrame(
            crop: CGRect(x: 4, y: 6, width: 640, height: 360),
            adaptedWidth: 320,
            adaptedHeight: 180,
            rotation: .degrees270,
            timestampNs: 123_456_789,
            timestamp90kHz: 900_090
        )

        let published = harness.bridge.live[0].deliverFrame(sent)

        XCTAssertTrue(published?.pixelBuffer === sent.pixelBuffer)
        XCTAssertEqual(published?.crop, sent.crop)
        XCTAssertEqual(published?.adaptedWidth, 320)
        XCTAssertEqual(published?.adaptedHeight, 180)
        XCTAssertEqual(published?.rotation, .degrees270)
        XCTAssertEqual(published?.timestampNs, 123_456_789)
        XCTAssertEqual(published?.timestamp90kHz, 900_090)
    }

    func testTheFourQuarterTurnsAreTheOnlyFrameRotations() {
        XCTAssertEqual(CameraFrameRotation(rawValue: 0), .degrees0)
        XCTAssertEqual(CameraFrameRotation(rawValue: 90), .degrees90)
        XCTAssertEqual(CameraFrameRotation(rawValue: 180), .degrees180)
        XCTAssertEqual(CameraFrameRotation(rawValue: 270), .degrees270)
        XCTAssertNil(CameraFrameRotation(rawValue: 45))
        XCTAssertNil(CameraFrameRotation(rawValue: 360))
        XCTAssertNil(CameraFrameRotation(rawValue: -90))
    }

    func testFramesTheBridgeCannotPresentNeverReachProcessingAndTheAttachExpires() {
        let harness = CameraEffectsHarness()
        harness.listen()
        let reply = harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        let attachment = harness.bridge.live[0]

        for _ in 0..<3 { attachment.forwardUnprocessedFrame() }
        harness.scheduler.advance()

        XCTAssertEqual(attachment.unprocessedFrames, 3)
        XCTAssertEqual(reply.value, .failure(.trackNotProcessable))
        XCTAssertEqual(harness.world.registrations(on: "a"), 0)
        XCTAssertEqual(
            harness.events,
            [
                .idle(generation: 0),
                .applying(.blur, generation: 1),
                .idle(generation: 1),
            ]
        )
    }

    // MARK: - Activation and outcomes

    func testActivationWaitsForACompositedOutputNotCallbackEntry() {
        let harness = CameraEffectsHarness()
        harness.listen()
        let reply = harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        let processor = harness.fakeProcessors!.last!
        processor.answer = .substitute

        harness.deliverFrame(count: 3)

        XCTAssertEqual(reply.value, .done)
        XCTAssertEqual(
            harness.events,
            [.idle(generation: 0), .applying(.blur, generation: 1)]
        )
        XCTAssertEqual(harness.service.currentStatus, .applying(.blur, generation: 1))

        processor.answer = .composite
        harness.deliverFrame()

        XCTAssertEqual(harness.events.last, .active(.blur, generation: 1))
        XCTAssertEqual(harness.service.currentStatus, .active(.blur, generation: 1))
    }

    func testCallbackEntryAloneSatisfiesTheAttachGuard() {
        let harness = CameraEffectsHarness()
        harness.listen()
        let reply = harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        let processor = harness.fakeProcessors!.last!
        processor.answer = .substitute
        XCTAssertEqual(harness.scheduler.armed.first?.delay, 0.75)

        harness.deliverFrame()

        XCTAssertEqual(reply.value, .done)
        XCTAssertEqual(harness.scheduler.scheduled.count, 2)
        XCTAssertTrue(harness.scheduler.scheduled[0].cancelled)
        XCTAssertEqual(harness.scheduler.armed.count, 1)
        XCTAssertEqual(harness.scheduler.armed.first?.delay, 0.75)
        XCTAssertEqual(
            harness.events,
            [.idle(generation: 0), .applying(.blur, generation: 1)]
        )
    }

    func testAFailedCompositeAfterActivationEmitsProcessingFailedOncePerRecord() {
        let harness = CameraEffectsHarness()
        harness.listen()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        let first = harness.fakeProcessors!.last!
        harness.deliverFrame()

        first.answer = .substitute
        harness.deliverFrame(count: 3)

        harness.send(.setEffect(trackId: "a", effect: .dim, generation: 2))
        XCTAssertEqual(first.retireCount, 1)
        let second = harness.fakeProcessors!.last!
        harness.deliverFrame()

        second.answer = .substitute
        harness.deliverFrame(count: 2)

        XCTAssertEqual(
            harness.events,
            [
                .idle(generation: 0),
                .applying(.blur, generation: 1),
                .active(.blur, generation: 1),
                .failed(.blur, generation: 1, code: "processing_failed"),
                .applying(.dim, generation: 2),
                .active(.dim, generation: 2),
                .failed(.dim, generation: 2, code: "processing_failed"),
            ]
        )
    }

    func testAPersistentlySubstitutingProcessorResolvesApplyingIntoIdle() {
        let harness = CameraEffectsHarness()
        harness.listen()
        let reply = harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        let processor = harness.fakeProcessors!.last!
        processor.answer = .substitute
        harness.deliverFrame(count: 3)
        XCTAssertEqual(reply.value, .done)

        harness.scheduler.advance()

        XCTAssertEqual(harness.bridge.detachCount, 1)
        XCTAssertTrue(harness.bridge.live.isEmpty)
        XCTAssertEqual(processor.retireCount, 1)
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

    func testTheAttachGuardAloneOwnsTheNoFrameOutcome() {
        let harness = CameraEffectsHarness()
        harness.listen()
        let reply = harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        XCTAssertEqual(harness.scheduler.scheduled.count, 1)

        harness.scheduler.advance()

        XCTAssertEqual(reply.value, .failure(.trackNotProcessable))
        XCTAssertEqual(harness.scheduler.scheduled.count, 1)
        XCTAssertEqual(
            harness.events,
            [
                .idle(generation: 0),
                .applying(.blur, generation: 1),
                .idle(generation: 1),
            ]
        )
    }

    func testASameTrackSwitchSupersedesThePendingApplyingDeadline() {
        let harness = CameraEffectsHarness()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        let first = harness.fakeProcessors!.last!
        first.answer = .substitute
        harness.deliverFrame()
        XCTAssertEqual(harness.scheduler.armed.count, 1)
        let superseded = harness.scheduler.armed[0]

        harness.send(.setEffect(trackId: "a", effect: .dim, generation: 2))

        XCTAssertTrue(superseded.cancelled)
        XCTAssertEqual(harness.scheduler.armed.count, 1)

        harness.deliverFrame()

        XCTAssertTrue(harness.scheduler.armed.isEmpty)

        harness.scheduler.advance()

        XCTAssertEqual(harness.bridge.live.count, 1)
        XCTAssertEqual(harness.service.currentStatus, .active(.dim, generation: 2))
    }

    func testASwitchWhoseTrackGoesSilentStillResolvesToIdle() {
        let harness = CameraEffectsHarness()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        harness.deliverFrame()
        harness.listen()

        let reply = harness.send(.setEffect(trackId: "a", effect: .dim, generation: 2))

        XCTAssertEqual(reply.value, .done)
        XCTAssertEqual(harness.scheduler.armed.count, 1)
        XCTAssertEqual(harness.scheduler.armed.first?.delay, 0.75)
        let processor = harness.fakeProcessors!.last!

        harness.scheduler.advance()

        XCTAssertEqual(harness.bridge.detachCount, 1)
        XCTAssertTrue(harness.bridge.live.isEmpty)
        XCTAssertEqual(processor.retireCount, 1)
        XCTAssertEqual(
            harness.events,
            [
                .active(.blur, generation: 1),
                .applying(.dim, generation: 2),
                .idle(generation: 2),
            ]
        )
        XCTAssertEqual(harness.service.currentStatus, .idle(generation: 2))
    }

    func testACompositeFromARetiredProcessorDoesNotActivate() {
        let first = FakeEffectProcessor()
        let second = FakeEffectProcessor()
        let processors = FakeEffectProcessors()
        processors.prepared = [first, second]
        let harness = CameraEffectsHarness(processors: processors)
        harness.listen()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        first.hold()
        let attachment = harness.bridge.live[0]
        let returned = expectation(description: "held frame returns")
        DispatchQueue.global().async {
            attachment.deliverFrame()
            returned.fulfill()
        }
        XCTAssertTrue(first.waitForFrames(1))

        XCTAssertEqual(
            harness.send(.setEffect(trackId: "a", effect: .dim, generation: 2)).value,
            .done
        )
        first.release()
        wait(for: [returned], timeout: 5)

        XCTAssertEqual(harness.service.currentStatus, .applying(.dim, generation: 2))

        harness.deliverFrame()

        XCTAssertEqual(
            harness.events,
            [
                .idle(generation: 0),
                .applying(.blur, generation: 1),
                .applying(.dim, generation: 2),
                .active(.dim, generation: 2),
            ]
        )
    }

    func testASubstitutionFromARetiredProcessorDoesNotSpendTheFailOnce() {
        let first = FakeEffectProcessor()
        let second = FakeEffectProcessor()
        let processors = FakeEffectProcessors()
        processors.prepared = [first, second]
        let harness = CameraEffectsHarness(processors: processors)
        harness.listen()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        harness.deliverFrame()
        first.answer = .substitute
        first.hold()
        let attachment = harness.bridge.live[0]
        let returned = expectation(description: "held frame returns")
        DispatchQueue.global().async {
            attachment.deliverFrame()
            returned.fulfill()
        }
        XCTAssertTrue(first.waitForFrames(2))

        harness.send(.setEffect(trackId: "a", effect: .dim, generation: 2))
        harness.deliverFrame()
        first.release()
        wait(for: [returned], timeout: 5)

        XCTAssertEqual(
            harness.events,
            [
                .idle(generation: 0),
                .applying(.blur, generation: 1),
                .active(.blur, generation: 1),
                .applying(.dim, generation: 2),
                .active(.dim, generation: 2),
            ]
        )

        second.answer = .substitute
        harness.deliverFrame()

        XCTAssertEqual(
            harness.events.last,
            .failed(.dim, generation: 2, code: "processing_failed")
        )
        XCTAssertEqual(harness.events.filter { $0.phase == .failed }.count, 1)
    }

    func testClearRetiresTheProcessor() {
        let harness = CameraEffectsHarness()
        harness.send(.setEffect(trackId: "a", effect: .blur, generation: 1))
        let processor = harness.fakeProcessors!.last!
        harness.deliverFrame()

        harness.send(.clear(generation: 2))

        XCTAssertEqual(processor.retireCount, 1)
    }

    // MARK: - Threading

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
