package io.swipelab.ux.camera.effects

import java.nio.ByteBuffer
import java.nio.FloatBuffer
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

private const val MASK_WIDTH = 160
private const val MASK_HEIGHT = 90

/** The grid stretches onto the whole frame, so the person lands at twice these. */
private fun personMaskPixels(): PersonMaskPixels {
    val confidence = FloatBuffer.allocate(MASK_WIDTH * MASK_HEIGHT)
    for (row in 20 until 60) {
        for (column in 30 until 80) {
            confidence.put(row * MASK_WIDTH + column, 1f)
        }
    }
    return PersonMaskPixels(MASK_WIDTH, MASK_HEIGHT, confidence)
}

class CameraEffectProcessorsTest {
    private val executor = ManualExecutor()
    private val clock = TestClock()
    private val cadence = CameraThermalCadence(clock)
    private val segmenter = ScriptedSegmenter(mask = ::personMaskPixels)

    private fun makeProducer() = PersonMaskProducer(
        segmenter,
        PersonMaskInputPool(
            PersonMaskProducer.INPUT_WIDTH,
            PersonMaskProducer.INPUT_HEIGHT,
            PersonMaskProducer.INPUT_BUFFER_COUNT,
        ),
        clock,
        executor,
    )

    private fun makeProcessor(producer: PersonMaskProducer) = CompositingEffectProcessor(
        CameraEffectCompositor(CameraEffect.DIM),
        producer,
    )

    /** Background 220 everywhere, person 40 under what the mask marks. */
    private fun personFrame(): EffectFrame = EffectFrame(width = 320, height = 180).apply {
        fillLuma { x, y -> if (x in 60 until 160 && y in 40 until 120) 40 else 220 }
    }

    private fun composited(outcome: CameraFrameOutcome): CompositeOutcome.Composited {
        val result = outcome.outcome
        assertTrue("expected a composite, got $result", result is CompositeOutcome.Composited)
        return result as CompositeOutcome.Composited
    }

    private fun substituted(outcome: CameraFrameOutcome): CompositeOutcome.Substituted {
        val result = outcome.outcome
        assertTrue("expected a substitute, got $result", result is CompositeOutcome.Substituted)
        return result as CompositeOutcome.Substituted
    }

    private fun assertLuma(planes: CameraFramePlanes, x: Int, y: Int, expected: Int) {
        val value = luma(planes, x, y)
        assertTrue("($x,$y) = $value, expected $expected ± 4", abs(value - expected) <= 4)
    }

    @Test
    fun everyFrameFeedsTheProducerAndTheCompositePullsThePublishedMask() {
        val producer = makeProducer()
        val processor = makeProcessor(producer)
        val input = personFrame()

        val warmUp = composited(processor.process(input.frame()))
        assertNull(warmUp.maskRejection)
        assertLuma(warmUp.frame.planes, 110, 50, 20)
        assertLuma(warmUp.frame.planes, 300, 20, 110)
        warmUp.frame.close()

        assertTrue(executor.runNext())
        assertEquals(1, segmenter.submits)
        assertNotNull(producer.mask)
        clock.advance(PersonMaskProducer.TARGET_SUBMISSION_INTERVAL_NANOS)

        val masked = processor.process(input.frame())

        assertSame(processor, masked.processor)
        val planes = composited(masked).frame.planes
        assertNull(composited(masked).maskRejection)
        assertLuma(planes, 110, 50, 40)
        assertLuma(planes, 300, 20, 110)
        composited(masked).frame.close()
    }

    @Test
    fun everyProcessedFrameReleasesMaterializedInputPlanesExactlyOnce() {
        val processor = makeProcessor(makeProducer())
        val input = personFrame()
        val frame = input.frame()
        frame.planes()

        val output = processor.process(frame).frame

        assertEquals(1, input.releases)
        frame.close()
        assertEquals(1, input.releases)
        assertThrows(IllegalStateException::class.java) { frame.planes() }
        output.close()
    }

    @Test
    fun releasingAnUnmaterializedFrameIsTerminalWithoutReadingItBack() {
        val input = personFrame()
        val frame = input.frame()

        frame.close()
        frame.close()

        assertEquals(0, input.releases)
        assertThrows(IllegalStateException::class.java) { frame.planes() }
    }

    @Test
    fun aReadbackFailureSubstitutesAndTheProducerAcceptsTheNextFrame() {
        val producer = makeProducer()
        val processor = makeProcessor(producer)
        var materializations = 0
        val failure = PlaneReadbackFailure()
        val unreadable = CameraFrame(
            width = 320,
            height = 180,
            rotation = CameraFrameRotation.DEGREES_0,
            timestampNs = 0,
            source = {
                materializations += 1
                throw failure
            },
        )

        val failed = substituted(processor.process(unreadable))

        assertEquals(CameraCompositeSubstitution.RENDER_FAILED, failed.reason)
        assertEquals(1, materializations)
        assertThrows(IllegalStateException::class.java) { unreadable.planes() }
        failed.frame.close()
        val recovered = composited(processor.process(personFrame().frame()))
        recovered.frame.close()
        assertTrue(executor.runNext())
        assertEquals(1, segmenter.submits)
    }

    @Test
    fun malformedPlanesSubstituteAndTheProducerAcceptsTheNextFrame() {
        val producer = makeProducer()
        val processor = makeProcessor(producer)
        var releases = 0
        val malformed = CameraFrame(
            width = 320,
            height = 180,
            rotation = CameraFrameRotation.DEGREES_0,
            timestampNs = 0,
            source = {
                CameraFramePlanes(
                    width = 320,
                    height = 180,
                    dataY = ByteBuffer.allocate(1), strideY = 320,
                    dataU = ByteBuffer.allocate(1), strideU = 160,
                    dataV = ByteBuffer.allocate(1), strideV = 160,
                    onRelease = { releases += 1 },
                )
            },
        )

        val failed = substituted(processor.process(malformed))

        assertEquals(CameraCompositeSubstitution.MALFORMED_FRAME, failed.reason)
        assertEquals(1, releases)
        failed.frame.close()
        val recovered = composited(processor.process(personFrame().frame()))
        recovered.frame.close()
        assertTrue(executor.runNext())
        assertEquals(1, segmenter.submits)
    }

    @Test
    fun retireClosesTheProducerExactlyOnce() {
        val pools = ScriptedBufferPools()
        val producer = makeProducer()
        val processor = CompositingEffectProcessor(
            CameraEffectCompositor(CameraEffect.DIM, pools), producer,
        )
        val output = processor.process(personFrame().frame()).frame
        output.close()
        assertTrue(executor.runNext())

        processor.retire()
        val recycled = pools.pools[0].recycled
        processor.retire()

        assertEquals(1, segmenter.closes)
        assertEquals(1, executor.closes)
        assertNull(producer.mask)
        assertEquals(pools.pools[0].taken, recycled)
        assertEquals(recycled, pools.pools[0].recycled)
    }

    @Test
    fun aFrameOnARetiredProcessorPublishesAFreshWholeFrameEffect() {
        val pools = ScriptedBufferPools()
        val producer = makeProducer()
        val processor = CompositingEffectProcessor(
            CameraEffectCompositor(CameraEffect.DIM, pools), producer,
        )
        val input = personFrame()
        composited(processor.process(input.frame())).frame.close()
        assertTrue(executor.runNext())
        assertNotNull(producer.mask)
        val masked = composited(processor.process(input.frame()))
        assertLuma(masked.frame.planes, 110, 50, 40)
        masked.frame.close()

        processor.retire()
        val outcome = composited(processor.process(input.frame()))

        assertNull(outcome.maskRejection)
        assertNull(producer.mask)
        val planes = outcome.frame.planes
        assertLuma(planes, 110, 50, 20)
        assertLuma(planes, 300, 20, 110)
        outcome.frame.close()
        assertEquals(pools.pools[0].taken, pools.pools[0].recycled)
    }

    @Test
    fun thePassthroughStageCopiesTheFrameAndRunsNoInference() {
        val made = mutableListOf<ScriptedSegmenter>()
        val factory = CameraEffectProcessors(cadence) { ScriptedSegmenter().also { made.add(it) } }
        factory.stage = CameraEffectStage.PASSTHROUGH

        val processor = factory.makeProcessor(CameraEffect.BLUR)
        val outcome = composited(processor.process(personFrame().frame()))

        assertTrue(made.isEmpty())
        assertLuma(outcome.frame.planes, 110, 50, 40)
        assertLuma(outcome.frame.planes, 300, 20, 220)
        outcome.frame.close()
        processor.retire()
    }

    @Test
    fun theMaskOnlyStageRunsTheInferenceAndCopiesTheFrameAnyway() {
        val producer = makeProducer()
        val processor = StagedEffectProcessor(
            CameraEffectCompositor(CameraEffect.NONE), producer,
        )
        val input = personFrame()

        composited(processor.process(input.frame())).frame.close()
        assertTrue(executor.runNext())
        assertNotNull(producer.mask)
        clock.advance(PersonMaskProducer.TARGET_SUBMISSION_INTERVAL_NANOS)
        val outcome = composited(processor.process(input.frame()))

        assertEquals(1, segmenter.submits)
        assertNull(outcome.maskRejection)
        assertLuma(outcome.frame.planes, 110, 50, 40)
        assertLuma(outcome.frame.planes, 300, 20, 220)
        outcome.frame.close()
        processor.retire()
        assertEquals(1, segmenter.closes)
    }

    @Test
    fun theCompositeStageIsWhatTheFactoryHolds() {
        val factory = CameraEffectProcessors(cadence) { ScriptedSegmenter() }

        val processor = factory.makeProcessor(CameraEffect.DIM)

        assertEquals(CameraEffectStage.COMPOSITE, factory.stage)
        assertTrue(processor is CompositingEffectProcessor)
        processor.retire()
    }

    @Test
    fun theFactoryBuildsOneProducerPerProcessor() {
        val made = mutableListOf<ScriptedSegmenter>()
        val factory = CameraEffectProcessors(cadence) { ScriptedSegmenter().also { made.add(it) } }

        val first = factory.makeProcessor(CameraEffect.BLUR)
        val second = factory.makeProcessor(CameraEffect.DIM)

        assertEquals(2, made.size)
        assertNotSame(made[0], made[1])
        first.retire()
        assertEquals(1, made[0].closes)
        assertEquals(0, made[1].closes)
        second.retire()
    }
}
