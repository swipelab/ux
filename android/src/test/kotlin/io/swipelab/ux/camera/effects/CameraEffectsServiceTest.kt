package io.swipelab.ux.camera.effects

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
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
        service = CameraEffectsService(factory, scheduler, ImmediateDelivery())
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
        liveAttachment().deliverFrame()
        assertEquals(listOf<CameraEffectsReply>(CameraEffectsReply.Done), replies)
        assertEquals(CameraEffectStatus.active(CameraEffect.BLUR, 1), events.last())
        assertEquals(CameraEffectStatus.active(CameraEffect.BLUR, 1), service.currentStatus)
    }

    @Test
    fun aSameTrackSwitchDoesNotReattachAndResolvesImmediately() {
        setEffect()
        liveAttachment().deliverFrame()
        setEffect(effect = CameraEffect.DIM, generation = 2)
        assertEquals(1, bridge.attachCount)
        assertEquals(
            listOf<CameraEffectsReply>(CameraEffectsReply.Done, CameraEffectsReply.Done),
            replies,
        )
        assertEquals(CameraEffectStatus.applying(CameraEffect.DIM, 2), events.last())
        assertTrue(factory.made.first().retired)
        liveAttachment().deliverFrame()
        assertEquals(CameraEffectStatus.active(CameraEffect.DIM, 2), events.last())
    }

    @Test
    fun aSecondTrackDetachesTheFirstByIdentityAndAttachesTheSecond() {
        setEffect()
        liveAttachment().deliverFrame()
        setEffect(trackId = "t2", generation = 2)
        assertEquals(2, bridge.attachCount)
        assertEquals(0, bridge.world.registrations("t1"))
        assertEquals(1, bridge.world.registrations("t2"))
        assertTrue(factory.made.first().retired)
    }

    @Test
    fun clearDetachesAndIsIdempotent() {
        setEffect()
        liveAttachment().deliverFrame()
        clear()
        assertEquals(0, bridge.world.registrations("t1"))
        assertEquals(CameraEffectStatus.idle(2), service.currentStatus)
        assertTrue(factory.made.first().retired)
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
        liveAttachment().deliverFrame()
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
        assertTrue(factory.made.first().retired)
    }

    @Test
    fun aCallbackBeforeTheDeadlineActivatesOnceAndCancelsIt() {
        setEffect()
        val attachDeadline = scheduler.scheduled.first()
        liveAttachment().deliverFrame()
        assertTrue(attachDeadline.cancelled)
        liveAttachment().deliverFrame()
        assertEquals(1, events.count { it.phase == CameraEffectPhase.ACTIVE })
    }

    @Test
    fun activationWaitsForACompositedOutputNotCallbackEntry() {
        setEffect()
        factory.made.first().substitute = true
        liveAttachment().deliverFrame()
        assertEquals(listOf<CameraEffectsReply>(CameraEffectsReply.Done), replies)
        assertEquals(CameraEffectStatus.applying(CameraEffect.BLUR, 1), events.last())
    }

    @Test
    fun aPersistentlySubstitutingProcessorResolvesApplyingIntoIdle() {
        setEffect()
        factory.made.first().substitute = true
        liveAttachment().deliverFrame()
        scheduler.fireLast()
        assertEquals(CameraEffectStatus.idle(1), events.last())
        assertEquals(0, bridge.world.registrations("t1"))
        assertTrue(factory.made.first().retired)
    }

    @Test
    fun aFailedCompositeAfterActivationEmitsProcessingFailedOnce() {
        setEffect()
        liveAttachment().deliverFrame()
        factory.made.first().substitute = true
        liveAttachment().deliverFrame()
        liveAttachment().deliverFrame()
        val failures = events.filter { it.phase == CameraEffectPhase.FAILED }
        assertEquals(1, failures.size)
        assertEquals(CameraEffectStatusCode.PROCESSING_FAILED, failures.first().code)
        assertEquals(CameraEffect.BLUR, failures.first().effect)
    }

    @Test
    fun everyEventCarriesTheLastCommandsGeneration() {
        setEffect(generation = 7)
        liveAttachment().deliverFrame()
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
        val floorless = CameraEffectsService(null, scheduler, ImmediateDelivery())
        floorless.install(FakeCameraTrackBridge())
        floorless.reply(CameraEffectsRequest.Available) {
            flags.add((it as CameraEffectsReply.Flag).value)
        }
        assertEquals(listOf(true, false, false), flags)
    }

    @Test
    fun anUnsupportedHostFailsSetEffect() {
        val floorless = CameraEffectsService(null, scheduler, ImmediateDelivery())
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
    }

    @Test
    fun uninstallingUnderALiveAttachmentFailsOnceAndTearsDown() {
        setEffect()
        liveAttachment().deliverFrame()
        service.uninstall()
        val failed = events.last()
        assertEquals(CameraEffectPhase.FAILED, failed.phase)
        assertEquals(CameraEffectsFailure.integrationUnavailable.code, failed.code)
        assertEquals(1, bridge.teardownCount)
        assertEquals(0, bridge.world.registrations("t1"))
        assertTrue(factory.made.first().retired)
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
        liveAttachment().deliverFrame()
        service.install(FakeCameraTrackBridge())
        assertEquals(0, bridge.world.registrations("t1"))
        assertEquals(0, bridge.teardownCount)
        assertTrue(factory.made.first().retired)
    }

    @Test
    fun teardownDetachesAndReleasesTheObserver() {
        setEffect()
        liveAttachment().deliverFrame()
        service.teardown()
        assertEquals(0, bridge.world.registrations("t1"))
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
        liveAttachment().deliverFrame()
        assertEquals(
            listOf<CameraEffectsReply>(CameraEffectsReply.Done, CameraEffectsReply.Done),
            replies,
        )
        assertEquals(0, bridge.world.registrations("t1"))
        assertEquals(CameraEffectStatus.idle(2), service.currentStatus)
    }

    @Test
    fun aFrameRoundTripsThroughProcessingUntouched() {
        setEffect()
        val frame = makeCameraFrame(timestampNs = 41)
        val published = liveAttachment().deliverFrame(frame)
        assertSame(frame, published)
    }

    @Test
    fun aCompositeFromARetiredProcessorDoesNotActivate() {
        setEffect()
        factory.made.first().beforeOutcome = {
            setEffect(effect = CameraEffect.DIM, generation = 2)
        }
        liveAttachment().deliverFrame()
        assertFalse(events.any { it.phase == CameraEffectPhase.ACTIVE })
        assertEquals(CameraEffectStatus.applying(CameraEffect.DIM, 2), events.last())
        factory.made.first().beforeOutcome = null
        liveAttachment().deliverFrame()
        assertEquals(CameraEffectStatus.active(CameraEffect.DIM, 2), events.last())
    }

    @Test
    fun aDetachWhoseTrackWasReplacedReportsTrackReplaced() {
        setEffect()
        liveAttachment().deliverFrame()
        bridge.world.replaceTrack("t1")
        clear()
        assertEquals(CameraTrackDetachOutcome.TRACK_REPLACED, bridge.outcomes.last())
    }

    @Test
    fun aDetachThatFindsTheTrackGoneStillSucceeds() {
        setEffect()
        liveAttachment().deliverFrame()
        bridge.world.removeTrack("t1")
        clear()
        assertEquals(CameraTrackDetachOutcome.ALREADY_GONE, bridge.outcomes.last())
        assertEquals(CameraEffectStatus.idle(2), service.currentStatus)
    }
}
