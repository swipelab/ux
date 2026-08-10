package io.swipelab.ux.camera.effects

import java.nio.FloatBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

private const val MASK_WIDTH = 160
private const val MASK_HEIGHT = 90

private const val TARGET = PersonMaskProducer.TARGET_SUBMISSION_INTERVAL_NANOS

private fun personMaskPixels(): PersonMaskPixels {
    val confidence = FloatBuffer.allocate(MASK_WIDTH * MASK_HEIGHT)
    for (row in 20 until 60) {
        for (column in 30 until 80) {
            confidence.put(row * MASK_WIDTH + column, 1f)
        }
    }
    return PersonMaskPixels(MASK_WIDTH, MASK_HEIGHT, confidence)
}

class CameraCompositeTelemetryTest {
    private val executor = ManualExecutor()
    private val clock = TestClock()
    private val segmenter = ScriptedSegmenter(mask = ::personMaskPixels)
    private val emptySegmenter = ScriptedSegmenter()

    private fun makeProducer(from: ScriptedSegmenter = segmenter) = PersonMaskProducer(
        from,
        PersonMaskInputPool(
            PersonMaskProducer.INPUT_WIDTH,
            PersonMaskProducer.INPUT_HEIGHT,
            PersonMaskProducer.INPUT_BUFFER_COUNT,
        ),
        clock,
        executor,
    )

    private fun frameAt(
        timestampNs: Long,
        width: Int = 320,
        height: Int = 180,
    ): CameraFrame = EffectFrame(width, height, timestampNs = timestampNs).frame()

    /** Runs one frame through so the producer publishes, and opens the cadence gate. */
    private fun publishAMask(processor: CameraEffectProcessor, timestampNs: Long) {
        processor.process(frameAt(timestampNs)).frame.close()
        assertTrue(executor.runNext())
        clock.advance(TARGET)
    }

    private fun composited(outcome: CameraFrameOutcome): CompositeOutcome.Composited =
        outcome.outcome as CompositeOutcome.Composited

    @Test
    fun aFrameCompositedUnderAPublishedMaskIsRecordedUsed() {
        val producer = makeProducer()
        val processor = CompositingEffectProcessor(
            CameraEffectCompositor(CameraEffect.DIM), producer,
        )
        publishAMask(processor, timestampNs = 100)

        val outcome = processor.process(frameAt(200))

        assertEquals(CameraCompositeUse.Used, outcome.use)
        assertEquals(100L, outcome.mask?.sourceTimestampNs)
        assertNull(composited(outcome).maskRejection)
        outcome.frame.close()
    }

    @Test
    fun aFrameArrivingBeforeAnyMaskIsRecordedMaskless() {
        val processor = CompositingEffectProcessor(
            CameraEffectCompositor(CameraEffect.DIM), makeProducer(),
        )

        val outcome = processor.process(frameAt(100))

        assertEquals(CameraCompositeUse.Maskless, outcome.use)
        assertNull(outcome.mask)
        outcome.frame.close()
    }

    @Test
    fun aStructurallyInapplicableMaskIsRecordedRejectedWithItsReason() {
        val processor = CompositingEffectProcessor(
            CameraEffectCompositor(CameraEffect.DIM), makeProducer(emptySegmenter),
        )
        publishAMask(processor, timestampNs = 100)

        val outcome = processor.process(frameAt(200))

        assertEquals(CameraCompositeUse.Rejected(CameraMaskRejection.EMPTY), outcome.use)
        assertEquals(100L, outcome.mask?.sourceTimestampNs)
        outcome.frame.close()
    }

    @Test
    fun aSubstituteIsRecordedWithTheHeldFrameItPublished() {
        val pools = ScriptedBufferPools()
        val processor = CompositingEffectProcessor(
            CameraEffectCompositor(CameraEffect.DIM, pools), makeProducer(),
        )

        pools.allocationsFail = true
        val black = processor.process(frameAt(100))
        black.frame.close()
        pools.allocationsFail = false
        processor.process(frameAt(200)).frame.close()
        pools.allocationsFail = true
        val lastGood = processor.process(frameAt(300))

        assertEquals(
            CameraCompositeUse.Substituted(
                CameraCompositeSubstitution.POOL_UNAVAILABLE,
                CameraCompositeSubstitute.BLACK,
            ),
            black.use,
        )
        assertEquals(
            CameraCompositeUse.Substituted(
                CameraCompositeSubstitution.POOL_UNAVAILABLE,
                CameraCompositeSubstitute.LAST_GOOD,
            ),
            lastGood.use,
        )
        lastGood.frame.close()
    }

    @Test
    fun theReportedMaskIsTheObjectTheCompositeWasHanded() {
        val producer = makeProducer()
        val handed = mutableListOf<CameraMask?>()
        val compositor = object : CameraCompositing {
            private val delegate = CameraEffectCompositor(CameraEffect.DIM)

            override fun composite(frame: CameraFrame, mask: CameraMask?): CompositeOutcome {
                handed.add(mask)
                executor.runNext()
                return delegate.composite(frame, mask)
            }

            override fun retire() = delegate.retire()
        }
        val processor = CompositingEffectProcessor(compositor, producer)

        processor.process(frameAt(100)).frame.close()
        clock.advance(TARGET)
        val outcome = processor.process(frameAt(200))

        assertNotNull(outcome.mask)
        assertSame(handed.last(), outcome.mask)
        assertEquals(100L, outcome.mask?.sourceTimestampNs)
        assertNotSame(producer.mask, outcome.mask)
        assertEquals(200L, producer.mask?.sourceTimestampNs)
        outcome.frame.close()
    }

    @Test
    fun theMaskOnlyStageRecordsAnApplicableSnapshotUsedWithoutCompositingIt() {
        val processor = StagedEffectProcessor(
            CameraEffectCompositor(CameraEffect.NONE), makeProducer(),
        )
        publishAMask(processor, timestampNs = 100)

        val outcome = processor.process(frameAt(200))

        assertEquals(CameraCompositeUse.Used, outcome.use)
        assertEquals(100L, outcome.mask?.sourceTimestampNs)
        assertEquals(1f, composited(outcome).background.fraction(4, 8), 0f)
        outcome.frame.close()
    }

    @Test
    fun theMaskOnlyStageRecordsAnInapplicableSnapshotRejected() {
        val processor = StagedEffectProcessor(
            CameraEffectCompositor(CameraEffect.NONE), makeProducer(emptySegmenter),
        )
        publishAMask(processor, timestampNs = 100)

        val outcome = processor.process(frameAt(200))

        assertEquals(CameraCompositeUse.Rejected(CameraMaskRejection.EMPTY), outcome.use)
        outcome.frame.close()
    }

    @Test
    fun thePassthroughStageRecordsEveryFrameMaskless() {
        val processor = StagedEffectProcessor(CameraEffectCompositor(CameraEffect.NONE), null)

        val outcome = processor.process(frameAt(100))

        assertEquals(CameraCompositeUse.Maskless, outcome.use)
        assertNull(outcome.mask)
        outcome.frame.close()
    }

    private inner class CompositingFactory : CameraEffectProcessorFactory {
        override fun makeProcessor(effect: CameraEffect): CameraEffectProcessor =
            CompositingEffectProcessor(CameraEffectCompositor(effect), makeProducer())
    }

    private fun serve(log: CameraCompositeLog): FakeCameraTrackBridge.Attachment {
        val bridge = FakeCameraTrackBridge()
        val service = CameraEffectsService(
            CompositingFactory(), FakeScheduler(), ImmediateDelivery(), log,
        )
        service.install(bridge)
        service.reply(CameraEffectsRequest.SetEffect("t1", CameraEffect.DIM, 7)) {}
        return bridge.live.single()
    }

    @Test
    fun everyRecordIsKeyedByTheEffectGenerationAndItsFramesTimestamp() {
        val log = CameraCompositeLog(exposes = true)

        val attachment = serve(log)
        for (timestampNs in listOf(10L, 20L, 30L)) {
            attachment.deliverFrame(frameAt(timestampNs))?.close()
        }

        assertEquals(
            listOf(7 to 10L, 7 to 20L, 7 to 30L),
            log.records().map { it.generation to it.frameTimestampNs },
        )
        assertEquals(
            listOf<CameraCompositeUse>(
                CameraCompositeUse.Maskless,
                CameraCompositeUse.Maskless,
                CameraCompositeUse.Maskless,
            ),
            log.records().map { it.use },
        )
        assertNotNull(log.records().last().background)
    }

    @Test
    fun aMaskedRecordCarriesTheTimestampOfTheFrameItsMaskWasInferredFrom() {
        val log = CameraCompositeLog(exposes = true)

        val attachment = serve(log)
        attachment.deliverFrame(frameAt(10))?.close()
        assertTrue(executor.runNext())
        clock.advance(TARGET)
        attachment.deliverFrame(frameAt(20))?.close()

        assertEquals(listOf(null, 10L), log.records().map { it.maskFrameTimestampNs })
        assertEquals(
            listOf<CameraCompositeUse>(CameraCompositeUse.Maskless, CameraCompositeUse.Used),
            log.records().map { it.use },
        )
    }

    @Test
    fun sustainedFramesLeaveTheLogAtItsCapacityHoldingTheNewest() {
        val log = CameraCompositeLog(exposes = true, capacity = 8)

        val attachment = serve(log)
        for (timestampNs in 1L..40L) attachment.deliverFrame(frameAt(timestampNs))?.close()

        assertEquals(8, log.records().size)
        assertEquals((33L..40L).toList(), log.records().map { it.frameTimestampNs })
    }

    @Test
    fun aLogThatDoesNotExposeHoldsNothingUnderSustainedFrames() {
        val log = CameraCompositeLog(exposes = false)

        val attachment = serve(log)
        for (timestampNs in 1L..40L) attachment.deliverFrame(frameAt(timestampNs))?.close()

        assertTrue(log.records().isEmpty())
    }
}
