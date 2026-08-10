package io.swipelab.ux.camera.effects

import java.nio.FloatBuffer
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

    private fun variance(
        planes: CameraFramePlanes,
        left: Int,
        top: Int,
        right: Int,
        bottom: Int,
    ): Double {
        var sum = 0.0
        var squares = 0.0
        var count = 0
        for (y in top until bottom) {
            for (x in left until right) {
                val value = luma(planes, x, y).toDouble()
                sum += value
                squares += value * value
                count += 1
            }
        }
        val mean = sum / count
        return squares / count - mean * mean
    }

    @Test
    fun blurLeavesThePersonRegionsVarianceAndTakesTheBackgrounds() {
        val compositor = CameraEffectCompositor(CameraEffect.BLUR)
        val input = EffectFrame(width = 320, height = 180).apply {
            fillLuma { x, y -> if ((x + y) % 2 == 0) 40 else 220 }
        }

        val outcome = composited(compositor.composite(input.frame(), personMask()))

        assertNull(outcome.maskRejection)
        val planes = outcome.frame.planes
        val person = variance(planes, 80, 60, 140, 100)
        val background = variance(planes, 220, 20, 300, 60)
        assertTrue("the person region should keep its detail, got $person", person > 4000.0)
        assertTrue("the background should lose its detail, got $background", background < 100.0)
    }

    @Test
    fun blurKeepsThePersonAndChangesTheBackground() {
        val compositor = CameraEffectCompositor(CameraEffect.BLUR)
        val input = personFrame()

        val outcome = composited(compositor.composite(input.frame(), personMask()))

        assertNull(outcome.maskRejection)
        val planes = outcome.frame.planes
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
        val planes = outcome.frame.planes
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
        val planes = outcome.frame.planes
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

        val planes = composited(compositor.composite(input.frame(), null)).frame.planes

        assertLuma(planes, 160, 90, 100)
        assertLuma(planes, 2, 2, 100)
        assertLuma(planes, 317, 177, 100)
    }

    @Test
    fun aUniformFrameBlursToItsOwnValueOutToTheCorners() {
        val compositor = CameraEffectCompositor(CameraEffect.BLUR)
        val input = EffectFrame(width = 320, height = 180).apply { fillLuma { _, _ -> 255 } }

        val planes = composited(compositor.composite(input.frame(), null)).frame.planes

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
        val planes = outcome.frame.planes
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
        assertLuma(outcome.frame.planes, 32, 18, 100)
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
        assertLuma(outcome.frame.planes, 32, 18, 100)
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
        val planes = outcome.frame.planes
        assertLuma(planes, 32, 18, 100)
        assertLuma(planes, 20, 12, 100)
    }

    @Test
    fun anUndersizedMaskIsSetAsideAndTheWholeFrameTakesTheEffect() {
        val compositor = CameraEffectCompositor(CameraEffect.DIM)
        val input = EffectFrame(width = 64, height = 36)
        val mask = CameraMask(
            confidence = FloatBuffer.allocate(32 * 24 - 1),
            width = 32,
            height = 24,
            sourceRect = CameraFrameRect(0, 0, 64, 36),
            sourceTimestampNs = 0,
            generation = 0,
        )

        val outcome = composited(compositor.composite(input.frame(), mask))

        assertEquals(CameraMaskRejection.INVALID_STORAGE, outcome.maskRejection)
        assertLuma(outcome.frame.planes, 32, 18, 100)
    }

    @Test
    fun aLimitShortenedMaskIsSetAsideAndTheWholeFrameTakesTheEffect() {
        val compositor = CameraEffectCompositor(CameraEffect.DIM)
        val input = EffectFrame(width = 64, height = 36)
        val confidence = FloatBuffer.allocate(32 * 24).apply { limit(32 * 24 - 1) }
        val mask = CameraMask(
            confidence = confidence,
            width = 32,
            height = 24,
            sourceRect = CameraFrameRect(0, 0, 64, 36),
            sourceTimestampNs = 0,
            generation = 0,
        )

        val outcome = composited(compositor.composite(input.frame(), mask))

        assertEquals(CameraMaskRejection.INVALID_STORAGE, outcome.maskRejection)
        assertLuma(outcome.frame.planes, 32, 18, 100)
    }

    @Test
    fun anOverflowingMaskGridIsSetAsideAndTheWholeFrameTakesTheEffect() {
        val compositor = CameraEffectCompositor(CameraEffect.DIM)
        val input = EffectFrame(width = 64, height = 36)
        val mask = CameraMask(
            confidence = FloatBuffer.allocate(1),
            width = Int.MAX_VALUE,
            height = 2,
            sourceRect = CameraFrameRect(0, 0, 64, 36),
            sourceTimestampNs = 0,
            generation = 0,
        )

        val outcome = composited(compositor.composite(input.frame(), mask))

        assertEquals(CameraMaskRejection.INVALID_STORAGE, outcome.maskRejection)
        assertLuma(outcome.frame.planes, 32, 18, 100)
    }

    @Test
    fun changingTheSuppliedMasksLimitDoesNotChangeTheMask() {
        val compositor = CameraEffectCompositor(CameraEffect.DIM)
        val input = EffectFrame(width = 64, height = 36)
        val confidence = FloatBuffer.allocate(32 * 24).apply {
            for (index in 0 until capacity()) put(index, 1f)
        }
        val mask = CameraMask(
            confidence = confidence,
            width = 32,
            height = 24,
            sourceRect = CameraFrameRect(0, 0, 64, 36),
            sourceTimestampNs = 0,
            generation = 0,
        )
        confidence.limit(1)

        val outcome = composited(compositor.composite(input.frame(), mask))

        assertNull(outcome.maskRejection)
        assertLuma(outcome.frame.planes, 32, 18, 200)
    }

    @Test
    fun changingAnExposedMaskViewsLimitDoesNotChangeTheMask() {
        val compositor = CameraEffectCompositor(CameraEffect.DIM)
        val input = EffectFrame(width = 64, height = 36)
        val mask = makeEffectMask(
            width = 32,
            height = 24,
            sourceRect = CameraFrameRect(0, 0, 64, 36),
            person = CameraFrameRect(0, 0, 32, 24),
        )
        mask.confidence.limit(1)

        val outcome = composited(compositor.composite(input.frame(), mask))

        assertNull(outcome.maskRejection)
        assertLuma(outcome.frame.planes, 32, 18, 200)
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
        val planes = outcome.frame.planes
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
        assertLuma(outcome.frame.planes, 32, 18, 100)
    }

    @Test
    fun aFrameWhosePlanesFailToMaterializeSubstitutes() {
        val compositor = CameraEffectCompositor(CameraEffect.DIM)
        val input = EffectFrame(width = 64, height = 36).apply { failsToMaterialize = true }

        val outcome = substituted(compositor.composite(input.frame(), null))

        assertEquals(CameraCompositeSubstitution.RENDER_FAILED, outcome.reason)
        assertLuma(outcome.frame.planes, 32, 18, 0, within = 0)
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
            luma(effected.planes, 32, 18),
            luma(outcome.frame.planes, 32, 18),
        )
        assertLuma(outcome.frame.planes, 32, 18, 100)
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
        val planes = outcome.frame.planes
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
            composited(compositor.composite(input.frame(), null)).frame.close()
        }

        assertEquals(1, pools.pools.size)
        assertEquals(500, pools.pools[0].taken)
        assertEquals(499, pools.pools[0].recycled)
        assertEquals(0, pools.pools[0].exhausted)

        compositor.retire()

        assertEquals(500, pools.pools[0].recycled)
    }

    @Test
    fun releasingCompositorOutputsWithoutReadingPlanesDoesNotExhaustThePool() {
        val pools = ScriptedBufferPools()
        val compositor = CameraEffectCompositor(CameraEffect.DIM, pools)
        val input = EffectFrame(width = 64, height = 36)
        val rounds = FrameBufferPool.ALLOCATION_BOUND * 4

        repeat(rounds) {
            composited(compositor.composite(input.frame(), null)).frame.close()
        }

        assertEquals(rounds, pools.pools[0].taken)
        assertEquals(rounds - 1, pools.pools[0].recycled)
        assertEquals(0, pools.pools[0].exhausted)
    }

    @Test
    fun closingAPublishedFrameTwiceReleasesItsPublicationOnce() {
        val pools = ScriptedBufferPools()
        val compositor = CameraEffectCompositor(CameraEffect.DIM, pools)
        val input = EffectFrame(width = 64, height = 36)
        composited(compositor.composite(input.frame(), null)).frame.close()
        compositor.retire()
        val published = composited(compositor.composite(input.frame(), null)).frame
        val recycledBefore = pools.pools[0].recycled

        published.close()
        published.close()

        assertEquals(recycledBefore + 1, pools.pools[0].recycled)
        assertEquals(pools.pools[0].taken, pools.pools[0].recycled)
    }

    @Test
    fun aPublicationOutlivesRetirementAndItsBufferRecyclesOnTheHostsRelease() {
        val pools = ScriptedBufferPools()
        val compositor = CameraEffectCompositor(CameraEffect.DIM, pools)
        val input = EffectFrame(width = 64, height = 36).apply { fillLuma { _, _ -> 200 } }
        val published = composited(compositor.composite(input.frame(), null)).frame

        compositor.retire()

        assertEquals(0, pools.pools[0].recycled)
        assertLuma(published.planes, 32, 18, 100)

        published.close()

        assertEquals(pools.pools[0].taken, pools.pools[0].recycled)
    }

    @Test
    fun postRetirementFailuresPublishIndependentBlackFramesAndRetainNoPoolClaim() {
        val pools = ScriptedBufferPools()
        val compositor = CameraEffectCompositor(CameraEffect.DIM, pools)
        val input = EffectFrame(width = 64, height = 36).apply { fillLuma { _, _ -> 200 } }
        composited(compositor.composite(input.frame(), null)).frame.close()

        compositor.retire()
        val firstFailure = EffectFrame(width = 64, height = 36).apply {
            failsToMaterialize = true
        }
        val first = substituted(compositor.composite(firstFailure.frame(), null))

        assertEquals(CameraCompositeSubstitution.RENDER_FAILED, first.reason)
        assertLuma(first.frame.planes, 32, 18, 0, within = 0)
        first.frame.planes.dataY.put(0, 31)

        val secondFailure = EffectFrame(width = 64, height = 36).apply {
            failsToMaterialize = true
        }
        val second = substituted(compositor.composite(secondFailure.frame(), null))

        assertEquals(CameraCompositeSubstitution.RENDER_FAILED, second.reason)
        assertLuma(second.frame.planes, 0, 0, 0, within = 0)
        assertEquals(31, luma(first.frame.planes, 0, 0))
        first.frame.close()
        second.frame.close()
        assertEquals(pools.pools[0].taken, pools.pools[0].recycled)
    }

    @Test
    fun aFailedGeometryAdoptionPublishesIncomingSizedBlackAndPreservesTheOldGeometry() {
        val pools = ScriptedBufferPools()
        val compositor = CameraEffectCompositor(CameraEffect.DIM, pools)
        val wide = EffectFrame(width = 64, height = 36).apply { fillLuma { _, _ -> 200 } }
        composited(compositor.composite(wide.frame(), null)).frame.close()

        pools.creationFails = true
        val narrow = EffectFrame(width = 48, height = 24, timestampNs = 1234)
        val failed = substituted(compositor.composite(narrow.frame(), null))

        assertEquals(CameraCompositeSubstitution.RENDER_FAILED, failed.reason)
        assertEquals(48, failed.frame.width)
        assertEquals(24, failed.frame.height)
        assertLuma(failed.frame.planes, 24, 12, 0, within = 0)
        failed.frame.close()
        assertEquals(1, pools.pools.size)

        val staleSized = EffectFrame(
            width = 32,
            height = 18,
            declaredWidth = 64,
            declaredHeight = 36,
        )
        val recovered = substituted(compositor.composite(staleSized.frame(), null))

        assertEquals(CameraCompositeSubstitution.MALFORMED_FRAME, recovered.reason)
        assertLuma(recovered.frame.planes, 32, 18, 100)
        recovered.frame.close()

        pools.creationFails = false
        val next = composited(compositor.composite(wide.frame(), null))
        assertLuma(next.frame.planes, 32, 18, 100)
        next.frame.close()
        assertEquals(1, pools.pools.size)
    }

    @Test
    fun theOutputNeverAliasesTheInputPlanes() {
        val compositor = CameraEffectCompositor(CameraEffect.NONE)
        val input = EffectFrame(width = 64, height = 36).apply { fillLuma { _, _ -> 200 } }

        val planes = composited(compositor.composite(input.frame(), null)).frame.planes
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
    fun thePublishedPlanesAreDirectAndPositionedAtTheirStarts() {
        val compositor = CameraEffectCompositor(CameraEffect.DIM)
        val input = EffectFrame(width = 64, height = 36)

        val planes = composited(compositor.composite(input.frame(), null)).frame.planes

        assertTrue(planes.dataY.isDirect)
        assertTrue(planes.dataU.isDirect)
        assertTrue(planes.dataV.isDirect)
        assertEquals(0, planes.dataY.position())
        assertEquals(0, planes.dataU.position())
        assertEquals(0, planes.dataV.position())
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
        val pools = ScriptedBufferPools()
        val compositor = CameraEffectCompositor(CameraEffect.DIM, pools)
        val wide = EffectFrame(width = 64, height = 36)
        val narrow = EffectFrame(width = 48, height = 24)
        val violations = AtomicInteger()
        val workers = Executors.newFixedThreadPool(8)

        repeat(240) { index ->
            workers.execute {
                if (index == 120) compositor.retire()
                val source = if (index % 3 == 0) narrow else wide
                val output = compositor.composite(source.frame(), null).frame
                val planes = output.planes
                val coherent = output.width == planes.width &&
                    output.height == planes.height &&
                    (output.width == 64 || output.width == 48)
                if (!coherent) violations.incrementAndGet()
                output.close()
            }
        }
        workers.shutdown()

        assertTrue(workers.awaitTermination(30, TimeUnit.SECONDS))
        assertEquals(0, violations.get())
        compositor.retire()
        for (pool in pools.pools) assertEquals(pool.taken, pool.recycled)
    }
}
