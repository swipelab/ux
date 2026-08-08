package io.swipelab.ux.camera.effects

import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pixel assertions are regional, not exact: the blur runs downscaled and both
 * resamplings interpolate.
 */
private const val TOLERANCE = 4

class CameraEffectCompositorTest {
    private fun composited(outcome: CompositeOutcome): CompositeOutcome.Composited {
        assertTrue("expected a composite, got $outcome", outcome is CompositeOutcome.Composited)
        return outcome as CompositeOutcome.Composited
    }

    private fun substituted(outcome: CompositeOutcome): CompositeOutcome.Substituted {
        assertTrue("expected a substitute, got $outcome", outcome is CompositeOutcome.Substituted)
        return outcome as CompositeOutcome.Substituted
    }

    private fun assertLuma(
        planes: CameraFramePlanes,
        x: Int,
        y: Int,
        expected: Int,
        within: Int = TOLERANCE,
    ) {
        val value = luma(planes, x, y)
        assertTrue(
            "($x,$y) = $value, expected $expected ± $within",
            abs(value - expected) <= within,
        )
    }

    /** Background 220 everywhere, person 40 in a region off both centres. */
    private fun personFrame(): EffectFrame = EffectFrame(width = 320, height = 180).apply {
        fillLuma { x, y -> if (x in 60 until 160 && y in 40 until 120) 40 else 220 }
    }

    private fun personMask(): CameraMask = makeEffectMask(
        width = 160,
        height = 90,
        sourceRect = CameraFrameRect(0, 0, 320, 180),
        person = CameraFrameRect(30, 20, 50, 40),
    )

    @Test
    fun blurKeepsThePersonAndChangesTheBackground() {
        val compositor = CameraEffectCompositor(CameraEffect.BLUR)
        val input = personFrame()

        val outcome = composited(compositor.composite(input.frame(), personMask()))

        assertNull(outcome.maskRejection)
        val planes = outcome.frame.planes()
        assertLuma(planes, 110, 50, 40)
        assertLuma(planes, 300, 20, 220)
        val nearEdge = luma(planes, 170, 80)
        assertTrue(
            "background beside the person should mix, got $nearEdge",
            nearEdge in 71..199,
        )
    }

    @Test
    fun dimDarkensOnlyTheBackgroundUnderAPersonMask() {
        val compositor = CameraEffectCompositor(CameraEffect.DIM)
        val input = personFrame()

        val outcome = composited(compositor.composite(input.frame(), personMask()))

        assertNull(outcome.maskRejection)
        val planes = outcome.frame.planes()
        assertLuma(planes, 110, 50, 40)
        assertLuma(planes, 300, 20, 110)
        assertLuma(planes, 170, 80, 110)
        assertEquals(128, chromaU(planes, 150, 10))
        assertEquals(128, chromaV(planes, 150, 10))
    }

    @Test
    fun withoutAMaskBlurCoversTheWholeFrame() {
        val compositor = CameraEffectCompositor(CameraEffect.BLUR)
        val input = EffectFrame(width = 320, height = 180).apply {
            fillLuma { x, _ -> if (x < 160) 60 else 200 }
        }

        val outcome = composited(compositor.composite(input.frame(), null))

        assertNull(outcome.maskRejection)
        val planes = outcome.frame.planes()
        assertLuma(planes, 20, 90, 60)
        assertLuma(planes, 300, 90, 200)
        val boundary = luma(planes, 160, 90)
        assertTrue(
            "the step should smear across its boundary, got $boundary",
            boundary in 91..169,
        )
    }

    @Test
    fun withoutAMaskDimCoversTheWholeFrame() {
        val compositor = CameraEffectCompositor(CameraEffect.DIM)
        val input = EffectFrame(width = 320, height = 180).apply { fillLuma { _, _ -> 200 } }

        val planes = composited(compositor.composite(input.frame(), null)).frame.planes()

        assertLuma(planes, 160, 90, 100)
        assertLuma(planes, 2, 2, 100)
        assertLuma(planes, 317, 177, 100)
    }

    @Test
    fun aUniformFrameBlursToItsOwnValueOutToTheCorners() {
        val compositor = CameraEffectCompositor(CameraEffect.BLUR)
        val input = EffectFrame(width = 320, height = 180).apply { fillLuma { _, _ -> 255 } }

        val planes = composited(compositor.composite(input.frame(), null)).frame.planes()

        assertLuma(planes, 160, 90, 255)
        assertLuma(planes, 0, 0, 255)
        assertLuma(planes, 319, 0, 255)
        assertLuma(planes, 0, 179, 255)
        assertLuma(planes, 319, 179, 255)
    }

    @Test
    fun theMaskGridStretchesOntoTheFrameWithoutFitOrFlip() {
        val compositor = CameraEffectCompositor(CameraEffect.DIM)
        val input = EffectFrame(width = 640, height = 360).apply { fillLuma { _, _ -> 200 } }
        val mask = makeEffectMask(
            width = 256,
            height = 192,
            sourceRect = CameraFrameRect(0, 0, 640, 360),
            person = CameraFrameRect(154, 106, 51, 48),
        )

        val outcome = composited(compositor.composite(input.frame(), mask))

        assertNull(outcome.maskRejection)
        val planes = outcome.frame.planes()
        assertLuma(planes, 450, 240, 200)
        assertLuma(planes, 600, 240, 100)
        assertLuma(planes, 450, 330, 100)
        assertLuma(planes, 450, 120, 100)
        assertLuma(planes, 190, 240, 100)
    }

    @Test
    fun anAllZeroMaskIsSetAsideAndTheWholeFrameTakesTheEffect() {
        val compositor = CameraEffectCompositor(CameraEffect.DIM)
        val input = EffectFrame(width = 64, height = 36)
        val mask = makeEffectMask(32, 24, CameraFrameRect(0, 0, 64, 36))

        val outcome = composited(compositor.composite(input.frame(), mask))

        assertEquals(CameraMaskRejection.EMPTY, outcome.maskRejection)
        assertLuma(outcome.frame.planes(), 32, 18, 100)
    }

    @Test
    fun aZeroDimensionedMaskIsSetAsideAndTheWholeFrameTakesTheEffect() {
        val compositor = CameraEffectCompositor(CameraEffect.DIM)
        val input = EffectFrame(width = 64, height = 36)
        val mask = makeEffectMask(
            width = 32,
            height = 24,
            sourceRect = CameraFrameRect(0, 0, 64, 36),
            person = CameraFrameRect(8, 6, 16, 12),
            declaredWidth = 0,
            declaredHeight = 0,
        )

        val outcome = composited(compositor.composite(input.frame(), mask))

        assertEquals(CameraMaskRejection.ZERO_DIMENSIONED, outcome.maskRejection)
        assertLuma(outcome.frame.planes(), 32, 18, 100)
    }

    @Test
    fun aMaskOffTheFrameIsSetAsideAndTheWholeFrameTakesTheEffect() {
        val compositor = CameraEffectCompositor(CameraEffect.DIM)
        val input = EffectFrame(width = 64, height = 36)
        val mask = makeEffectMask(
            width = 32,
            height = 24,
            sourceRect = CameraFrameRect(10, 0, 64, 36),
            person = CameraFrameRect(8, 6, 16, 12),
        )

        val outcome = composited(compositor.composite(input.frame(), mask))

        assertEquals(CameraMaskRejection.SOURCE_RECT_MISMATCH, outcome.maskRejection)
        val planes = outcome.frame.planes()
        assertLuma(planes, 32, 18, 100)
        assertLuma(planes, 20, 12, 100)
    }

    @Test
    fun theFirstMalformedFrameSubstitutesBlackAtTheFramesSize() {
        val compositor = CameraEffectCompositor(CameraEffect.DIM)
        val input = EffectFrame(
            width = 32,
            height = 18,
            rotation = CameraFrameRotation.DEGREES_180,
            timestampNs = 4242,
            declaredWidth = 64,
            declaredHeight = 36,
        )

        val outcome = substituted(compositor.composite(input.frame(), null))

        assertEquals(CameraCompositeSubstitution.MALFORMED_FRAME, outcome.reason)
        assertEquals(64, outcome.frame.width)
        assertEquals(36, outcome.frame.height)
        assertEquals(CameraFrameRotation.DEGREES_180, outcome.frame.rotation)
        assertEquals(4242, outcome.frame.timestampNs)
        val planes = outcome.frame.planes()
        assertLuma(planes, 5, 5, 0, within = 0)
        assertLuma(planes, 60, 30, 0, within = 0)
        assertEquals(128, chromaU(planes, 5, 5))
        assertEquals(128, chromaV(planes, 5, 5))
    }

    @Test
    fun aMalformedFrameAfterAGoodOneSubstitutesTheLastGoodRetagged() {
        val compositor = CameraEffectCompositor(CameraEffect.DIM)
        val good = EffectFrame(width = 64, height = 36).apply { fillLuma { _, _ -> 200 } }
        composited(compositor.composite(good.frame(), null))

        val malformed = EffectFrame(
            width = 32,
            height = 18,
            rotation = CameraFrameRotation.DEGREES_90,
            timestampNs = 999,
            declaredWidth = 64,
            declaredHeight = 36,
        )
        val outcome = substituted(compositor.composite(malformed.frame(), null))

        assertEquals(CameraCompositeSubstitution.MALFORMED_FRAME, outcome.reason)
        assertEquals(CameraFrameRotation.DEGREES_90, outcome.frame.rotation)
        assertEquals(999, outcome.frame.timestampNs)
        assertLuma(outcome.frame.planes(), 32, 18, 100)
    }

    @Test
    fun aFrameWhosePlanesFailToMaterializeSubstitutes() {
        val compositor = CameraEffectCompositor(CameraEffect.DIM)
        val input = EffectFrame(width = 64, height = 36).apply { failsToMaterialize = true }

        val outcome = substituted(compositor.composite(input.frame(), null))

        assertEquals(CameraCompositeSubstitution.RENDER_FAILED, outcome.reason)
        assertLuma(outcome.frame.planes(), 32, 18, 0, within = 0)
    }

    @Test
    fun aPoolFailureAnswersWithTheLastGoodFrameRetagged() {
        val pools = ScriptedBufferPools()
        val compositor = CameraEffectCompositor(CameraEffect.DIM, pools)
        val good = EffectFrame(width = 64, height = 36).apply { fillLuma { _, _ -> 200 } }
        val effected = composited(compositor.composite(good.frame(), null)).frame

        pools.allocationsFail = true
        val next = EffectFrame(
            width = 64,
            height = 36,
            rotation = CameraFrameRotation.DEGREES_270,
            timestampNs = 77,
        ).apply { fillLuma { _, _ -> 60 } }
        val outcome = substituted(compositor.composite(next.frame(), null))

        assertEquals(CameraCompositeSubstitution.POOL_UNAVAILABLE, outcome.reason)
        assertEquals(CameraFrameRotation.DEGREES_270, outcome.frame.rotation)
        assertEquals(77, outcome.frame.timestampNs)
        assertEquals(
            luma(effected.planes(), 32, 18),
            luma(outcome.frame.planes(), 32, 18),
        )
        assertLuma(outcome.frame.planes(), 32, 18, 100)
    }

    @Test
    fun aGeometryChangeDiscardsTheLastGoodAndAnswersBlack() {
        val pools = ScriptedBufferPools()
        val compositor = CameraEffectCompositor(CameraEffect.DIM, pools)
        val good = EffectFrame(width = 64, height = 36).apply { fillLuma { _, _ -> 200 } }
        composited(compositor.composite(good.frame(), null))

        pools.allocationsFail = true
        val resized = EffectFrame(width = 48, height = 24, timestampNs = 1234)
        val outcome = substituted(compositor.composite(resized.frame(), null))

        assertEquals(CameraCompositeSubstitution.POOL_UNAVAILABLE, outcome.reason)
        assertEquals(48, outcome.frame.width)
        assertEquals(24, outcome.frame.height)
        assertEquals(1234, outcome.frame.timestampNs)
        val planes = outcome.frame.planes()
        assertLuma(planes, 5, 5, 0, within = 0)
        assertLuma(planes, 40, 20, 0, within = 0)
        assertEquals(2, pools.pools.size)
    }

    @Test
    fun sustainedCompositingStaysInsideThePoolBound() {
        val pools = ScriptedBufferPools()
        val compositor = CameraEffectCompositor(CameraEffect.DIM, pools)
        val input = EffectFrame(width = 64, height = 36)

        repeat(500) {
            composited(compositor.composite(input.frame(), null)).frame.planes().release()
        }

        assertEquals(1, pools.pools.size)
        assertEquals(500, pools.pools[0].taken)
        assertEquals(0, pools.pools[0].exhausted)
    }

    @Test
    fun theOutputNeverAliasesTheInputPlanes() {
        val compositor = CameraEffectCompositor(CameraEffect.NONE)
        val input = EffectFrame(width = 64, height = 36).apply { fillLuma { _, _ -> 200 } }

        val planes = composited(compositor.composite(input.frame(), null)).frame.planes()
        input.fillLuma { _, _ -> 10 }
        input.fillChroma(30, 40)

        assertTrue(planes.dataY !== input.dataY)
        assertTrue(planes.dataU !== input.dataU)
        assertTrue(planes.dataV !== input.dataV)
        assertLuma(planes, 32, 18, 200, within = 0)
        assertEquals(128, chromaU(planes, 16, 9))
        assertEquals(128, chromaV(planes, 16, 9))
        assertEquals(0, input.releases)
    }

    @Test
    fun theOutputCarriesTheInputsRotationAndTimestamp() {
        val compositor = CameraEffectCompositor(CameraEffect.BLUR)
        val input = EffectFrame(
            width = 64,
            height = 36,
            rotation = CameraFrameRotation.DEGREES_90,
            timestampNs = 123_456_789,
        )

        val output = composited(compositor.composite(input.frame(), null)).frame

        assertEquals(64, output.width)
        assertEquals(36, output.height)
        assertEquals(CameraFrameRotation.DEGREES_90, output.rotation)
        assertEquals(123_456_789, output.timestampNs)
    }

    @Test
    fun concurrentCompositesAcrossAGeometryChangeStayCoherent() {
        val compositor = CameraEffectCompositor(CameraEffect.DIM)
        val wide = EffectFrame(width = 64, height = 36)
        val narrow = EffectFrame(width = 48, height = 24)
        val violations = AtomicInteger()
        val workers = Executors.newFixedThreadPool(8)

        repeat(240) { index ->
            workers.execute {
                val source = if (index % 3 == 0) narrow else wide
                val output = compositor.composite(source.frame(), null).frame
                val planes = output.planes()
                val coherent = output.width == planes.width &&
                    output.height == planes.height &&
                    (output.width == 64 || output.width == 48)
                if (!coherent) violations.incrementAndGet()
                planes.release()
            }
        }
        workers.shutdown()

        assertTrue(workers.awaitTermination(30, TimeUnit.SECONDS))
        assertEquals(0, violations.get())
    }
}
