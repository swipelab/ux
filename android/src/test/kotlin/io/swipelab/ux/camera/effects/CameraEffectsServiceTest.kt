package io.swipelab.ux.camera.effects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class CameraEffectsServiceTest {
    private lateinit var bridge: FakeCameraTrackBridge
    private lateinit var scheduler: FakeScheduler
    private lateinit var factory: RecordingProcessorFactory
    private lateinit var service: CameraEffectsService
    private lateinit var replies: MutableList<CameraEffectsReply>
    private lateinit var events: MutableList<CameraEffectStatus>

    @Before
    fun setUp() {
        bridge = FakeCameraTrackBridge()
        scheduler = FakeScheduler()
        factory = RecordingProcessorFactory()
        service = CameraEffectsService(
            factory, scheduler, ImmediateDelivery(), CameraCompositeLog(exposes = false),
        )
        service.install(bridge)
        replies = mutableListOf()
        events = mutableListOf()
        service.setStatusObserver { events.add(it) }
    }

    private fun setEffect(
        trackId: String = "t1",
        effect: CameraEffect = CameraEffect.BLUR,
        generation: Int = 1,
    ) = service.reply(
        CameraEffectsRequest.SetEffect(trackId, effect, generation)
    ) { replies.add(it) }

    private fun clear(generation: Int = 2) =
        service.reply(CameraEffectsRequest.Clear(generation)) { replies.add(it) }

    private fun liveAttachment(): FakeCameraTrackBridge.Attachment {
        val live = bridge.live
        assertEquals(1, live.size)
        return live.first()
    }

    @Test
    fun setEffectAttachesOneCallbackAndWithholdsItsReply() {
        setEffect()
        assertEquals(1, bridge.attachCount)
        assertEquals(1, bridge.world.registrations("t1"))
        assertTrue(replies.isEmpty())
        assertEquals(CameraEffectStatus.applying(CameraEffect.BLUR, 1), events.last())
    }

    @Test
    fun aFrameResolvesTheWithheldReplyAndACompositeActivates() {
        setEffect()
        liveAttachment().deliverFrame()?.close()
        assertEquals(listOf<CameraEffectsReply>(CameraEffectsReply.Done), replies)
        assertEquals(CameraEffectStatus.active(CameraEffect.BLUR, 1), events.last())
        assertEquals(CameraEffectStatus.active(CameraEffect.BLUR, 1), service.currentStatus)
    }

    @Test
    fun aSameTrackSwitchDoesNotReattachAndResolvesImmediately() {
        setEffect()
        liveAttachment().deliverFrame()?.close()
        setEffect(effect = CameraEffect.DIM, generation = 2)
        assertEquals(1, bridge.attachCount)
        assertEquals(
            listOf<CameraEffectsReply>(CameraEffectsReply.Done, CameraEffectsReply.Done),
            replies,
        )
        assertEquals(CameraEffectStatus.applying(CameraEffect.DIM, 2), events.last())
        assertEquals(1, factory.made.first().retires)
        assertTrue(factory.made.first().balanced)
        liveAttachment().deliverFrame()?.close()
        assertEquals(CameraEffectStatus.active(CameraEffect.DIM, 2), events.last())
    }

    @Test
    fun aSecondTrackDetachesTheFirstByIdentityAndAttachesTheSecond() {
        setEffect()
        liveAttachment().deliverFrame()?.close()
        setEffect(trackId = "t2", generation = 2)
        assertEquals(2, bridge.attachCount)
        assertEquals(0, bridge.world.registrations("t1"))
        assertEquals(1, bridge.world.registrations("t2"))
        assertEquals(1, factory.made.first().retires)
        assertTrue(factory.made.first().balanced)
    }

    @Test
    fun clearDetachesAndIsIdempotent() {
        setEffect()
        liveAttachment().deliverFrame()?.close()
        clear()
        assertEquals(0, bridge.world.registrations("t1"))
        assertEquals(CameraEffectStatus.idle(2), service.currentStatus)
        assertEquals(1, factory.made.first().retires)
        assertTrue(factory.made.first().balanced)
        val detaches = bridge.detachCount
        clear(generation = 3)
        assertEquals(detaches, bridge.detachCount)
        assertEquals(
            listOf<CameraEffectsReply>(
                CameraEffectsReply.Done, CameraEffectsReply.Done, CameraEffectsReply.Done
            ),
            replies,
        )
    }

    @Test
    fun aSuccessfulClearEmitsNothing() {
        setEffect()
        liveAttachment().deliverFrame()?.close()
        val before = events.size
        clear()
        assertEquals(before, events.size)
        assertEquals(CameraEffectStatus.idle(2), service.currentStatus)
    }

    @Test
    fun theDeadlineFailsTheCommandUndoesTheAttachAndRetractsToIdle() {
        setEffect()
        scheduler.fireLast()
        assertEquals(
            listOf<CameraEffectsReply>(
                CameraEffectsReply.Failure(CameraEffectsFailure.trackNotProcessable)
            ),
            replies,
        )
        assertEquals(0, bridge.world.registrations("t1"))
        assertEquals(CameraEffectStatus.idle(1), events.last())
        assertEquals(1, bridge.detachCount)
        assertEquals(1, factory.made.first().retires)
    }

    @Test
    fun aCallbackBeforeTheDeadlineActivatesOnceAndCancelsIt() {
        setEffect()
        val attachDeadline = scheduler.scheduled.first()
        liveAttachment().deliverFrame()?.close()
        assertTrue(attachDeadline.cancelled)
        liveAttachment().deliverFrame()?.close()
        assertEquals(1, events.count { it.phase == CameraEffectPhase.ACTIVE })
    }

    @Test
    fun activationWaitsForACompositedOutputNotCallbackEntry() {
        setEffect()
        factory.made.first().substitute = true
        liveAttachment().deliverFrame()?.close()
        assertEquals(listOf<CameraEffectsReply>(CameraEffectsReply.Done), replies)
        assertEquals(CameraEffectStatus.applying(CameraEffect.BLUR, 1), events.last())
    }

    @Test
    fun aPersistentlySubstitutingProcessorResolvesApplyingIntoIdle() {
        setEffect()
        factory.made.first().substitute = true
        liveAttachment().deliverFrame()?.close()
        scheduler.fireLast()
        assertEquals(CameraEffectStatus.idle(1), events.last())
        assertEquals(0, bridge.world.registrations("t1"))
        assertEquals(1, factory.made.first().retires)
        assertEquals(1, factory.made.size)
    }

    @Test
    fun aFailedCompositeAfterActivationEmitsProcessingFailedOnce() {
        setEffect()
        liveAttachment().deliverFrame()?.close()
        factory.made.first().substitute = true
        liveAttachment().deliverFrame()?.close()
        liveAttachment().deliverFrame()?.close()
        val failures = events.filter { it.phase == CameraEffectPhase.FAILED }
        assertEquals(1, failures.size)
        assertEquals(CameraEffectStatusCode.PROCESSING_FAILED, failures.first().code)
        assertEquals(CameraEffect.BLUR, failures.first().effect)
    }

    @Test
    fun everyEventCarriesTheLastCommandsGeneration() {
        setEffect(generation = 7)
        liveAttachment().deliverFrame()?.close()
        assertTrue(events.all { it.generation == 7 })
    }

    @Test
    fun availableAnswersTrueOnlyWithACapableHostAndAnInstalledBridge() {
        val flags = mutableListOf<Boolean>()
        service.reply(CameraEffectsRequest.Available) {
            flags.add((it as CameraEffectsReply.Flag).value)
        }
        service.uninstall()
        service.reply(CameraEffectsRequest.Available) {
            flags.add((it as CameraEffectsReply.Flag).value)
        }
        val floorless = CameraEffectsService(
            null, scheduler, ImmediateDelivery(), CameraCompositeLog(exposes = false),
        )
        floorless.install(FakeCameraTrackBridge())
        floorless.reply(CameraEffectsRequest.Available) {
            flags.add((it as CameraEffectsReply.Flag).value)
        }
        assertEquals(listOf(true, false, false), flags)
    }

    @Test
    fun anUnsupportedHostFailsSetEffect() {
        val floorless = CameraEffectsService(
            null, scheduler, ImmediateDelivery(), CameraCompositeLog(exposes = false),
        )
        floorless.install(FakeCameraTrackBridge())
        val got = mutableListOf<CameraEffectsReply>()
        floorless.reply(CameraEffectsRequest.SetEffect("t1", CameraEffect.BLUR, 1)) {
            got.add(it)
        }
        assertEquals(
            listOf<CameraEffectsReply>(
                CameraEffectsReply.Failure(CameraEffectsFailure.unsupported)
            ),
            got,
        )
    }

    @Test
    fun aMissingBridgeDoesNotCreateAProcessor() {
        service.uninstall()

        setEffect()

        assertTrue(factory.made.isEmpty())
        assertEquals(
            listOf<CameraEffectsReply>(
                CameraEffectsReply.Failure(CameraEffectsFailure.integrationUnavailable)
            ),
            replies,
        )
    }

    @Test
    fun aProcessorMadeWhileTheBridgeDisappearsIsRetired() {
        val made = FlippableProcessor()
        lateinit var disappearingService: CameraEffectsService
        val disappearingFactory = object : CameraEffectProcessorFactory {
            override fun makeProcessor(effect: CameraEffect): CameraEffectProcessor {
                disappearingService.uninstall()
                return made
            }
        }
        disappearingService = CameraEffectsService(
            disappearingFactory,
            scheduler,
            ImmediateDelivery(),
            CameraCompositeLog(exposes = false),
        )
        disappearingService.install(FakeCameraTrackBridge())
        val got = mutableListOf<CameraEffectsReply>()

        disappearingService.reply(
            CameraEffectsRequest.SetEffect("t1", CameraEffect.BLUR, 1)
        ) { got.add(it) }

        assertEquals(
            listOf<CameraEffectsReply>(
                CameraEffectsReply.Failure(CameraEffectsFailure.integrationUnavailable)
            ),
            got,
        )
        assertEquals(1, made.retires)
        assertTrue(made.pools.pools.isEmpty())
    }

    @Test
    fun anUnknownTrackFailsWithTrackNotFoundAndRetractsToIdle() {
        bridge.attachException = CameraTrackAttachException(unknownTrack = true)
        setEffect()
        assertEquals(
            listOf<CameraEffectsReply>(
                CameraEffectsReply.Failure(CameraEffectsFailure.trackNotFound)
            ),
            replies,
        )
        assertEquals(CameraEffectStatus.idle(1), events.last())
        assertNull(bridge.live.firstOrNull())
        assertEquals(1, factory.made.first().retires)
        assertTrue(factory.made.first().pools.pools.isEmpty())
    }

    @Test
    fun uninstallingUnderALiveAttachmentFailsOnceAndTearsDown() {
        setEffect()
        liveAttachment().deliverFrame()?.close()
        service.uninstall()
        val failed = events.last()
        assertEquals(CameraEffectPhase.FAILED, failed.phase)
        assertEquals(CameraEffectsFailure.integrationUnavailable.code, failed.code)
        assertEquals(1, bridge.teardownCount)
        assertEquals(0, bridge.world.registrations("t1"))
        assertEquals(1, factory.made.first().retires)
        assertTrue(factory.made.first().balanced)
    }

    @Test
    fun uninstallingUnderAWithheldReplyResolvesItImmediatelyAndRetractsToIdle() {
        setEffect()
        service.uninstall()
        assertEquals(
            listOf<CameraEffectsReply>(
                CameraEffectsReply.Failure(CameraEffectsFailure.integrationUnavailable)
            ),
            replies,
        )
        assertEquals(CameraEffectStatus.idle(1), events.last())
    }

    @Test
    fun installingUnderALiveAttachmentDetachesThroughTheOutgoingBridge() {
        setEffect()
        liveAttachment().deliverFrame()?.close()
        service.install(FakeCameraTrackBridge())
        assertEquals(0, bridge.world.registrations("t1"))
        assertEquals(0, bridge.teardownCount)
        assertEquals(1, factory.made.first().retires)
        assertTrue(factory.made.first().balanced)
    }

    @Test
    fun teardownDetachesAndReleasesTheObserver() {
        setEffect()
        liveAttachment().deliverFrame()?.close()
        service.teardown()
        assertEquals(0, bridge.world.registrations("t1"))
        assertEquals(1, factory.made.first().retires)
        assertTrue(factory.made.first().balanced)
        val eventsBefore = events.size
        clear(generation = 5)
        assertEquals(eventsBefore, events.size)
    }

    @Test
    fun commandsSerializeBehindAWithheldReply() {
        setEffect()
        clear(generation = 2)
        assertTrue(replies.isEmpty())
        assertEquals(1, bridge.world.registrations("t1"))
        assertEquals(0, bridge.detachCount)
        liveAttachment().deliverFrame()?.close()
        assertEquals(
            listOf<CameraEffectsReply>(CameraEffectsReply.Done, CameraEffectsReply.Done),
            replies,
        )
        assertEquals(0, bridge.world.registrations("t1"))
        assertEquals(CameraEffectStatus.idle(2), service.currentStatus)
    }

    @Test
    fun aRepresentableFramePublishesADistinctOwnedFrame() {
        setEffect()
        val source = EffectFrame(width = 64, height = 36, timestampNs = 41)
        val frame = source.frame()

        val published = requireNotNull(liveAttachment().deliverFrame(frame))

        assertEquals(41, published.timestampNs)
        assertEquals(1, source.releases)
        assertTrue(published.planes.dataY !== source.dataY)
        assertTrue(published.planes.dataY.isDirect)
        published.close()
    }

    @Test
    fun aFrameInFlightAcrossASameTrackSwitchPublishesFreshEffectedPixels() {
        setEffect()
        liveAttachment().deliverFrame()?.close()
        val outgoing = factory.made.first()
        outgoing.beforeOutcome = { setEffect(effect = CameraEffect.DIM, generation = 2) }

        val published = requireNotNull(liveAttachment().deliverFrame())

        assertTrue(outgoing.retired)
        assertEquals(100, luma(published.planes, 32, 18))
        published.close()
        assertEquals(CameraEffectStatus.applying(CameraEffect.DIM, 2), events.last())
    }

    @Test
    fun aCompositeFromARetiredProcessorDoesNotActivate() {
        setEffect()
        factory.made.first().beforeOutcome = {
            setEffect(effect = CameraEffect.DIM, generation = 2)
        }
        liveAttachment().deliverFrame()?.close()
        assertFalse(events.any { it.phase == CameraEffectPhase.ACTIVE })
        assertEquals(CameraEffectStatus.applying(CameraEffect.DIM, 2), events.last())
        factory.made.first().beforeOutcome = null
        liveAttachment().deliverFrame()?.close()
        assertEquals(CameraEffectStatus.active(CameraEffect.DIM, 2), events.last())
    }

    @Test
    fun aDetachWhoseTrackWasReplacedReportsTrackReplaced() {
        setEffect()
        liveAttachment().deliverFrame()?.close()
        bridge.world.replaceTrack("t1")
        clear()
        assertEquals(CameraTrackDetachOutcome.TRACK_REPLACED, bridge.outcomes.last())
    }

    @Test
    fun aRetiredCallbackOnAReplacedTrackPublishesAnEffectedFrameAndChangesNoStatus() {
        setEffect()
        val retained = liveAttachment()
        retained.deliverFrame()?.close()
        bridge.world.replaceTrack("t1")
        clear()
        service.uninstall()
        val eventsBefore = events.toList()
        val source = EffectFrame(width = 64, height = 36, timestampNs = 42)

        val published = requireNotNull(retained.deliverFrame(source.frame()))

        assertEquals(42, published.timestampNs)
        assertEquals(100, luma(published.planes, 32, 18))
        assertEquals(1, source.releases)
        published.close()
        assertEquals(eventsBefore, events)
        assertEquals(CameraTrackDetachOutcome.TRACK_REPLACED, bridge.outcomes.last())
        assertEquals(0, bridge.teardownCount)

        bridge.world.removeTrack("t1")
        assertEquals(0, bridge.world.registrations("t1"))
    }

    @Test
    fun aDetachThatFindsTheTrackGoneStillSucceeds() {
        setEffect()
        liveAttachment().deliverFrame()?.close()
        bridge.world.removeTrack("t1")
        clear()
        assertEquals(CameraTrackDetachOutcome.ALREADY_GONE, bridge.outcomes.last())
        assertEquals(CameraEffectStatus.idle(2), service.currentStatus)
    }
}
