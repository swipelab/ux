package io.swipelab.ux.camera.effects

import java.nio.ByteBuffer
import java.util.concurrent.RejectedExecutionException
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

private const val TARGET = PersonMaskProducer.TARGET_SUBMISSION_INTERVAL_NANOS

class PersonMaskProducerTest {
    private val executor = TestPersonMaskExecutor()
    private val clock = TestClock()
    private val pool = PersonMaskInputPool(
        PersonMaskProducer.INPUT_WIDTH,
        PersonMaskProducer.INPUT_HEIGHT,
        PersonMaskProducer.INPUT_BUFFER_COUNT,
    )
    private val segmenter = ScriptedSegmenter()
    private val source = TestFrame()

    @After
    fun tearDown() {
        segmenter.release()
        executor.close()
    }

    private fun makeProducer() = PersonMaskProducer(segmenter, pool, clock, executor)

    /** Waits out everything `consider` handed the executor. */
    private fun drain() {
        executor.drain()
    }

    @Test
    fun closeIsIdempotentAndStopsFurtherSubmissions() {
        val manual = ManualExecutor()
        val producer = PersonMaskProducer(segmenter, pool, clock, manual)

        producer.consider(source.frame())
        producer.close()
        producer.close()
        producer.consider(source.frame())

        assertFalse(manual.runNext())
        assertEquals(0, segmenter.submits)
        assertEquals(1, segmenter.closes)
        assertEquals(1, manual.closes)
        assertNull(producer.mask)
    }

    @Test(timeout = 1_000)
    fun closeDuringInFlightInferenceDropsItsLateResult() {
        val manual = ManualExecutor()
        val deferred = ScriptedSegmenter(ScriptedSegmenter.Behavior.Deferred)
        val producer = PersonMaskProducer(deferred, pool, clock, manual)

        producer.consider(source.frame())
        assertTrue(manual.runNext())
        assertEquals(1, deferred.submits)

        producer.close()
        deferred.answerHeld()

        assertNull(producer.mask)
        assertEquals(1, deferred.closes)
        assertEquals(1, manual.closes)
    }

    @Test(timeout = 2_000)
    fun closeStopsTheOwnedWorkerThread() {
        val ownedExecutor = TestPersonMaskExecutor()
        val blocked = ScriptedSegmenter(ScriptedSegmenter.Behavior.Blocked)
        val producer = PersonMaskProducer(blocked, pool, clock, ownedExecutor)

        producer.consider(source.frame())
        assertTrue(blocked.waitForSubmits(1))

        producer.close()

        assertTrue(ownedExecutor.workerStopsWithin(1_000))
        assertEquals(1, blocked.closes)
        assertEquals(1, ownedExecutor.closes)
        assertNull(producer.mask)
    }

    @Test
    fun frameCallbacksCompleteWhileAnInferenceNeverAnswers() {
        segmenter.behavior = ScriptedSegmenter.Behavior.Blocked
        val producer = makeProducer()

        repeat(100) {
            clock.advance(TARGET)
            producer.consider(source.frame())
        }

        assertTrue(segmenter.waitForSubmits(1))
        assertEquals(1, segmenter.submits)
        assertEquals(1, pool.taken)
        assertNull(producer.mask)
    }

    @Test
    fun noFurtherInputIsTakenWhileAnInferenceIsInFlight() {
        segmenter.behavior = ScriptedSegmenter.Behavior.Blocked
        val producer = makeProducer()

        producer.consider(source.frame())
        assertTrue(segmenter.waitForSubmits(1))
        assertEquals(1, pool.taken)

        repeat(20) {
            clock.advance(TARGET * 10)
            producer.consider(source.frame())
        }

        assertEquals(1, pool.taken)
        assertEquals(0, pool.exhausted)
    }

    @Test
    fun theInferenceInputCarriesTheFixedGrid() {
        val producer = makeProducer()

        producer.consider(source.frame())
        drain()

        assertEquals(
            listOf(PersonMaskProducer.INPUT_WIDTH to PersonMaskProducer.INPUT_HEIGHT),
            segmenter.inputs,
        )
    }

    @Test
    fun theFramePlanesMayBeRewrittenTheMomentConsiderReturns() {
        val manual = ManualExecutor()
        val producer = PersonMaskProducer(segmenter, pool, clock, manual)
        source.fillLuma { _, _ -> 200 }

        producer.consider(source.frame())
        source.fillLuma { _, _ -> 0 }
        assertTrue(manual.runNext())

        val input = requireNotNull(segmenter.lastInput)
        assertEquals(200, input.nv21.get(0).toInt() and 0xff)
        assertEquals(
            200,
            input.nv21.get(input.width * input.height - 1).toInt() and 0xff,
        )
    }

    @Test
    fun malformedPlanePreparationRecyclesItsClaimAndInput() {
        val producer = makeProducer()
        val malformed = {
            CameraFrame(
                width = source.width,
                height = source.height,
                rotation = CameraFrameRotation.DEGREES_0,
                timestampNs = 0,
                source = {
                    CameraFramePlanes(
                        width = source.width,
                        height = source.height,
                        dataY = ByteBuffer.allocate(1), strideY = source.width,
                        dataU = ByteBuffer.allocate(1), strideU = source.width / 2,
                        dataV = ByteBuffer.allocate(1), strideV = source.width / 2,
                        onRelease = {},
                    )
                },
            )
        }

        repeat(3) { producer.consider(malformed()) }
        producer.consider(source.frame())
        drain()

        assertEquals(4, pool.taken)
        assertEquals(0, pool.exhausted)
        assertEquals(1, segmenter.submits)
        assertNotNull(producer.mask)
    }

    @Test
    fun rejectedEnqueueRecyclesItsClaimAndInput() {
        var rejects = true
        val rejecting = object : PersonMaskExecutor {
            override fun execute(command: Runnable) {
                if (rejects) {
                    rejects = false
                    throw RejectedExecutionException()
                }
                command.run()
            }

            override fun close() = Unit
        }
        val producer = PersonMaskProducer(segmenter, pool, clock, rejecting)

        producer.consider(source.frame())
        producer.consider(source.frame())

        assertEquals(2, pool.taken)
        assertEquals(0, pool.exhausted)
        assertEquals(1, segmenter.submits)
        assertNotNull(producer.mask)
        producer.close()
    }

    @Test
    fun theDownscaleSamplesAcrossTheWholeFrame() {
        val producer = makeProducer()
        source.fillLuma { x, _ -> x * 255 / (source.width - 1) }
        source.fillChroma(u = 60, v = 90)

        producer.consider(source.frame())
        drain()

        val input = requireNotNull(segmenter.lastInput)
        val sample = { x: Int, y: Int ->
            input.nv21.get(y * input.width + x).toInt() and 0xff
        }
        assertEquals(0, sample(0, 0))
        assertEquals(
            (input.width - 1) * source.width / input.width * 255 / (source.width - 1),
            sample(input.width - 1, input.height - 1),
        )
        val chromaBase = input.width * input.height
        assertEquals(90, input.nv21.get(chromaBase).toInt() and 0xff)
        assertEquals(60, input.nv21.get(chromaBase + 1).toInt() and 0xff)
    }

    @Test
    fun theMaskCarriesTheFramesGeometryAndItsGeneration() {
        val producer = makeProducer()

        producer.consider(source.frame())
        drain()

        val mask = requireNotNull(producer.mask)
        assertEquals(256, mask.width)
        assertEquals(144, mask.height)
        assertEquals(
            CameraFrameRect(0, 0, source.width, source.height), mask.sourceRect,
        )
        assertEquals(0, mask.generation)
    }

    @Test
    fun theLastMaskIsServedBetweenPublications() {
        val producer = makeProducer()

        producer.consider(source.frame())
        drain()
        val published = producer.mask
        assertNotNull(published)

        repeat(5) {
            clock.advance(TARGET / 10)
            producer.consider(source.frame())
            drain()
        }

        assertEquals(1, segmenter.submits)
        assertSame(published, producer.mask)

        clock.advance(TARGET)
        producer.consider(source.frame())
        drain()

        assertEquals(2, segmenter.submits)
        assertTrue(published !== producer.mask)
    }

    @Test
    fun submissionsStayAtOrBelowTheTargetRateHoweverFastFramesArrive() {
        val producer = makeProducer()
        repeat(60) {
            clock.advance(1_000_000_000L / 60)
            producer.consider(source.frame())
            drain()
        }
        assertTrue("${segmenter.submits} submits", segmenter.submits in 10..15)

        val doubledClock = TestClock()
        val doubled = ScriptedSegmenter()
        val atOneTwenty = PersonMaskProducer(doubled, clock = doubledClock, executor = executor)
        repeat(120) {
            doubledClock.advance(1_000_000_000L / 120)
            atOneTwenty.consider(source.frame())
            drain()
        }
        assertTrue(
            "${doubled.submits} submits",
            doubled.submits <= PersonMaskProducer.TARGET_SUBMISSIONS_PER_SECOND,
        )
    }

    @Test
    fun aSlowInferenceWidensTheIntervalAndAFastOneReturnsItToTheTarget() {
        val slow = 500_000_000L
        val scripted = ScriptedSegmenter(ScriptedSegmenter.Behavior.Advancing(slow), clock)
        val producer = PersonMaskProducer(scripted, pool, clock, executor)

        producer.consider(source.frame())
        drain()
        assertEquals(1, scripted.submits)
        assertEquals(TARGET, producer.submissionIntervalNanos)

        producer.consider(source.frame())
        drain()
        assertEquals(2, scripted.submits)
        assertEquals(slow, producer.submissionIntervalNanos)

        scripted.behavior = ScriptedSegmenter.Behavior.Immediate
        producer.consider(source.frame())
        drain()
        assertEquals(3, scripted.submits)
        assertEquals(TARGET, producer.submissionIntervalNanos)

        clock.advance(TARGET * 2)
        producer.consider(source.frame())
        drain()
        assertEquals(4, scripted.submits)
    }

    @Test
    fun aCompletionFromARetiredGenerationIsDropped() {
        segmenter.behavior = ScriptedSegmenter.Behavior.Deferred
        val producer = makeProducer()

        producer.consider(source.frame())
        drain()
        producer.reset()
        segmenter.answerHeld()

        assertNull(producer.mask)
    }

    @Test
    fun aCompletionOfAnInferenceResetRanThroughIsDropped() {
        segmenter.behavior = ScriptedSegmenter.Behavior.Blocked
        val producer = makeProducer()

        producer.consider(source.frame())
        assertTrue(segmenter.waitForSubmits(1))
        producer.reset()
        segmenter.release()
        assertTrue(segmenter.waitForFinishes(1))

        assertNull(producer.mask)
    }

    @Test
    fun resetLetsAFreshFrameSubmitWhileTheAbandonedInferenceStillHoldsAnInput() {
        segmenter.behavior = ScriptedSegmenter.Behavior.Blocked
        val producer = makeProducer()

        producer.consider(source.frame())
        assertTrue(segmenter.waitForSubmits(1))
        assertEquals(1, pool.taken)

        producer.reset()
        producer.consider(source.frame())

        assertEquals(2, pool.taken)
        assertEquals(0, pool.exhausted)

        segmenter.release()
        assertTrue(segmenter.waitForSubmits(2))
        assertTrue(segmenter.waitForFinishes(2))
        assertNotNull(producer.mask)
    }

    @Test
    fun anExhaustedPoolDropsTheSubmissionAndTheNextFrameSubmitsOnceAnInputReturns() {
        segmenter.behavior = ScriptedSegmenter.Behavior.Blocked
        val producer = makeProducer()

        producer.consider(source.frame())
        assertTrue(segmenter.waitForSubmits(1))
        producer.reset()
        producer.consider(source.frame())
        producer.reset()
        producer.consider(source.frame())

        assertEquals(2, pool.taken)
        assertEquals(1, pool.exhausted)

        segmenter.release()
        assertTrue(segmenter.waitForFinishes(2))
        segmenter.behavior = ScriptedSegmenter.Behavior.Immediate
        clock.advance(TARGET)
        producer.consider(source.frame())
        drain()

        assertEquals(3, segmenter.submits)
        assertNotNull(producer.mask)
    }

    @Test
    fun resetWithAnInferenceInFlightDropsItAndReturnsItsInput() {
        segmenter.behavior = ScriptedSegmenter.Behavior.Blocked
        val producer = makeProducer()

        producer.consider(source.frame())
        assertTrue(segmenter.waitForSubmits(1))
        producer.reset()
        segmenter.release()
        assertTrue(segmenter.waitForFinishes(1))
        assertNull(producer.mask)

        segmenter.behavior = ScriptedSegmenter.Behavior.Immediate
        repeat(5) {
            clock.advance(TARGET * 2)
            producer.consider(source.frame())
            drain()
        }

        assertEquals(6, segmenter.submits)
        assertEquals(0, pool.exhausted)
        assertNotNull(producer.mask)
    }

    @Test
    fun anErroredInferenceLeavesTheProducerSubmittingAgain() {
        segmenter.behavior = ScriptedSegmenter.Behavior.Failing
        val producer = makeProducer()

        producer.consider(source.frame())
        drain()
        assertNull(producer.mask)

        segmenter.behavior = ScriptedSegmenter.Behavior.Immediate
        clock.advance(TARGET * 2)
        producer.consider(source.frame())
        drain()

        assertEquals(2, segmenter.submits)
        assertNotNull(producer.mask)
        assertEquals(0, pool.exhausted)
    }

    @Test
    fun aFrameWithNoPixelsSubmitsOnTheVeryNextFrame() {
        val producer = makeProducer()

        producer.consider(TestFrame(width = 0, height = 0).frame())
        producer.consider(source.frame())
        drain()

        assertEquals(1, segmenter.submits)
        assertNotNull(producer.mask)
    }
}
