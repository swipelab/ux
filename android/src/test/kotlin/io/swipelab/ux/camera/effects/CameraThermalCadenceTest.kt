package io.swipelab.ux.camera.effects

import android.os.PowerManager
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

private const val TARGET = PersonMaskProducer.TARGET_SUBMISSION_INTERVAL_NANOS
private const val BACKED_OFF = TARGET * CameraThermalCadence.BACKOFF
private const val SUSTAIN = CameraThermalCadence.SUSTAIN_NANOS

class CameraThermalCadenceTest {
    private val clock = TestClock()
    private val source = TestThermalSource()
    private val cadence = CameraThermalCadence(clock).also { it.observe(source) }

    @Test
    fun anUnpressuredHostHoldsTheTargetInterval() {
        assertTrue(source.observed)
        assertEquals(TARGET, cadence.intervalNanos())

        source.report(PowerManager.THERMAL_STATUS_NONE)
        clock.advance(SUSTAIN * 10)

        assertEquals(TARGET, cadence.intervalNanos())
    }

    @Test
    fun pressureThatHasJustArrivedLeavesTheIntervalAlone() {
        source.report(PowerManager.THERMAL_STATUS_LIGHT)

        assertEquals(TARGET, cadence.intervalNanos())

        clock.advance(SUSTAIN - 1)

        assertEquals(TARGET, cadence.intervalNanos())
    }

    @Test
    fun pressureHeldPastTheSustainWindowWidensTheInterval() {
        source.report(PowerManager.THERMAL_STATUS_LIGHT)
        clock.advance(SUSTAIN)

        assertEquals(BACKED_OFF, cadence.intervalNanos())
    }

    @Test
    fun pressureThatClearsReturnsTheTargetInterval() {
        source.report(PowerManager.THERMAL_STATUS_MODERATE)
        clock.advance(SUSTAIN)
        assertEquals(BACKED_OFF, cadence.intervalNanos())

        source.report(PowerManager.THERMAL_STATUS_NONE)

        assertEquals(TARGET, cadence.intervalNanos())
    }

    @Test
    fun pressureThatClearsAndReturnsSustainsFromItsNewArrival() {
        source.report(PowerManager.THERMAL_STATUS_LIGHT)
        clock.advance(SUSTAIN - 1)
        source.report(PowerManager.THERMAL_STATUS_NONE)
        source.report(PowerManager.THERMAL_STATUS_LIGHT)

        clock.advance(SUSTAIN - 1)
        assertEquals(TARGET, cadence.intervalNanos())

        clock.advance(1)
        assertEquals(BACKED_OFF, cadence.intervalNanos())
    }

    @Test
    fun aStatusClimbingUnderPressureKeepsTheArrivalItSustainsFrom() {
        source.report(PowerManager.THERMAL_STATUS_LIGHT)
        clock.advance(SUSTAIN - 1)
        source.report(PowerManager.THERMAL_STATUS_SEVERE)

        clock.advance(1)

        assertEquals(BACKED_OFF, cadence.intervalNanos())
    }

    @Test
    fun stopClosesTheSourceAndDropsThePressureItReported() {
        source.report(PowerManager.THERMAL_STATUS_LIGHT)
        clock.advance(SUSTAIN)

        cadence.stop()

        assertEquals(1, source.closes)
        assertFalse(source.observed)
        assertEquals(TARGET, cadence.intervalNanos())
    }

    @Test
    fun aSecondSourceTakesOverAndTheFirstIsClosed() {
        val successor = TestThermalSource()

        cadence.observe(successor)
        successor.report(PowerManager.THERMAL_STATUS_LIGHT)
        clock.advance(SUSTAIN)

        assertEquals(1, source.closes)
        assertFalse(source.observed)
        assertEquals(BACKED_OFF, cadence.intervalNanos())
    }
}

class ThermalCadenceProducerTest {
    private val clock = TestClock()
    private val source = TestThermalSource()
    private val cadence = CameraThermalCadence(clock).also { it.observe(source) }
    private val executor = TestPersonMaskExecutor()
    private val segmenter = ScriptedSegmenter()
    private val frames = TestFrame()

    @After
    fun tearDown() {
        segmenter.release()
        executor.close()
    }

    /** What the producer submits over a second of frames arriving every millisecond. */
    private fun submissionsInASecond(producer: PersonMaskProducer): Int {
        val before = segmenter.submits
        repeat(1_000) {
            clock.advance(1_000_000)
            producer.consider(frames.frame())
            executor.drain()
        }
        return segmenter.submits - before
    }

    @Test
    fun sustainedPressureHalvesWhatTheProducerSubmitsInASecond() {
        val producer = PersonMaskProducer(
            segmenter,
            PersonMaskInputPool(
                PersonMaskProducer.INPUT_WIDTH,
                PersonMaskProducer.INPUT_HEIGHT,
                PersonMaskProducer.INPUT_BUFFER_COUNT,
            ),
            clock,
            executor,
            cadence,
        )

        val unpressured = submissionsInASecond(producer)

        source.report(PowerManager.THERMAL_STATUS_LIGHT)
        clock.advance(SUSTAIN)
        val pressured = submissionsInASecond(producer)

        source.report(PowerManager.THERMAL_STATUS_NONE)
        val recovered = submissionsInASecond(producer)

        assertEquals(15, unpressured)
        assertEquals(8, pressured)
        assertEquals(15, recovered)
    }
}
