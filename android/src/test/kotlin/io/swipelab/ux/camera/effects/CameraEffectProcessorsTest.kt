package io.swipelab.ux.camera.effects

import java.nio.FloatBuffer
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
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
        assertLuma(warmUp.frame.planes(), 110, 50, 20)
        assertLuma(warmUp.frame.planes(), 300, 20, 110)

        assertTrue(executor.runNext())
        assertEquals(1, segmenter.submits)
        assertNotNull(producer.mask)
        clock.advance(PersonMaskProducer.TARGET_SUBMISSION_INTERVAL_NANOS)

        val masked = processor.process(input.frame())

        assertSame(processor, masked.processor)
        val planes = composited(masked).frame.planes()
        assertNull(composited(masked).maskRejection)
        assertLuma(planes, 110, 50, 40)
        assertLuma(planes, 300, 20, 110)
    }

    @Test
    fun retireClosesTheProducerExactlyOnce() {
        val producer = makeProducer()
        val processor = makeProcessor(producer)
        processor.process(personFrame().frame())
        assertTrue(executor.runNext())

        processor.retire()
        processor.retire()

        assertEquals(1, segmenter.closes)
        assertEquals(1, executor.closes)
        assertNull(producer.mask)
    }

    @Test
    fun aRetiredProcessorSubstitutesRatherThanCompositing() {
        val processor = makeProcessor(makeProducer())
        val input = personFrame()
        composited(processor.process(input.frame()))

        processor.retire()
        val outcome = substituted(processor.process(input.frame()))

        assertEquals(CameraCompositeSubstitution.RETIRED, outcome.reason)
        val planes = outcome.frame.planes()
        assertEquals(0, luma(planes, 110, 50))
        assertEquals(0, luma(planes, 300, 20))
        assertEquals(128, chromaU(planes, 150, 10))
    }

    @Test
    fun theFactoryBuildsOneProducerPerProcessor() {
        val made = mutableListOf<ScriptedSegmenter>()
        val factory = CameraEffectProcessors { ScriptedSegmenter().also { made.add(it) } }

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
