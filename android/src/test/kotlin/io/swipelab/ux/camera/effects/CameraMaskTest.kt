package io.swipelab.ux.camera.effects

import java.nio.FloatBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class CameraMaskTest {
    /**
     * An upright grid whose only confident cell sits one in from the left and
     * one down from the top.
     */
    private fun uprightMask(width: Int, height: Int): PersonMaskPixels {
        val confidence = FloatBuffer.allocate(width * height)
        confidence.put(1 * width + 1, 1f)
        return PersonMaskPixels(width, height, confidence)
    }

    private fun confident(pixels: PersonMaskPixels): Pair<Int, Int> {
        val confidence = pixels.confidence
        for (y in 0 until pixels.height) {
            for (x in 0 until pixels.width) {
                if (confidence.get(y * pixels.width + x) == 1f) return x to y
            }
        }
        throw AssertionError("no confident cell in the mapped mask")
    }

    @Test
    fun anUnturnedMaskKeepsItsGridAndItsCells() {
        val mapped = uprightMask(6, 4).onInputGrid(CameraFrameRotation.DEGREES_0)

        assertEquals(6, mapped.width)
        assertEquals(4, mapped.height)
        assertEquals(1 to 1, confident(mapped))
    }

    @Test
    fun aQuarterTurnedMaskMapsBackOntoTheInputGrid() {
        val mapped = uprightMask(4, 6).onInputGrid(CameraFrameRotation.DEGREES_90)

        assertEquals(6, mapped.width)
        assertEquals(4, mapped.height)
        assertEquals(4 to 1, confident(mapped))
    }

    @Test
    fun aThreeQuarterTurnedMaskMapsBackOntoTheInputGrid() {
        val mapped = uprightMask(4, 6).onInputGrid(CameraFrameRotation.DEGREES_270)

        assertEquals(6, mapped.width)
        assertEquals(4, mapped.height)
        assertEquals(1 to 2, confident(mapped))
    }

    @Test
    fun aHalfTurnedMaskMapsBackOntoTheInputGrid() {
        val mapped = uprightMask(6, 4).onInputGrid(CameraFrameRotation.DEGREES_180)

        assertEquals(6, mapped.width)
        assertEquals(4, mapped.height)
        assertEquals(4 to 2, confident(mapped))
    }

    @Test
    fun personMaskPixelsRejectsAnUndersizedBuffer() {
        assertThrows(IllegalArgumentException::class.java) {
            PersonMaskPixels(16, 12, FloatBuffer.allocate(16 * 12 - 1))
        }
    }

    @Test
    fun personMaskPixelsRejectsALimitShortenedBuffer() {
        val confidence = FloatBuffer.allocate(16 * 12).apply { limit(16 * 12 - 1) }

        assertThrows(IllegalArgumentException::class.java) {
            PersonMaskPixels(16, 12, confidence)
        }
    }

    @Test
    fun personMaskPixelsRejectsAnOverflowingGrid() {
        assertThrows(IllegalArgumentException::class.java) {
            PersonMaskPixels(Int.MAX_VALUE, 2, FloatBuffer.allocate(1))
        }
    }
}
